#ifndef SOFT_PLAYER_IPLAYER_ENGINE_H
#define SOFT_PLAYER_IPLAYER_ENGINE_H

#include "FfmpegTypes.h"

#include <string>
#include <cstdint>
#include <functional>
#include <vector>

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

    /**
     * 文件里的全部音轨 / 字幕轨
     *
     * 引擎自己保留一份，供界面查询"这个文件有哪些声道可选"。
     * 类型直接复用 FfmpegTypes.h 里的定义 —— 这样做让引擎层耦合了
     * FFmpeg 侧的类型，但换来的是不用维护两套结构再逐字段互拷。
     */
    std::vector<AudioTrackInfo> audioTracks;
    std::vector<SubtitleTrackInfo> subtitleTracks;
    /** 当前生效的音轨 / 字幕轨下标（-1 表示无 / 未启用） */
    int32_t currentAudioIndex = -1;
    int32_t currentSubtitleIndex = -1;
};

/**
 * 一条待显示的字幕
 *
 * 为什么用"取当前字幕"(GetActiveSubtitle) 而不是事件推送：
 *   字幕天生是**时间对齐**的 —— 该显示哪一条只取决于当前播放位置。
 *   用事件推就得在 ArkTS 侧再做一次时间判断与去重，还要处理
 *   "推送延迟导致字幕晚了半秒"这类问题。
 *   让界面按当前 positionMs 来问"现在该显示什么"，逻辑简单且天然同步。
 */
struct SubtitleCue {
    int64_t startMs = 0;
    int64_t endMs = 0;
    std::string text;
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

    /**
     * 设置起播位置（毫秒），必须在 Prepare 之前调用
     *
     * 为什么要在 Prepare 之前给：续播时引擎要"打开后先跳到目标位置，
     * 再预渲染第一帧"，这样上层拿到的首帧就是续播位置那一帧。
     * 默认实现是空操作，方便不支持的原生实现（如 StubEngine）不受影响。
     */
    virtual void SetStartPositionMs(int64_t positionMs) { (void)positionMs; }

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

    /**
     * 切换音轨
     *
     * 实现方式见 FfmpegCodecApi.h 里 TrackRequest 的说明：
     * 「用新下标把会话重开一次，再 seek 回原来的位置」。
     * 之所以不做就地热替换，是因为解码器上下文、重采样上下文、包队列
     * 全都与具体那条流绑定，热替换要处理线程停顿、队列清空、解码器冲刷，
     * 出错面远大于重开。
     *
     * @param streamIndex 目标音轨的流下标（取自 MediaInfo::audioTracks）
     * @return 0 成功；非 0 失败（失败时会尽量保持原音轨可用）
     */
    virtual int32_t SwitchAudioTrack(int32_t streamIndex) { (void)streamIndex; return -1; }

    /**
     * 启用 / 关闭字幕轨
     *
     * @param streamIndex 字幕流下标；-1 表示关闭字幕
     * @return 0 成功；非 0 失败
     */
    virtual int32_t SetSubtitleTrack(int32_t streamIndex) { (void)streamIndex; return -1; }

    /**
     * 取"当前时刻该显示的字幕"
     *
     * @param out 有字幕时填充
     * @return true 表示当前有字幕要显示；false 表示这一时刻没有字幕
     *
     * 语义刻意做成"查询"而不是"事件"，理由见 SubtitleCue 的说明。
     */
    virtual bool GetActiveSubtitle(SubtitleCue &out) const { (void)out; return false; }

    /** 音频轨是否支持切换（文件里有多条可解码音轨） */
    virtual bool CanSwitchAudioTrack() const { return false; }

    /**
     * 色调调整（2026-10-04 新增）
     *
     * 七个参数都是**百分比**（-100 ~ +100，0 = 不改）：
     *   brightness 亮度、contrast 对比度、saturation 饱和度、
     *   hue 色彩度（±100% 对应 ±180°）、rGain/gGain/bGain 三个通道各自的增益。
     *
     * 默认实现什么都不做：系统 AVPlayer 通道的画面由系统渲染，
     * 播放器拿不到像素，那条路天然不支持（上层会给出提示）。
     */
    virtual void SetColorAdjust(int32_t brightness, int32_t contrast, int32_t saturation,
                                int32_t hue, int32_t rGain, int32_t gGain, int32_t bGain)
    {
        (void)brightness; (void)contrast; (void)saturation; (void)hue;
        (void)rGain; (void)gGain; (void)bGain;
    }

    /**
     * 均衡器（2026-10-04 新增）
     *
     * @param enabled  总开关；关掉时**完全不做处理**（零开销）
     * @param gainsDb  各段增益（dB，-12 ~ +12），长度由 count 给出
     * @param count    段数（上层固定传 10：60/170/310/600/1k/3k/6k/12k/14k/16kHz）
     *
     * 同样只有软解通道支持 —— AVPlayer 的音频由系统输出，插不进滤波器。
     */
    virtual void SetAudioEq(bool enabled, const int32_t *gainsDb, int32_t count)
    {
        (void)enabled; (void)gainsDb; (void)count;
    }

    /** 释放全部资源，之后不可再调用其它方法 */
    virtual void Release() = 0;
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_IPLAYER_ENGINE_H
