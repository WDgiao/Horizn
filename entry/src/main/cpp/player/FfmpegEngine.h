#ifndef SOFT_PLAYER_FFMPEG_ENGINE_H
#define SOFT_PLAYER_FFMPEG_ENGINE_H

#include "IPlayerEngine.h"
#include "FfmpegTypes.h"
#include "FfmpegCodecApi.h"
#include "AudioOutput.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

/** 前向声明，避免把 external_window.h 带进所有包含者 */
struct NativeWindow;

namespace softplayer {

/**
 * 基于 FFmpeg 的软解播放引擎
 *
 * 存在意义：系统 AVPlayer 在真机上实测只能解 H.264 / HEVC / MPEG-4 / MPEG-2 / H.263，
 *   连 asf(wmv)、realmedia(rm/rmvb)、ogg(ogv) 的解封装都不支持。
 *   要播 RMVB 必须自己解 —— 详见 `本机真实解码能力实测.md`。
 *
 * 线程模型（刻意简单，只有两条线程）：
 *
 *   ┌─ 控制线程（NAPI 调用的线程）──┐        ┌─ 解码线程 ─────────────┐
 *   │ Prepare / Start / Pause     │        │ 循环：                 │
 *   │ SeekTo / Release            │───────▶│  demux → decode        │
 *   │ 只改原子标志和队列，不阻塞   │        │  → FrameQueue          │
 *   └─────────────────────────────┘        └────────────────────────┘
 *
 * 为什么解码单独开线程：
 *   解码一次可能要几十毫秒（1080p 软解），放在控制线程里会让
 *   Play/Pause 这些调用卡住，ArkTS 侧看起来就是"点了没反应"。
 *
 * 为什么不下沉到"每路一条线程 + 音频时钟"的完整方案：
 *   当前目标是先让 RMVB 能播出画面。音频先用系统能力（或后续单独接），
 *   视频时钟先以系统单调时钟为准 —— 这足以验证"解码 + 上屏"这条主链路。
 *   等画面稳定了再加音频，比一上来就搭全套时钟要好调。
 *
 * 生命周期约定：
 *   Release() 后对象不可再用；析构里也会调一次 Release，保证不泄漏线程。
 */
class FfmpegEngine : public IPlayerEngine {
public:
    FfmpegEngine();
    ~FfmpegEngine() override;

    // 禁止拷贝：内部持有线程和裸句柄
    FfmpegEngine(const FfmpegEngine &) = delete;
    FfmpegEngine &operator=(const FfmpegEngine &) = delete;

    // ---------- IPlayerEngine 实现 ----------
    void SetCallback(EventCallback cb) override;
    int32_t Prepare(const std::string &path) override;
    int32_t Start() override;
    int32_t Pause() override;
    int32_t SeekTo(int64_t positionMs) override;
    int32_t SetSurface(const std::string &surfaceId) override;

    /**
     * 解绑 surface
     *
     * 实现要点：置空 surfaceId_ 并销毁 native window，全部在 surfaceMutex_ 下做，
     * 这样即使解码线程正卡在 RenderFrame 的临界区里，也会等它写完再销毁 ——
     * 不会出现"窗口已销毁但渲染函数还在用"的竞态。
     */
    int32_t DetachSurface() override;

    MediaInfo GetMediaInfo() const override;
    int64_t GetPositionMs() const override;
    void Release() override;

private:
    /** 解码线程主体 */
    void DecodeLoop();

    /** 音频解码线程主体：把 PCM 持续喂进 AudioOutput 的环形缓冲 */
    void AudioLoop();

    /** 渲染一帧到 surface，返回是否成功 */
    bool RenderFrame(VideoFrame &frame);

    /** 按 surfaceId 打开 native window（幂等） */
    bool EnsureWindow();

    /** 关闭 native window */
    void CloseWindow();

    /** 统一的事件上报出口，内部保证回调存在才调用 */
    void Emit(PlayerEvent type, int64_t data1, int64_t data2, const std::string &text);

    /** 置状态并发事件 */
    void SetState(PlayerState st);

    // ---------- 状态 ----------
    EventCallback callback_;

    /** 当前状态，控制线程写、解码线程读 */
    std::atomic<PlayerState> state_{PlayerState::IDLE};
    /** 是否处于播放中 */
    std::atomic<bool> playing_{false};
    /** 是否请求退出解码线程 */
    std::atomic<bool> quitting_{false};
    /** 待处理的 seek 目标（毫秒）；< 0 表示无 */
    std::atomic<int64_t> pendingSeekMs_{-1};
    /** 播放位置（毫秒），解码线程写 */
    std::atomic<int64_t> positionMs_{0};

    /** 媒体信息，Prepare 后只读 */
    MediaInfo info_;

    /** 解码线程 */
    std::thread decodeThread_;
    /** 解码线程是否已启动 */
    bool threadStarted_ = false;

    /** 解码出的帧队列（上限 8 帧：约 0.13 秒，足够平滑又不会延迟过大） */
    std::unique_ptr<FrameQueue> frameQueue_;
    /** 可打断睡眠，用于 pause/seek/release 立刻生效 */
    std::unique_ptr<InterruptibleSleep> sleeper_;

    /** FFmpeg 会话句柄（不透明） */
    codecapi::Session session_ = nullptr;
    /** 当前文件路径 */
    std::string path_;

    /** XComponent 的 surface id 字符串 */
    std::string surfaceId_;
    /** 由 surfaceId 创建出来的 native window */
    NativeWindow *nativeWindow_ = nullptr;
    /** surface 相关操作的互斥，避免 Prepare 与 SetSurface 竞争 */
    std::mutex surfaceMutex_;

    /** 时钟基准：上一帧的 pts 与对应的系统时间，用于算"这一帧该等多久" */
    int64_t lastFramePtsMs_ = -1;
    int64_t lastFrameSysMs_ = 0;

    /** 累计丢帧数（诊断用） */
    std::atomic<int64_t> droppedFrames_{0};
    /** sync 诊断日志已打印次数（只打印前几次"落后"，避免刷屏） */
    int32_t dropDbgCount_ = 0;

    /**
     * 性能统计（诊断用，2026-09-28 加）
     *
     * 为什么要分开统计解码与上屏：
     *   实测 720p 软解明显跟不上（前 30 帧花了约 4.7 秒），
     *   但"慢"可能来自三个完全不同的地方：
     *     ① FFmpeg 解码本身（rv20/av1 这类软解本来就重）
     *     ② sws_scale 缩放（我们要把 1280x720 缩到 1084x610 并转 RGBA）
     *     ③ RenderFrame 里拷进 surface buffer + 送显
     *   不分开量就只能靠猜。decodeUs 覆盖 ①②（都在 DecodeVideoFrame 内），
     *   renderUs 覆盖 ③。
     */
    int64_t perfDecodeUs_ = 0;
    int64_t perfRenderUs_ = 0;
    int64_t perfFrames_ = 0;

    /**
     * surface 实际分配的 buffer 尺寸（显示区域尺寸，不是视频尺寸）
     *
     * 由 RenderFrame 首次拿到 buffer 时探得，之后解码线程据此缩放画面。
     * 为什么要跨线程共享：缩放发生在解码阶段（FFmpeg 的 sws_scale），
     * 而 buffer 尺寸只有在渲染时才能从 BufferHandle 读到。
     * 用原子量避免加锁 —— 两个线程一个读一个写，且只关心"读到就够"。
     */
    std::atomic<int32_t> targetW_{0};
    std::atomic<int32_t> targetH_{0};

    /** 累计成功上屏的帧数（诊断用：区分"没渲染"与"渲染了但内容不对"） */
    std::atomic<int64_t> framesRendered_{0};

    /* ==================== 音频 ==================== */

    /**
     * 音频输出
     *
     * 为什么音频单独开一条线程：
     *   视频可以丢帧（丢一帧只是画面略卡），音频不能丢（丢了就是断音）。
     *   而且音频的数据量是视频的好几倍（48kHz 立体声 S16 = 192KB/s），
     *   若和视频挤在一条线程里，视频一次 seek/渲染卡顿就会让音频欠载爆音。
     *   所以两条线程各管各的，靠环形缓冲解耦。
     */
    std::unique_ptr<AudioOutput> audio_;
    /** 音频解码线程 */
    std::thread audioThread_;
    bool audioThreadStarted_ = false;
    /** 音频是否可用（文件有音频轨且解码器打开成功） */
    bool audioReady_ = false;

    /**
     * 已提交给输出的音频累计时长（毫秒）
     * 这是音频时钟的基准：音频"播到哪" = 已写入时长 − 缓冲里还没播的时长
     */
    std::atomic<int64_t> audioWrittenMs_{0};

    /**
     * 音频线程上一次上报位置的时间点（毫秒）
     *
     * 用途：纯音频文件没有视频线程，位置只能由音频线程上报。
     * 用 500ms 节流，避免每写一个 chunk 就发一次事件（chunk 可能只有几十毫秒）。
     */
    int64_t audioLastReportMs_ = 0;

    /**
     * seek 目标的绝对位置（毫秒），作为音频位置上报的偏移量
     *
     * 为什么需要它：audioWrittenMs_ 是【相对】基准（SeekTo 里会清零，
     * 原因见那里的注释）。而进度条要的是绝对位置，所以用
     * 「相对时钟 + 本偏移」还原。不这么做的话，seek 之后进度条会从 0 重新开始。
     */
    int64_t seekTargetMs_ = 0;
    /** 音频欠载累计次数（诊断：有没有断音） */
    std::atomic<int64_t> audioUnderruns_{0};
    /** 音频是否已播完（用于判断整片结束） */
    std::atomic<bool> audioEof_{false};
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_FFMPEG_ENGINE_H
