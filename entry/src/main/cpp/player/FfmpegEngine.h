#ifndef SOFT_PLAYER_FFMPEG_ENGINE_H
#define SOFT_PLAYER_FFMPEG_ENGINE_H

#include "IPlayerEngine.h"
#include "FfmpegTypes.h"
#include "FfmpegCodecApi.h"
#include "AudioOutput.h"

#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
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

    /**
     * 设置起播位置（毫秒），必须在 Prepare 之前调用
     *
     * 用途见 IPlayerEngine 里的说明：续播要在"打开之后、预渲染之前"就跳到位，
     * 否则预渲染出来的第一帧是文件开头那一帧。
     */
    void SetStartPositionMs(int64_t positionMs) override;
    int32_t Start() override;
    int32_t Pause() override;
    int32_t SeekTo(int64_t positionMs) override;
    int32_t SetSurface(const std::string &surfaceId) override;

    /** 色调调整（七项百分比，见 IPlayerEngine 说明）：随时可调用，立即生效 */
    void SetColorAdjust(int32_t brightness, int32_t contrast, int32_t saturation,
                        int32_t hue, int32_t rGain, int32_t gGain, int32_t bGain) override;

    /** 均衡器（10 段增益 dB）：随时可调用，下一块音频起生效 */
    void SetAudioEq(bool enabled, const int32_t *gainsDb, int32_t count) override;

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

    // ---------- 音轨 / 字幕（2026-09-29 新增）----------
    int32_t SwitchAudioTrack(int32_t streamIndex) override;
    int32_t SetSubtitleTrack(int32_t streamIndex) override;
    bool GetActiveSubtitle(SubtitleCue &out) const override;
    bool CanSwitchAudioTrack() const override;

private:
    /**
     * Prepare 的真正实现，带音轨 / 字幕轨选择
     *
     * 为什么单独抽一个带参数的内部版本：
     *   "切换音轨"的实现就是「用新的音轨下标重新走一遍 Prepare」。
     *   但公用 Prepare 还多了两件不该重复做的事：
     *     · 重建音频输出设备（会有一声爆音 + 华为设备上几百毫秒延迟）
     *     · 重新枚举轨道（其实没变）
     *   manageAudio=false 就是"换轨"路径，复用正在跑的音频设备。
     *
     * @param errMsg 失败时写入可读原因（换轨失败时由界面提示给用户）
     */
    int32_t PrepareWithTracks(const std::string &path, int32_t audioStreamIndex,
                              int32_t subtitleStreamIndex, bool manageAudio,
                              std::string &errMsg);

    /** 解码线程主体 */
    void DecodeLoop();

    /** 音频解码线程主体：把 PCM 持续喂进 AudioOutput 的环形缓冲 */
    void AudioLoop();

    /**
     * 字幕解码线程主体
     *
     * 为什么字幕要单独一条线程：
     *   字幕解码是"读队列 → 解析文本"的循环，与视频/音频都不共享状态。
     *   挂在视频线程上的话，一个文件如果有几万条字幕（很常见），
     *   视频解码每出一帧都要额外解析字幕，会把帧节奏带乱。
     *   单独线程 + 小队列，互不影响。
     */
    void SubtitleLoop();

    /**
     * 用新的音轨 / 字幕轨重新打开会话
     *
     * 这是"切换"的统一实现：停掉三条线程 → 关会话 → 按新下标重开 →
     * seek 回原位置 → 重启线程。成功返回 0。
     */
    int32_t ReopenWithTracks(int32_t audioIndex, int32_t subtitleIndex);

    /** 内部释放线程与会话（Release 与 ReopenWithTracks 共用） */
    void TearDownThreads();

    /** 渲染一帧到 surface，返回是否成功 */
    bool RenderFrame(VideoFrame &frame);

    /**
     * 取得某个 surface buffer 的可写映射（带缓存，2026-10-03）
     *
     * 为什么必须缓存：原实现是**每帧** mmap + munmap 一次 3.7MB 的 buffer。
     *   mmap 本身要建页表，munmap 还要做 TLB 失效；更要命的是新映射的页
     *   在第一次写入时逐页触发缺页异常 —— 1280x720 RGBA = 3.7MB ÷ 4KB
     *   ≈ 900 次缺页/帧。真机实测 RenderFrame 平均 8~13ms，其中大部分
     *   耗在这里，而不是那趟 memcpy。
     *
     * surface 只会循环使用固定的几块 buffer（每个 buffer 有各自的 fd），
     * 所以按 (fd, size) 缓存映射即可：每块只 mmap 一次，之后每帧白拿。
     *
     * @param handle 其实是 BufferHandle*（native_window/buffer_handle.h 里
     *        BufferHandle 是 typedef 出来的匿名字段结构，没法前向声明，
     *        所以这里用 void* 传，函数内再转回来）
     */
    void *MapSurfaceBuffer(void *handle);

    /** 清空映射缓存（窗口重建 / 释放时必须调用，否则会用到野映射） */
    void ClearSurfaceMapCache();

    /**
     * 清空帧队列，并把每帧的缓冲**还回解码器的缓冲池**
     *
     * ★ 2026-10-04：seek 时不能再用 FrameQueue::Clear() ——
     *   它只清长度、不回收缓冲，每 seek 一次就丢最多 8 块 3.7MB 缓冲，
     *   池子（上限 8）抽干后每帧都要现场分配（实测 80ms/帧 → 只有 8fps，
     *   表现为"拖几次进度条之后越来越卡"）。
     *   只在解码线程里调用（见 DecodeLoop 的 seek 处理段）。
     */
    void DrainFrameQueueRecycling();

    /* ==================== 色调 / 均衡器（2026-10-04 新增） ==================== */

    /**
     * 重建颜色变换矩阵（渲染线程调用，参数变化时触发一次）
     *
     * 为什么合成**一个** 3x3 矩阵 + 3 个偏移，而不是逐项做七次运算：
     *   每帧要处理 1280x720 = 92 万像素，逐项做就是七八遍遍历（每遍几十毫秒），
     *   而"对比度/通道增益/饱和度/色彩度"全是**线性**运算，可以按顺序相乘
     *   折叠成单个矩阵；亮度是常数偏移，也用矩阵的同一趟算掉。
     *   于是每像素只剩 9 次乘加，实测在 92 万像素上约十几毫秒
     *   —— 只有**开了色调**才会走这条路，参数全 0 时仍是原来的 memcpy。
     */
    void RebuildColorMatrix();

    /** 把当前是否"需要做颜色变换"的判断缓存下来（避免每帧重算矩阵） */
    void RefreshColorMatrixIfNeeded();

    /**
     * 音频均衡器：就地处理一块 S16 立体声数据（音频线程调用）
     *
     * 10 段 peaking biquad 串起来，频点与 Winamp 预设一致
     * （60/170/310/600/1k/3k/6k/12k/14k/16k）。
     * 全部增益为 0dB 或总开关关闭时**直接返回**，不产生任何计算。
     */
    void ApplyAudioEq(std::vector<uint8_t> &data);

    /** 按 eqGainDb_ 重建双二阶系数（音频线程内部调用，参数变化时一次） */
    void RebuildEqCoeffs();

    /** 内联的映射缓存项 */
    struct SurfaceMap {
        int fd = -1;
        int32_t size = 0;
        void *ptr = nullptr;
    };
    /** surface buffer 的映射缓存（少量项，线性查找足够） */
    std::vector<SurfaceMap> surfaceMaps_;

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

    /**
     * Prepare 之前设置好的起播位置（毫秒），< 0 表示从头播
     *
     * 为什么单独存一份而不是直接用 pendingSeekMs_：
     *   Prepare 时点还没开会话，SeekTo 会被"会话为空"直接拒绝；
     *   所以先把值存在这里，等会话建好、解码线程起来之前再转成一次内部 seek。
     */
    std::atomic<int64_t> startPositionMs_{-1};
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

    /** 时间基准重置日志已打印次数（坏时间戳导致基准被带偏时，见 DecodeLoop） */
    int32_t tsRealignLog_ = 0;

    /**
     * 上一次"为追进度而丢帧"的系统时刻（毫秒）
     *
     * 见 DecodeLoop 里的分档丢帧：真落后时允许丢帧，但丢帧间隔不得小于 200ms
     * （即最多 5 帧/秒），既能追上正常帧缺口，又不会在时钟异常时把整段丢光。
     */
    int64_t lastCatchUpDropMs_ = 0;
    /** 累计"追进度丢帧"次数（与"落后丢帧"分开计，便于区分原因） */
    std::atomic<int64_t> catchUpDrops_{0};

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
     * 上屏耗时细分（2026-10-03 加）
     *
     * 为什么要在 8~13ms 的"上屏均"里再拆一层：
     *   它可能来自三个完全不同的地方，而只有第一处能优化：
     *     · reqUs   —— RequestBuffer：拿不到空闲 buffer 时会**等合成器**，
     *                  这部分是等待，不是干活，优化代码没用；
     *     · mapUs   —— mmap/munmap + 首写缺页（已改为缓存，见 MapSurfaceBuffer）；
     *     · copyUs  —— 逐行 memcpy 3.7MB 进（通常是 uncached 的）显示缓冲；
     *     · flushUs —— FlushBuffer 送显，同样可能阻塞等合成器。
     *   不拆开就会把"等合成器"误判成"拷贝太慢"，然后去做一场
     *   毫无收益的零拷贝改造。
     */
    int64_t perfReqUs_ = 0;
    int64_t perfMapUs_ = 0;
    int64_t perfCopyUs_ = 0;
    int64_t perfFlushUs_ = 0;

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

    /**
     * seek 世代号：每次 SeekTo 递增
     *
     * 配合 renderedGen_ 表达"**当前播放位置的第一帧**还没上屏"这个状态。
     * 为什么要按世代算而不是"整场第一帧"（2026-10-03 实测踩到）：
     *   上层要求"先出画面再出声"，靠的是引擎报"首帧已上屏"。
     *   但续播流程是「READY → 上层发起 seek → 引擎预渲染」——
     *   如果只认整场第一帧，预渲染报上来的很可能是 **seek 之前**那一帧
     *   （文件开头，实测就是这样：先上屏 1 帧、20ms 后才 seek 到位），
     *   上层据此开播就会先闪一下开头，或者干脆误判。
     *   按世代算之后，"首帧"= 这个位置的第一帧，语义才对得上。
     */
    std::atomic<int64_t> seekGen_{0};
    /**
     * 已经渲染过的那一帧属于哪个 seek 世代；-1 表示还没有
     *
     * 只在解码线程里读写，不需要原子。
     */
    int64_t renderedGen_ = -1;
    /**
     * 最近一次 seek 的目标位置（毫秒）；-1 表示"没有 seek 过"
     *
     * 用途：刚 seek 完时滤掉流水线里残留的旧帧（pts 与目标对不上的），
     * 详见 DecodeLoop 里那段判断。
     */
    int64_t lastSeekTargetMs_ = -1;
    /** 已经因为"位置不符"丢掉多少帧（防呆上限，见 DecodeLoop） */
    int32_t staleFrameDropCount_ = 0;

    /**
     * 最近一次"成功解出视频帧"的时刻（毫秒，NowMs()）；0 = 还没解出过
     *
     * ★ 2026-10-04：解码停滞看门狗用的"喂狗"时间戳（见 DecodeLoop ①.5）。
     *   真机出现过解码器收下包却一帧不吐的病态（线程全睡、0% CPU、
     *   队列满着却没有任何输出），画面永远停在旧位置。
     *   有了这个时间戳就能检测出来，并用"重新 seek 一次"把解码器重开。
     */
    int64_t lastDecodeOkMs_ = 0;
    /** 最近一次执行"停滞恢复"的时刻（限速用，避免反复重 seek） */
    int64_t lastStallRecoverMs_ = 0;
    /** 当前"恢复风暴窗口"的起点（毫秒）；窗口内最多恢复若干次，防止 seek 循环 */
    int64_t stallStormStartMs_ = 0;
    /** 当前窗口内已经恢复了几次（窗口滚动时清零；满额后本窗口不再动作用） */
    int32_t stallRecoverCount_ = 0;

    /* ==================== 色调（画面颜色）状态 ==================== */

    /**
     * 七个色调参数（百分比 -100~100），由 UI 线程写、渲染线程读
     *
     * 用原子量而不是加锁：渲染线程每帧都要读，锁的开销和优先级反转风险
     * 都不值得；每个参数单独 4 字节对齐，读到的值最多是"差一帧的旧值"，
     * 对画面没有任何影响。
     */
    std::atomic<int32_t> colBrightness_{0};
    std::atomic<int32_t> colContrast_{0};
    std::atomic<int32_t> colSaturation_{0};
    std::atomic<int32_t> colHue_{0};
    std::atomic<int32_t> colRGain_{0};
    std::atomic<int32_t> colGGain_{0};
    std::atomic<int32_t> colBGain_{0};
    /** 参数版本号：UI 线程每改一次 +1，渲染线程据此判断要不要重建矩阵 */
    std::atomic<int32_t> colRev_{0};
    /** 渲染线程已经用过的版本号 */
    int32_t colSeenRev_ = -1;
    /** 合成后的颜色矩阵（16.16 定点，行主序 3x3）与常数偏移（同样是 16.16） */
    int32_t colM_[9] = {65536, 0, 0, 0, 65536, 0, 0, 0, 65536};
    int32_t colO_[3] = {0, 0, 0};
    /** 矩阵是否等于"恒等变换"（恒等时走原来的 memcpy 通路） */
    bool colIdentity_ = true;

    /* ==================== 均衡器状态 ==================== */

    /** 总开关 */
    std::atomic<bool> eqEnabled_{false};
    /** 各段增益（dB），UI 线程写、音频线程读 */
    std::atomic<int32_t> eqGainDb_[10];
    /** 参数版本号（同 colRev_ 的思路） */
    std::atomic<int32_t> eqRev_{0};
    /** 音频线程已经用过的版本号 */
    int32_t eqSeenRev_ = -1;
    /** 非平坦段数：0 表示可以整块跳过 */
    int32_t eqActiveBands_ = 0;
    /** 10 段的双二阶系数（归一化后） */
    double eqB0_[10] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    double eqB1_[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    double eqB2_[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    double eqA1_[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    double eqA2_[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    /** 滤波器状态： [声道 * 10 + 段] —— 只有音频线程访问 */
    double eqX1_[20] = {0};
    double eqX2_[20] = {0};
    double eqY1_[20] = {0};
    double eqY2_[20] = {0};

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

    /* ==================== 字幕（2026-09-29 新增） ==================== */

    /**
     * 已解出的字幕，按 startMs 升序
     *
     * 为什么要缓存整个列表而不是只留"当前一条"：
     *   用户随时可能往回拖进度条，往回拖之后需要立刻显示那个位置的字幕。
     *   只留一条的话必须重新解码整个区间的字幕流，会有明显延迟。
     *   缓存住就能瞬间响应。
     *
     * 上限见 kSubtitleCacheMax —— 超过就从头丢，因为往回拖很远是少数情况，
     * 而无限增长会让长片（几万条字幕）吃掉几 MB 内存。
     */
    std::deque<SubtitleCue> subtitleCues_;
    /** 保护 subtitleCues_ 的锁（字幕线程写、查询线程读） */
    mutable std::mutex subtitleMutex_;

    /** 字幕解码线程 */
    std::thread subtitleThread_;
    bool subtitleThreadStarted_ = false;
    /** 是否启用了字幕 */
    std::atomic<bool> subtitleEnabled_{false};

    /**
     * 字幕解码位置（毫秒），即 subtitleCues_ 里最后一条的结束时间
     *
     * 用途：GetActiveSubtitle 判断"当前没有字幕"时，要区分两种情况 ——
     *   · 当前位置的字幕还没解出来（需要等）
     *   · 这个区间本来就没有字幕（正常）
     * 用它做参照可以避免误判。
     */
    std::atomic<int64_t> subtitleDecodedUntilMs_{0};

    /** 诊断：已缓存字幕条数 */
    std::atomic<int64_t> subtitleCachedCount_{0};

    /**
     * 是否正在重开会话（换音轨 / 换字幕轨）
     *
     * 重开会依次"停三条线程 → 关会话 → 重开 → 重建线程"，
     * 中间有大量"半个状态"的时刻。两个重开并发进行的话，
     * 第二次会作用在第一次的中间状态上（例如往还没重建好的字幕线程
     * 里再赋一个 joinable 的 std::thread），直接触发 std::terminate。
     * 用这个标志把重开串行化：占用期间后续请求立即返回失败而不是排队
     * —— 排队也没意义，用户要的是"切到那条轨"，第二个请求的目标
     * 往往已经被第一个覆盖了。
     */
    std::atomic<bool> reopening_{false};
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_FFMPEG_ENGINE_H
