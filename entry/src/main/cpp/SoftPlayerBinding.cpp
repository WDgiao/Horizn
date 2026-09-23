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
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
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
    return obj;
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
        { "pollEvents", nullptr, JsPollEvents, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_value cls = nullptr;
    napi_define_class(env, kClassName, NAPI_AUTO_LENGTH, Create, nullptr,
                      sizeof(methods) / sizeof(methods[0]), methods, &cls);
    napi_set_named_property(env, exports, kClassName, cls);
    return exports;
}

}  // namespace softplayer
