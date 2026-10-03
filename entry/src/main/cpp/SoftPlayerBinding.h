#ifndef SOFT_PLAYER_BINDING_H
#define SOFT_PLAYER_BINDING_H

#include "napi/native_api.h"
#include "player/IPlayerEngine.h"
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <atomic>
#include <condition_variable>

namespace softplayer {

/**
 * 待投递给 JS 的事件
 *
 * 必须定义在头文件里：std::queue<PendingEvent> 作为成员变量，
 * 需要 PendingEvent 是完整类型，前向声明不够（会报
 * "invalid application of sizeof to an incomplete type"）。
 */
struct PendingEvent {
    /** 事件类型，对应 C++ 侧 PlayerEvent */
    int32_t type = 0;
    /** 主数据（含义随类型而定） */
    int64_t data1 = 0;
    /** 次数据 */
    int64_t data2 = 0;
    /** 文本载荷（错误描述等） */
    std::string text;
};

/**
 * 原生播放器对象的 JS 侧封装
 *
 * 生命周期约定（重要，容易出错的地方）：
 *   1) JS 侧 new SoftPlayer() 时创建本对象，并挂一个外部引用
 *   2) 引擎在解码线程里产生的每个事件，都通过 threadsafe function
 *      投递回 JS 线程后再转成回调调用 —— 绝不跨线程直接调 JS
 *   3) Release 必须在 JS 线程调用；它负责停线程、释放引擎、
 *      释放 threadsafe function。释放后 JS 再调用任何方法都返回错误而非崩溃
 */
class SoftPlayerBinding {
public:
    SoftPlayerBinding();
    ~SoftPlayerBinding();

    /** 在 JS 线程上创建对象（不会启动任何线程） */
    static napi_value Create(napi_env env, napi_callback_info info);

    /** 注册为 napi 模块的导出入口 */
    static napi_value Init(napi_env env, napi_value exports);

    // ---- JS 可调用方法（均为静态，通过 napi 回调进入） ----
    static napi_value JsSetSurface(napi_env env, napi_callback_info info);
    /** 解绑 surface：页面销毁时必须先于 release() 调用 */
    static napi_value JsDetachSurface(napi_env env, napi_callback_info info);
    static napi_value JsPrepare(napi_env env, napi_callback_info info);
    static napi_value JsStart(napi_env env, napi_callback_info info);
    static napi_value JsPause(napi_env env, napi_callback_info info);
    static napi_value JsSeekTo(napi_env env, napi_callback_info info);
    static napi_value JsRelease(napi_env env, napi_callback_info info);
    static napi_value JsGetState(napi_env env, napi_callback_info info);
    static napi_value JsGetDuration(napi_env env, napi_callback_info info);
    static napi_value JsGetPosition(napi_env env, napi_callback_info info);
    static napi_value JsGetMediaInfo(napi_env env, napi_callback_info info);
    /** 切换音轨；参数是流下标（取自 getMediaInfo 的 audioTracks） */
    static napi_value JsSwitchAudioTrack(napi_env env, napi_callback_info info);
    /** 启用/关闭字幕轨；参数是流下标，传 -1 表示关闭 */
    static napi_value JsSetSubtitleTrack(napi_env env, napi_callback_info info);
    /** 取当前该显示的字幕文本；没有时返回空串 */
    static napi_value JsGetActiveSubtitle(napi_env env, napi_callback_info info);
    /** 文件里是否有多条可切换音轨 */
    static napi_value JsCanSwitchAudioTrack(napi_env env, napi_callback_info info);
    /** 色调调整：7 个百分比参数（亮度/对比度/饱和度/色彩度/R/G/B） */
    static napi_value JsSetColorAdjust(napi_env env, napi_callback_info info);
    /** 均衡器：setAudioEq(enabled, gainsDb[10]) */
    static napi_value JsSetAudioEq(napi_env env, napi_callback_info info);
    /** 播放速度：setSpeed(1.0 = 原速) */
    static napi_value JsSetSpeed(napi_env env, napi_callback_info info);
    /** 应用内音量：setVolume(0.0 ~ 1.0) */
    static napi_value JsSetVolume(napi_env env, napi_callback_info info);
    static napi_value JsPollEvents(napi_env env, napi_callback_info info);

private:
    /** 引擎事件 → 放入队列（可能来自解码线程） */
    void OnEngineEvent(PlayerEvent type, int64_t d1, int64_t d2, const std::string &text);

    /** 解析 this 指针 */
    static SoftPlayerBinding *Unwrap(napi_env env, napi_callback_info info,
                                     size_t *argc, napi_value *argv);

    /** 生成一个事件对象 */
    static napi_value MakeEvent(napi_env env, const PendingEvent &ev);

    // ---- 成员 ----
    std::unique_ptr<IPlayerEngine> engine_;
    napi_env env_ = nullptr;

    /**
     * 事件队列
     *
     * 为什么用"队列 + JS 侧轮询"而不是 threadsafe function 直接回调：
     * threadsafe function 需要持有 napi_ref、管理释放时机，
     * 且在对象已释放后回调会变得危险。
     * 队列方案下：原生线程只做加锁入队（不碰 JS），
     * JS 线程定时 pollEvents 取走 —— 没有跨线程生命周期问题，
     * 也更容易在真机上排查。代价是有一帧级别的延迟（可接受）。
     */
    std::mutex queueMutex_;
    std::queue<PendingEvent> queue_;

    std::atomic<bool> released_{false};
    napi_ref wrapperRef_ = nullptr;
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_BINDING_H
