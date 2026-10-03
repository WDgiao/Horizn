#include "SoftPlayerBinding.h"
#include "player/StubEngine.h"
#include "player/FfmpegEngine.h"
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "SoftPlayer"

namespace softplayer {

namespace {

constexpr const char *kClassName = "SoftPlayer";

/** 读取 JS 字符串参数 */
bool GetStringArg(napi_env env, napi_value v, std::string &out)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, v, out.data(), len + 1, &copied) != napi_ok) {
        return false;
    }
    out.resize(copied);
    return true;
}

/** 读取 JS 数字参数（int64） */
bool GetInt64Arg(napi_env env, napi_value v, int64_t &out)
{
    return napi_get_value_int64(env, v, &out) == napi_ok;
}

/** 抛出 JS 异常并返回 undefined，避免 C++ 异常穿透到 napi */
napi_value ThrowError(napi_env env, const char *msg)
{
    napi_throw_error(env, nullptr, msg);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

}  // namespace

SoftPlayerBinding::SoftPlayerBinding() = default;

SoftPlayerBinding::~SoftPlayerBinding()
{
    if (!released_.exchange(true)) {
        if (engine_) {
            engine_->Release();
            engine_.reset();
        }
    }
}

/* ============================================================
   对象创建与 this 解析
   ============================================================ */

napi_value SoftPlayerBinding::Create(napi_env env, napi_callback_info info)
{
    napi_value jsThis = nullptr;
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, nullptr, &jsThis, nullptr);

    auto *self = new SoftPlayerBinding();
    self->env_ = env;
    // 用真正的软解引擎。
    // StubEngine 是最早用来验证 NAPI 链路的假实现（模拟 12 秒进度、不解码），
    // 保留它只是为了在没有 FFmpeg 的构建里也能验证骨架 —— 但那样时长、
    // 画面都是假的（实测表现为时长显示 2800 这种无意义数字）。
    self->engine_ = std::make_unique<FfmpegEngine>();

    // 把引擎事件接到本对象的队列上
    self->engine_->SetCallback(
        [self](PlayerEvent type, int64_t d1, int64_t d2, const std::string &text) {
            self->OnEngineEvent(type, d1, d2, text);
        });

    napi_wrap(env, jsThis, self,
        [](napi_env e, void *data, void *hint) {
            auto *obj = static_cast<SoftPlayerBinding *>(data);
            delete obj;
        }, nullptr, &self->wrapperRef_);

    OH_LOG_INFO(LOG_APP, "SoftPlayer instance created");
    return jsThis;
}

SoftPlayerBinding *SoftPlayerBinding::Unwrap(napi_env env, napi_callback_info info,
                                             size_t *argc, napi_value *argv)
{
    napi_value jsThis = nullptr;
    napi_get_cb_info(env, info, argc, argv, &jsThis, nullptr);
    void *data = nullptr;
    if (napi_unwrap(env, jsThis, &data) != napi_ok || data == nullptr) {
        return nullptr;
    }
    return static_cast<SoftPlayerBinding *>(data);
}

/* ============================================================
   事件队列
   ============================================================ */

void SoftPlayerBinding::OnEngineEvent(PlayerEvent type, int64_t d1, int64_t d2,
                                      const std::string &text)
{
    // 只做入队，不接触任何 JS 对象 —— 本函数可能运行在解码线程
    std::lock_guard<std::mutex> lock(queueMutex_);
    PendingEvent ev;
    ev.type = static_cast<int32_t>(type);
    ev.data1 = d1;
    ev.data2 = d2;
    ev.text = text;
    queue_.push(std::move(ev));
}

napi_value SoftPlayerBinding::MakeEvent(napi_env env, const PendingEvent &ev)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);

    napi_value v = nullptr;
    napi_create_int32(env, ev.type, &v);
    napi_set_named_property(env, obj, "type", v);

    napi_create_int64(env, ev.data1, &v);
    napi_set_named_property(env, obj, "data1", v);

    napi_create_int64(env, ev.data2, &v);
    napi_set_named_property(env, obj, "data2", v);

    napi_create_string_utf8(env, ev.text.c_str(), ev.text.size(), &v);
    napi_set_named_property(env, obj, "text", v);

    return obj;
}

napi_value SoftPlayerBinding::JsPollEvents(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }

    std::queue<PendingEvent> local;
    {
        std::lock_guard<std::mutex> lock(self->queueMutex_);
        std::swap(local, self->queue_);
    }

    napi_value arr = nullptr;
    napi_create_array_with_length(env, local.size(), &arr);
    uint32_t i = 0;
    while (!local.empty()) {
        napi_value ev = MakeEvent(env, local.front());
        napi_set_element(env, arr, i++, ev);
        local.pop();
    }
    return arr;
}

/* ============================================================
   控制方法
   ============================================================ */

napi_value SoftPlayerBinding::JsSetSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    SoftPlayerBinding *self = Unwrap(env, info, &argc, argv);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    if (self->released_.load()) {
        return ThrowError(env, "player already released");
    }
    std::string id;
    if (argc < 1 || !GetStringArg(env, argv[0], id)) {
        return ThrowError(env, "setSurface expects a string surfaceId");
    }
    napi_value ret = nullptr;
    napi_create_int32(env, self->engine_ ? self->engine_->SetSurface(id) : -1, &ret);
    return ret;
}

/**
 * 解绑渲染 surface
 *
 * 页面销毁时必须【先】调它，再调 release()。
 * 原因见 IPlayerEngine::DetachSurface 的说明：
 * XComponent 销毁时 ArkUI 会析构 Surface 渲染节点，
 * 原生侧若还持有该 surface 就会和系统销毁流程撞车（实测崩溃在
 * RSSurfaceNode::~RSSurfaceNode），表现为"极快开合时闪退"。
 *
 * 注意：这里刻意不检查 released_ —— 解绑在释放流程里可能被重复调用，
 * 而它本身是幂等的（窗口已销毁就直接返回）。
 */
napi_value SoftPlayerBinding::JsDetachSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    napi_value ret = nullptr;
    napi_create_int32(env, self->engine_ ? self->engine_->DetachSurface() : -1, &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsPrepare(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    SoftPlayerBinding *self = Unwrap(env, info, &argc, argv);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    if (self->released_.load()) {
        return ThrowError(env, "player already released");
    }
    std::string path;
    if (argc < 1 || !GetStringArg(env, argv[0], path)) {
        return ThrowError(env, "prepare expects a string path");
    }
    // ★ 2026-10-03：可选的第 2 个参数 = 起播位置（毫秒）。
    //   续播必须在 Prepare 之前把位置交给引擎，这样"预渲染的第一帧"
    //   就是续播位置那一帧（详见 FfmpegEngine::SetStartPositionMs 的说明）。
    if (self->engine_ != nullptr && argc >= 2 && argv[1] != nullptr) {
        int64_t startMs = 0;
        if (napi_get_value_int64(env, argv[1], &startMs) == napi_ok && startMs > 0) {
            self->engine_->SetStartPositionMs(startMs);
        }
    }
    napi_value ret = nullptr;
    napi_create_int32(env, self->engine_ ? self->engine_->Prepare(path) : -1, &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsStart(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    if (self->released_.load()) {
        return ThrowError(env, "player already released");
    }
    napi_value ret = nullptr;
    napi_create_int32(env, self->engine_ ? self->engine_->Start() : -1, &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsPause(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    if (self->released_.load()) {
        return ThrowError(env, "player already released");
    }
    napi_value ret = nullptr;
    napi_create_int32(env, self->engine_ ? self->engine_->Pause() : -1, &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsSeekTo(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    SoftPlayerBinding *self = Unwrap(env, info, &argc, argv);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    if (self->released_.load()) {
        return ThrowError(env, "player already released");
    }
    int64_t ms = 0;
    if (argc < 1 || !GetInt64Arg(env, argv[0], ms)) {
        return ThrowError(env, "seekTo expects a number");
    }
    napi_value ret = nullptr;
    napi_create_int32(env, self->engine_ ? self->engine_->SeekTo(ms) : -1, &ret);
    return ret;
}

/**
 * setColorAdjust(brightness, contrast, saturation, hue, rGain, gGain, bGain)
 *
 * 七个参数都是百分比（-100 ~ +100），见 IPlayerEngine 的说明。
 * 参数缺省按 0 处理（= 不改），这样 JS 侧即使只传一部分也不会报错。
 */
napi_value SoftPlayerBinding::JsSetColorAdjust(napi_env env, napi_callback_info info)
{
    size_t argc = 7;
    napi_value argv[7] = {nullptr};
    SoftPlayerBinding *self = Unwrap(env, info, &argc, argv);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    if (self->released_.load() || !self->engine_) {
        return ThrowError(env, "player already released");
    }
    int32_t v[7] = {0, 0, 0, 0, 0, 0, 0};
    for (size_t i = 0; i < argc && i < 7; i++) {
        int64_t t = 0;
        if (GetInt64Arg(env, argv[i], t)) {
            v[i] = static_cast<int32_t>(t);
        }
    }
    self->engine_->SetColorAdjust(v[0], v[1], v[2], v[3], v[4], v[5], v[6]);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

/**
 * setAudioEq(enabled, gainsDb[])
 *
 * gainsDb 是长度 10 的数组（60/170/310/600/1k/3k/6k/12k/14k/16kHz 的 dB 增益）。
 * 数组缺失时按全 0（平坦）处理，不会抛异常 —— UI 侧只关心"能不能调"。
 */
napi_value SoftPlayerBinding::JsSetAudioEq(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    SoftPlayerBinding *self = Unwrap(env, info, &argc, argv);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    if (self->released_.load() || !self->engine_) {
        return ThrowError(env, "player already released");
    }
    bool enabled = false;
    if (argc >= 1) {
        napi_get_value_bool(env, argv[0], &enabled);
    }
    int32_t gains[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    if (argc >= 2) {
        bool isArray = false;
        napi_is_array(env, argv[1], &isArray);
        if (isArray) {
            uint32_t len = 0;
            napi_get_array_length(env, argv[1], &len);
            for (uint32_t i = 0; i < len && i < 10; i++) {
                napi_value item = nullptr;
                if (napi_get_element(env, argv[1], i, &item) != napi_ok) {
                    continue;
                }
                int64_t t = 0;
                if (GetInt64Arg(env, item, t)) {
                    gains[i] = static_cast<int32_t>(t);
                }
            }
        }
    }
    self->engine_->SetAudioEq(enabled, gains, 10);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

napi_value SoftPlayerBinding::JsRelease(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    if (self == nullptr) {
        return ThrowError(env, "player object is invalid");
    }
    // 幂等：重复调用不报错，避免 JS 侧多次清理导致崩溃
    if (!self->released_.exchange(true)) {
        if (self->engine_) {
            self->engine_->Release();
            self->engine_.reset();
        }
        OH_LOG_INFO(LOG_APP, "SoftPlayer released");
    }
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

/* ============================================================
   查询方法
   ============================================================ */

napi_value SoftPlayerBinding::JsGetState(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    napi_value ret = nullptr;
    if (self == nullptr || self->released_.load() || !self->engine_) {
        napi_create_int32(env, static_cast<int32_t>(PlayerState::RELEASED), &ret);
        return ret;
    }
    napi_create_int32(env, static_cast<int32_t>(PlayerState::IDLE), &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsGetDuration(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    napi_value ret = nullptr;
    int64_t d = 0;
    if (self != nullptr && !self->released_.load() && self->engine_) {
        d = self->engine_->GetMediaInfo().durationMs;
    }
    napi_create_int64(env, d, &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsGetPosition(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    napi_value ret = nullptr;
    int64_t p = 0;
    if (self != nullptr && !self->released_.load() && self->engine_) {
        p = self->engine_->GetPositionMs();
    }
    napi_create_int64(env, p, &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsGetMediaInfo(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    if (self == nullptr || self->released_.load() || !self->engine_) {
        return obj;
    }
    MediaInfo mi = self->engine_->GetMediaInfo();
    napi_value v = nullptr;
    napi_create_int64(env, mi.durationMs, &v);
    napi_set_named_property(env, obj, "durationMs", v);
    napi_create_int32(env, mi.width, &v);
    napi_set_named_property(env, obj, "width", v);
    napi_create_int32(env, mi.height, &v);
    napi_set_named_property(env, obj, "height", v);
    napi_create_double(env, mi.frameRate, &v);
    napi_set_named_property(env, obj, "frameRate", v);
    napi_create_string_utf8(env, mi.videoCodec.c_str(), mi.videoCodec.size(), &v);
    napi_set_named_property(env, obj, "videoCodec", v);
    napi_create_string_utf8(env, mi.audioCodec.c_str(), mi.audioCodec.size(), &v);
    napi_set_named_property(env, obj, "audioCodec", v);
    napi_get_boolean(env, mi.hasVideo, &v);
    napi_set_named_property(env, obj, "hasVideo", v);
    napi_get_boolean(env, mi.hasAudio, &v);
    napi_set_named_property(env, obj, "hasAudio", v);

    // ---- 轨道列表（2026-09-29 新增）----
    //
    // 为什么要在这里转成 JS 数组而不是让 ArkTS 侧逐个查询：
    //   轨道数量很少（通常 1~8 条），一次性给完最省事；
    //   分次查询就得为"查第 i 条"设计一个按索引取字段的接口，
    //   反而更啰嗦也更容易在 napi 边界上出错。
    napi_value audioArr = nullptr;
    napi_create_array_with_length(env, mi.audioTracks.size(), &audioArr);
    for (size_t i = 0; i < mi.audioTracks.size(); i++) {
        const AudioTrackInfo &t = mi.audioTracks[i];
        napi_value item = nullptr;
        napi_create_object(env, &item);
        napi_create_int32(env, t.index, &v);
        napi_set_named_property(env, item, "index", v);
        napi_create_string_utf8(env, t.codec.c_str(), t.codec.size(), &v);
        napi_set_named_property(env, item, "codec", v);
        napi_create_string_utf8(env, t.language.c_str(), t.language.size(), &v);
        napi_set_named_property(env, item, "language", v);
        napi_create_string_utf8(env, t.title.c_str(), t.title.size(), &v);
        napi_set_named_property(env, item, "title", v);
        napi_create_int32(env, t.channels, &v);
        napi_set_named_property(env, item, "channels", v);
        napi_create_int32(env, t.sampleRate, &v);
        napi_set_named_property(env, item, "sampleRate", v);
        napi_create_int64(env, t.bitRate, &v);
        napi_set_named_property(env, item, "bitRate", v);
        napi_get_boolean(env, t.isDefault, &v);
        napi_set_named_property(env, item, "isDefault", v);
        napi_set_element(env, audioArr, static_cast<uint32_t>(i), item);
    }
    napi_set_named_property(env, obj, "audioTracks", audioArr);

    napi_value subArr = nullptr;
    napi_create_array_with_length(env, mi.subtitleTracks.size(), &subArr);
    for (size_t i = 0; i < mi.subtitleTracks.size(); i++) {
        const SubtitleTrackInfo &t = mi.subtitleTracks[i];
        napi_value item = nullptr;
        napi_create_object(env, &item);
        napi_create_int32(env, t.index, &v);
        napi_set_named_property(env, item, "index", v);
        napi_create_string_utf8(env, t.codec.c_str(), t.codec.size(), &v);
        napi_set_named_property(env, item, "codec", v);
        napi_create_string_utf8(env, t.language.c_str(), t.language.size(), &v);
        napi_set_named_property(env, item, "language", v);
        napi_create_string_utf8(env, t.title.c_str(), t.title.size(), &v);
        napi_set_named_property(env, item, "title", v);
        napi_get_boolean(env, t.isDefault, &v);
        napi_set_named_property(env, item, "isDefault", v);
        // supported 必须传下去：界面要根据它把图形字幕显示成"不支持"，
        // 而不是让用户点了之后毫无反应
        napi_get_boolean(env, t.supported, &v);
        napi_set_named_property(env, item, "supported", v);
        napi_set_element(env, subArr, static_cast<uint32_t>(i), item);
    }
    napi_set_named_property(env, obj, "subtitleTracks", subArr);

    napi_create_int32(env, mi.currentAudioIndex, &v);
    napi_set_named_property(env, obj, "currentAudioIndex", v);
    napi_create_int32(env, mi.currentSubtitleIndex, &v);
    napi_set_named_property(env, obj, "currentSubtitleIndex", v);
    return obj;
}

napi_value SoftPlayerBinding::JsSwitchAudioTrack(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    SoftPlayerBinding *self = Unwrap(env, info, &argc, argv);
    napi_value ret = nullptr;
    if (self == nullptr || self->released_.load() || !self->engine_) {
        napi_create_int32(env, -1, &ret);
        return ret;
    }
    int32_t idx = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &idx);
    }
    napi_create_int32(env, self->engine_->SwitchAudioTrack(idx), &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsSetSubtitleTrack(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    SoftPlayerBinding *self = Unwrap(env, info, &argc, argv);
    napi_value ret = nullptr;
    if (self == nullptr || self->released_.load() || !self->engine_) {
        napi_create_int32(env, -1, &ret);
        return ret;
    }
    int32_t idx = -1;   // 缺省 -1 = 关闭字幕
    if (argc >= 1) {
        napi_get_value_int32(env, argv[0], &idx);
    }
    napi_create_int32(env, self->engine_->SetSubtitleTrack(idx), &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsGetActiveSubtitle(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    // 没有字幕时返回空字符串而不是 null：
    // ArkTS 侧拿到的类型稳定（永远是 string），界面逻辑不用做 null 判断，
    // 而且 "" 直接绑到 Text 上就是"不显示"，正好是想要的效果。
    napi_value ret = nullptr;
    std::string text;
    if (self != nullptr && !self->released_.load() && self->engine_) {
        SubtitleCue cue;
        if (self->engine_->GetActiveSubtitle(cue)) {
            text = cue.text;
        }
    }
    napi_create_string_utf8(env, text.c_str(), text.size(), &ret);
    return ret;
}

napi_value SoftPlayerBinding::JsCanSwitchAudioTrack(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    SoftPlayerBinding *self = Unwrap(env, info, &argc, nullptr);
    bool can = false;
    if (self != nullptr && !self->released_.load() && self->engine_) {
        can = self->engine_->CanSwitchAudioTrack();
    }
    napi_value ret = nullptr;
    napi_get_boolean(env, can, &ret);
    return ret;
}

/* ============================================================
   模块注册
   ============================================================ */

napi_value SoftPlayerBinding::Init(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        { "setSurface", nullptr, JsSetSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "detachSurface", nullptr, JsDetachSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "prepare", nullptr, JsPrepare, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "start", nullptr, JsStart, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pause", nullptr, JsPause, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "seekTo", nullptr, JsSeekTo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "release", nullptr, JsRelease, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getState", nullptr, JsGetState, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getDuration", nullptr, JsGetDuration, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPosition", nullptr, JsGetPosition, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getMediaInfo", nullptr, JsGetMediaInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "switchAudioTrack", nullptr, JsSwitchAudioTrack, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setSubtitleTrack", nullptr, JsSetSubtitleTrack, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getActiveSubtitle", nullptr, JsGetActiveSubtitle, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "canSwitchAudioTrack", nullptr, JsCanSwitchAudioTrack, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setColorAdjust", nullptr, JsSetColorAdjust, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setAudioEq", nullptr, JsSetAudioEq, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pollEvents", nullptr, JsPollEvents, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_value cls = nullptr;
    napi_define_class(env, kClassName, NAPI_AUTO_LENGTH, Create, nullptr,
                      sizeof(methods) / sizeof(methods[0]), methods, &cls);
    napi_set_named_property(env, exports, kClassName, cls);
    return exports;
}

}  // namespace softplayer
