#include "napi/native_api.h"
#include "hilog/log.h"
#include "SoftPlayerBinding.h"
#include "player/FfmpegEngine.h"
#include "player/FfmpegCodecApi.h"
#include <cstdio>
#include <ctime>
#include <string>
#include <unistd.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "SoftPlayer"

/**
 * 探针函数：返回一个可验证的字符串
 *
 * 阶段 1 的验收标准就是「ArkTS 能拿到这个返回值」——
 * 它同时证明了：C++ 编译成功、.so 被正确打包、NAPI 注册成功、
 * ArkTS 能加载并调用原生模块。这四件事任何一件不成立都会失败。
 */
static napi_value NativeProbe(napi_env env, napi_callback_info info)
{
    const char *msg = "native-ok:20260923";
    napi_value result = nullptr;
    napi_create_string_utf8(env, msg, NAPI_AUTO_LENGTH, &result);
    OH_LOG_INFO(LOG_APP, "NativeProbe called, returning %{public}s", msg);
    return result;
}

/**
 * 返回原生库的编译信息，用于确认 ABI 与编译选项
 */
static napi_value NativeBuildInfo(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
#if defined(__aarch64__)
    const char *arch = "aarch64";
#elif defined(__arm__)
    const char *arch = "arm";
#elif defined(__x86_64__)
    const char *arch = "x86_64";
#else
    const char *arch = "unknown";
#endif
    const char *cpp = (__cplusplus >= 201703L) ? "c++17+" : "c++14-";
    char buf[128] = {0};
    snprintf(buf, sizeof(buf), "arch=%s %s %s", arch, cpp, __DATE__);

    napi_create_string_utf8(env, buf, NAPI_AUTO_LENGTH, &result);
    OH_LOG_INFO(LOG_APP, "NativeBuildInfo: %{public}s", buf);
    return result;
}

/**
 * 软解引擎探针
 *
 * 用来在真机上验证 FfmpegEngine 这条「与 FFmpeg 无关」的骨架是否真的工作：
 *   构造引擎 → 设回调 → SetSurface → Prepare → Start → 收事件 → 释放
 *
 * 在 FFmpeg 未集成时，Prepare 应当返回明确的「未集成」错误并且状态切到 ERROR，
 * 而不是崩溃或静默失败 —— 这正是本探针要证明的。
 * 等 FFmpeg 接上之后，同一个探针会变成真正的软解播放验证。
 *
 * 用法：nativeSoftDecodeProbe(surfaceId, filePath) -> 结果字符串
 */
static napi_value NativeSoftDecodeProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char surfaceBuf[64] = {0};
    char pathBuf[1024] = {0};
    size_t len = 0;
    if (argc >= 1 && args[0] != nullptr) {
        napi_get_value_string_utf8(env, args[0], surfaceBuf, sizeof(surfaceBuf), &len);
    }
    if (argc >= 2 && args[1] != nullptr) {
        napi_get_value_string_utf8(env, args[1], pathBuf, sizeof(pathBuf), &len);
    }

    std::string log;
    char line[512] = {0};

    snprintf(line, sizeof(line), "软解集成状态: %s (FFmpeg %s)",
             softplayer::codecapi::IsIntegrated() ? "已集成" : "未集成",
             softplayer::codecapi::VersionString().c_str());
    log += line;
    log += "\n";

    auto *engine = new softplayer::FfmpegEngine();

    // 收集事件，验证回调链路真的通
    int stateEvents = 0;
    std::string lastError;
    bool sawPrepared = false;
    engine->SetCallback([&](softplayer::PlayerEvent type, int64_t d1, int64_t d2,
                            const std::string &text) {
        if (type == softplayer::PlayerEvent::STATE_CHANGED) {
            stateEvents++;
        } else if (type == softplayer::PlayerEvent::PREPARED) {
            sawPrepared = true;
        } else if (type == softplayer::PlayerEvent::ERROR) {
            lastError = text;
        }
    });

    const std::string surfaceId(surfaceBuf);
    const int32_t surfRet = engine->SetSurface(surfaceId);
    snprintf(line, sizeof(line), "SetSurface(%s) -> %d",
             surfaceId.empty() ? "空" : surfaceId.c_str(), surfRet);
    log += line;
    log += "\n";

    const std::string path(pathBuf);
    const int32_t prepRet = engine->Prepare(path);
    snprintf(line, sizeof(line), "Prepare(%s) -> %d", path.c_str(), prepRet);
    log += line;
    log += "\n";

    snprintf(line, sizeof(line), "事件: 状态变化 %d 次, PREPARED=%s",
             stateEvents, sawPrepared ? "是" : "否");
    log += line;
    log += "\n";

    if (!lastError.empty()) {
        snprintf(line, sizeof(line), "错误: %s", lastError.c_str());
        log += line;
        log += "\n";
    }

    // 走到 READY 才 Start；未集成时是 ERROR，不该启动线程
    const int32_t startRet = engine->Start();
    snprintf(line, sizeof(line), "Start -> %d", startRet);
    log += line;
    log += "\n";

    const softplayer::MediaInfo mi = engine->GetMediaInfo();
    snprintf(line, sizeof(line), "媒体信息: %dx%d 编码=%s/%s 时长=%lldms",
             mi.width, mi.height,
             mi.videoCodec.empty() ? "-" : mi.videoCodec.c_str(),
             mi.audioCodec.empty() ? "-" : mi.audioCodec.c_str(),
             static_cast<long long>(mi.durationMs));
    log += line;
    log += "\n";

    // ★ 关键验证：真的让它解一会儿，看播放位置有没有推进。
    //   位置推进 = 解码线程在跑 + FFmpeg 真解出了帧 + 帧进了队列 + 时钟在走。
    //   只报告"Prepare 成功"是不够的 —— 那只能证明解封装和找解码器成功。
    //
    //   surfaceMode 参数：传空串则 RenderFrame 会直接返回（没有 surface 就不上屏），
    //   于是这条路径只验证「解码」本身。用来把"解码问题"和"渲染问题"分开定位。
    if (startRet == 0) {
        int64_t maxPos = 0;
        int samples = 0;
        for (int i = 0; i < 20; i++) {
            usleep(100 * 1000);
            const int64_t pos = engine->GetPositionMs();
            if (pos > maxPos) {
                maxPos = pos;
            }
            samples++;
            if (maxPos >= mi.durationMs && mi.durationMs > 0) {
                break;
            }
        }
        snprintf(line, sizeof(line), "播放 2 秒后: 位置 %lld ms / %lld ms（采样 %d 次，%s）",
                 static_cast<long long>(maxPos), static_cast<long long>(mi.durationMs), samples,
                 surfaceId.empty() ? "无 surface 仅解码" : "带 surface 解码+上屏");
        log += line;
        log += "\n";
        if (maxPos > 0) {
            log += "✅ 解码推进正常\n";
        } else {
            log += "⚠ 位置未推进：解码线程可能没出帧\n";
        }
    }

    // 线程退出路径也要验证：Release 不能让线程卡在等待里导致 join 挂死
    const int64_t t0 = static_cast<int64_t>(time(nullptr));
    engine->Release();
    const int64_t costMs = (static_cast<int64_t>(time(nullptr)) - t0) * 1000;
    snprintf(line, sizeof(line), "Release 完成（%lld 秒内返回，未挂死）",
             static_cast<long long>(costMs / 1000));
    log += line;
    delete engine;

    OH_LOG_INFO(LOG_APP, "SoftDecodeProbe 结束");
    napi_value result = nullptr;
    napi_create_string_utf8(env, log.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "nativeProbe", nullptr, NativeProbe, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "nativeBuildInfo", nullptr, NativeBuildInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "nativeSoftDecodeProbe", nullptr, NativeSoftDecodeProbe, nullptr, nullptr, nullptr,
          napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    // 注册原生播放器类（SoftPlayer）
    softplayer::SoftPlayerBinding::Init(env, exports);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "softplayer",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterSoftPlayerModule(void)
{
    napi_module_register(&demoModule);
}
