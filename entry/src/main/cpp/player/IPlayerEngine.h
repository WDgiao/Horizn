#ifndef SOFT_PLAYER_IPLAYER_ENGINE_H
#define SOFT_PLAYER_IPLAYER_ENGINE_H

#include <string>
#include <cstdint>
#include <functional>

namespace softplayer {

/** 播放器状态，与 ArkTS 侧 SoftPlayerState 一一对应 */
enum class PlayerState : int32_t {
    IDLE = 0,        // 已创建，未准备
    PREPARING = 1,   // 正在打开文件/探测流
    READY = 2,       // 已就绪，可播放
    PLAYING = 3,
    PAUSED = 4,
    COMPLETED = 5,
    ERROR_STATE = 6,
    RELEASED = 7
};

/** 媒体信息，prepare 成功后有效 */
struct MediaInfo {
    int64_t durationMs = 0;   // 总时长
    int32_t width = 0;        // 画面宽
    int32_t height = 0;       // 画面高
    double frameRate = 0.0;   // 帧率
    std::string videoCodec;   // 视频编码名，例如 "rv40"
    std::string audioCodec;   // 音频编码名，例如 "cook"
    bool hasVideo = false;
    bool hasAudio = false;
    /**
     * 画面旋转角度（0 / 90 / 180 / 270，顺时针）
     *
     * 手机竖拍视频常以横向像素存储，靠容器的旋转矩阵标记"播放时转 90 度"。
     * 系统 AVPlayer 会自动处理，我们自己解码必须自己转 —— 否则画面是歪的。
     * 注意：width/height 报的是**旋转前**的存储尺寸；
     * 旋转 90/270 时实际观看尺寸是两者互换。
     */
    int32_t rotationDeg = 0;
};

/** 事件类型，通过回调上报到 JS 侧 */
enum class PlayerEvent : int32_t {
    STATE_CHANGED = 0,   // 状态变化，data1 = PlayerState
    POSITION = 1,        // 播放进度，data1 = 当前毫秒
    DURATION = 2,        // 时长就绪，data1 = 毫秒
    VIDEO_SIZE = 3,      // 画面尺寸，data1 = 宽，data2 = 高
    ERROR = 4,           // 出错，text = 描述，data1 = 错误码
    PREPARED = 5,        // 准备完成
    COMPLETED = 6        // 播放结束
};

/**
 * 事件回调
 * ★ 实现方必须保证：本回调可能在【任意线程】被调用（解码线程），
 *   因此实现里不能直接碰 ArkTS 对象，必须投递到 JS 线程。
 *   这正是 NAPI 层用 napi_threadsafe_function 的原因。
 */
using EventCallback = std::function<void(PlayerEvent type, int64_t data1, int64_t data2,
                                         const std::string &text)>;

/**
 * 播放引擎抽象接口
 *
 * 这层刻意不出现任何 FFmpeg 类型 —— 这样：
 *   1) NAPI 层可以在没有 FFmpeg 的情况下先写完并验证
 *   2) 将来换实现（比如硬解）不影响上层
 */
class IPlayerEngine {
public:
    virtual ~IPlayerEngine() = default;

    /** 设置事件回调，必须在 Prepare 之前调用 */
    virtual void SetCallback(EventCallback cb) = 0;

    /**
     * 打开媒体并准备解码
     * @param path 媒体文件绝对路径（沙箱内）
     * @return 0 成功；非 0 为错误码
     */
    virtual int32_t Prepare(const std::string &path) = 0;

    /** 开始/继续播放 */
    virtual int32_t Start() = 0;

    /** 暂停 */
    virtual int32_t Pause() = 0;

    /** 跳转到指定毫秒位置 */
    virtual int32_t SeekTo(int64_t positionMs) = 0;

    /** 设置视频渲染 surface（XComponent 的 surfaceId 字符串） */
    virtual int32_t SetSurface(const std::string &surfaceId) = 0;

    /**
     * 解绑渲染 surface：释放 native window 且不再上屏
     *
     * 为什么需要在 Release 之外单独提供这个动作：
     *   XComponent 被销毁时，ArkUI 会去析构对应的 Surface 渲染节点
     *   （实测崩溃栈：RSSurfaceNode::~RSSurfaceNode -> RSNode::ClearAllModifiers，
     *    崩在系统渲染库里，主线程）。
     *   如果此时原生侧还持有那个 surface 的 native window、甚至还在往上写帧，
     *   就会与系统销毁流程撞车，表现为"极快开合时闪退"。
     *
     *   所以页面消失时必须**先解绑 surface**，让原生侧立刻放弃它，
     *   然后再去停线程、关音频、释放会话 —— 顺序反了就来不及。
     *
     * 默认实现返回 0，不强制所有引擎都支持。
     */
    virtual int32_t DetachSurface() { return 0; }

    /** 取当前媒体信息 */
    virtual MediaInfo GetMediaInfo() const = 0;

    /** 当前播放位置（毫秒） */
    virtual int64_t GetPositionMs() const = 0;

    /** 释放全部资源，之后不可再调用其它方法 */
    virtual void Release() = 0;
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_IPLAYER_ENGINE_H
