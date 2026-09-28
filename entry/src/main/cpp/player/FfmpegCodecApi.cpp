/**
 * FFmpeg 调用边界的实现
 *
 * 这个文件是**唯一**允许 include libav* 的地方。
 * 编译开关 SOFT_PLAYER_WITH_FFMPEG 未定义时，全部退化成返回 kNotIntegrated，
 * 于是整个原生模块在没有 FFmpeg 的情况下也能编过、能跑、能给出清晰错误。
 *
 * FFmpeg 产物的 configure 开关（依据真机实测的缺口清单，
 * 见 `本机真实解码能力实测.md`）：
 *
 *   容器/解封装  asf,rm,ogg,mov,matroska,avi,mpegts,flv,mpegps,...
 *                （asf → wmv/wma；rm → rm/rmvb；ogg → theora）
 *
 *   视频解码     rv10,rv20,rv30,rv40,wmv1,wmv2,wmv3,vc1,theora,
 *                vp8,vp9,av1,h264,hevc,mpeg4,mpeg2video,h263
 *                ★ rv30/rv40 是 GPL-only，本项目确定开源，故已启用
 *                  （RMVB 主流就是 RV40，不开这个等于白干）
 *
 *   音频解码     cook,wmav1,wmav2,wmapro,ac3,eac3,vorbis,aac,mp3,...
 *                ★ cook 是 RealAudio，RMVB 标配；实测系统就是卡在 ac3/wmav2
 *                  这些音频上（DEM_FMT_ERR），所以音频解码器一个都不能少
 *
 *   解析器       rv30,rv40,vc1,mpeg4video,h264,hevc,theora,vp8,vp9,av1,...
 *                （没有 parser，很多流会解不出来）
 */

#include "FfmpegCodecApi.h"

#ifdef SOFT_PLAYER_WITH_FFMPEG

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <cstring>
#include <cmath>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#endif  // SOFT_PLAYER_WITH_FFMPEG

#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "SoftPlayerCodec"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)
#define LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)

namespace softplayer {
namespace codecapi {

#ifdef SOFT_PLAYER_WITH_FFMPEG

/**
 * 有界包队列（解复用线程 → 解码线程 的单向通道）
 *
 * ★ 为什么要引入它（2026-09-29 的架构性修复）：
 *
 *   FFmpeg 官方明确说明 AVFormatContext **不是线程安全的**。
 *   而在此之前，视频解码线程和音频解码线程各自调用 av_read_frame()
 *   读同一个 fmtCtx —— 这是违背设计的用法。之前靠 demuxMutex + 包副本
 *   打了两层补丁，仍然出问题：
 *
 *     实测：720p VP9 + Opus（.webm）→ 第 10 个包就被解码器拒绝，
 *           报 AVERROR_INVALIDDATA，一帧都上不了屏；
 *           而把**同一份 VP9 帧数据**去掉音轨后 → 完美播放（19 fps）。
 *           VP8 + Opus 却完全正常 —— 也就是只有「VP9 + 有音频」会炸。
 *
 *   改成「单解复用线程 + 双队列」之后，av_read_frame 全进程只被
 *   一条线程调用，从根上消除了这类竞态 —— 不再依赖锁的粒度正确。
 *
 * 为什么要限制容量：解复用远比解码快，不设上限会把整个文件读进内存。
 * 队列满时解复用线程阻塞等待，天然形成背压。
 *
 * 注意：本类型定义在匿名命名空间【之外】—— 因为 DecoderSession
 * 也定义在命名空间之外，它要按值持有本类型；放进去会「未声明」。
 */
struct PacketQueue {
    std::mutex mutex;
    std::condition_variable notEmpty;
    std::condition_variable notFull;
    /** 队列中的包（每个都是独立引用） */
    std::deque<AVPacket *> packets;
    /** 容量上限 */
    size_t limit = 512;
    /** 生产者已结束（到达文件尾） */
    bool eof = false;
    /** 会话正在关闭：唤醒所有等待者并让它们退出 */
    bool abort = false;

    ~PacketQueue() {
        for (AVPacket *p : packets) {
            av_packet_free(&p);
        }
        packets.clear();
    }

    /**
     * 生产者放入一个包（会拷贝 src，调用方随后可自由 unref src）
     * 队列满时阻塞等待消费者腾出空间
     * @return false 表示会话中止，应停止生产
     */
    bool Push(AVPacket *src) {
        AVPacket *copy = av_packet_alloc();
        if (copy == nullptr) {
            return false;
        }
        if (av_packet_ref(copy, src) < 0) {
            av_packet_free(&copy);
            return false;
        }
        std::unique_lock<std::mutex> lock(mutex);
        notFull.wait(lock, [this] { return abort || packets.size() < limit; });
        if (abort) {
            lock.unlock();
            av_packet_free(&copy);
            return false;
        }
        packets.push_back(copy);
        lock.unlock();
        notEmpty.notify_one();
        return true;
    }

    /** 标记生产者结束 */
    void SetEof() {
        std::lock_guard<std::mutex> lock(mutex);
        eof = true;
        notEmpty.notify_all();
    }

    /** 中止：唤醒所有等待者 */
    void Abort() {
        std::lock_guard<std::mutex> lock(mutex);
        abort = true;
        notEmpty.notify_all();
        notFull.notify_all();
    }

    /** 清空（seek 后调用，丢弃旧位置的包） */
    void Clear() {
        std::lock_guard<std::mutex> lock(mutex);
        for (AVPacket *p : packets) {
            av_packet_free(&p);
        }
        packets.clear();
        eof = false;
        notFull.notify_all();
    }

    /**
     * 消费者取一个包；内部把包的引用转移给 out，并释放队列里那个壳
     * @param timeoutMs 队列为空时最多等待多久
     * @return kOk 取到；kAgain 超时/被中止且队列空；kEof 生产结束且已取空
     */
    int32_t Pop(AVPacket *out, int timeoutMs) {
        std::unique_lock<std::mutex> lock(mutex);
        if (packets.empty()) {
            notEmpty.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                              [this] { return abort || eof || !packets.empty(); });
        }
        if (!packets.empty()) {
            AVPacket *p = packets.front();
            packets.pop_front();
            av_packet_unref(out);
            av_packet_move_ref(out, p);
            av_packet_free(&p);
            lock.unlock();
            notFull.notify_one();
            return kOk;
        }
        if (abort) {
            return kAgain;
        }
        if (eof) {
            return kEof;
        }
        return kAgain;
    }
};

/**
 * 中断回调：让阻塞中的 av_read_frame 能被打断
 *
 * FFmpeg 约定：回调返回非 0 表示「请中止当前 I/O」。
 * 用途见 DecoderSession::demuxAbort —— Close 时要 join 解复用线程，
 * 而它可能正卡在文件 I/O 上，没有中断回调就会一直等。
 */
int InterruptCallback(void *opaque) {
    auto *flag = static_cast<std::atomic<bool> *>(opaque);
    return (flag != nullptr && flag->load()) ? 1 : 0;
}

namespace {

/**
 * 采样实测「每秒码率」，用于给没有时长的裸流估时长
 *
 * 为什么不直接用常数（这是踩过的坑）：
 *   DTS-HD MA 是**无损**编码，第一版按理论 PCM 码率算
 *      声道数 × 位深 × 采样率
 *   实测三个真实样本后发现有损 core 层是**叠加**在无损层上的额外开销，
 *   真实码率与理论值的比值跨度极大：
 *        MA 2.0 / 16bit : 1,776,507 / 1,536,000 = 1.16  （core 开销占主导）
 *        MA 5.1 / 24bit : 4,055,242 / 6,912,000 = 0.59  （压缩明显）
 *        MA 7.1 / 24bit : 7,662,835 / 9,216,000 = 0.83
 *   任何一元常数都不可能同时拟合这三点，所以改成实测。
 *
 * 做法：另开一个解复用器读开头若干包，量出
 *     「这段字节数」对应的「精确时长」
 * 两者相除就是真实平均码率，再拿文件总大小外推总时长。
 * 只读开头几百个包（不到一秒的 I/O），不会拖慢打开速度。
 *
 * @param path      文件路径
 * @param maxProbe  最多读多少个包（取到就够了，不必读完整个文件）
 * @return 实测码率（bps）；测不出来返回 0
 */
int64_t MeasureStreamBitRate(const std::string &path, int maxProbe) {
    AVFormatContext *fmt = nullptr;
    if (avformat_open_input(&fmt, path.c_str(), nullptr, nullptr) < 0) {
        return 0;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        avformat_close_input(&fmt);
        return 0;
    }

    // 找第一条音频流（纯音频文件场景，一般为 0 号流）
    const int aIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (aIdx < 0) {
        avformat_close_input(&fmt);
        return 0;
    }
    const AVRational tb = fmt->streams[aIdx]->time_base;
    const int frameSize = fmt->streams[aIdx]->codecpar->frame_size;
    const int sampleRate = fmt->streams[aIdx]->codecpar->sample_rate;

    AVPacket *pkt = av_packet_alloc();
    if (pkt == nullptr) {
        avformat_close_input(&fmt);
        return 0;
    }

    int64_t firstPos = -1;
    int64_t lastPos = -1;
    int64_t firstPts = AV_NOPTS_VALUE;
    int64_t lastPts = AV_NOPTS_VALUE;
    int64_t packets = 0;
    // 时间戳缺失时用 frame_size 累加出来的时长兜底（dca 的 frame_size 是
    // 「每帧样本数」，即 core 帧的 PCM 块数，对 DTS 通常是 512）
    int64_t synthSamples = 0;

    while (packets < maxProbe && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == aIdx) {
            if (firstPos < 0) {
                firstPos = pkt->pos;
            }
            if (pkt->pos >= 0) {
                lastPos = pkt->pos + pkt->size;
            }
            if (pkt->pts != AV_NOPTS_VALUE) {
                if (firstPts == AV_NOPTS_VALUE) {
                    firstPts = pkt->pts;
                }
                lastPts = pkt->pts;
            }
            if (frameSize > 0) {
                synthSamples += frameSize;
            }
            packets++;
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    avformat_close_input(&fmt);

    if (packets <= 0) {
        return 0;
    }

    // 字节跨度优先用实测的包位置差；拿不到就用「包数 × 平均包大小」不可靠，
    // 这里直接退回失败，让调用方保持"时长未知"而不是给一个错得离谱的值
    if (firstPos < 0 || lastPos <= firstPos) {
        return 0;
    }
    const int64_t byteSpan = lastPos - firstPos;

    int64_t durationMs = 0;
    if (firstPts != AV_NOPTS_VALUE && lastPts != AV_NOPTS_VALUE
        && lastPts > firstPts) {
        durationMs = av_rescale_q(lastPts - firstPts, tb, AVRational{1, 1000});
    } else if (synthSamples > 0 && sampleRate > 0) {
        durationMs = synthSamples * 1000 / sampleRate;
    }
    if (durationMs <= 0) {
        return 0;
    }

    // 每毫秒字节数 -> bps
    return byteSpan * 8 * 1000 / durationMs;
}

/**
 * 统一的音频输出格式
 *
 * 为什么固定成 48kHz / 立体声 / S16LE：
 *   片源格式五花八门（RMVB 里 cook 常见 22050Hz 单声道，AC3 常见 48kHz 5.1），
 *   而音频设备只接受一个固定配置。统一转换之后，播放器只有一条音频路径，
 *   不用每次按片源重建音频流，设备兼容性也最好。
 */
constexpr int32_t kAudioSampleRate = 48000;
constexpr int32_t kAudioChannels = 2;

/**
 * 字幕兜底显示时长（毫秒）
 *
 * 用于"容器只给开始时间、不给持续时间"的字幕包（MKV / MP4 里的文本字幕
 * 大多如此）。取 4 秒的理由：真人语速读一行字幕通常 1.5~3 秒，4 秒足够
 * 覆盖绝大多数情况；而偏长是无害的 —— 播放器在匹配到下一条字幕时会把
 * 当前这条替换掉，不会两条同时挂着（见引擎侧的匹配逻辑）。
 */
constexpr int64_t kSubtitleFallbackMs = 4000;

/**
 * 一次会话的全部 FFmpeg 状态
 *
 * 命名注意：不能叫 Session —— 那会和公开接口里的
 * `using Session = void*`（codecapi 命名空间）撞名，
 * 编译器会报 "reference to 'Session' is ambiguous"。
 * 所以内部结构体统一叫 DecoderSession。
 */
struct DecoderSession {
    AVFormatContext *fmtCtx = nullptr;
    AVCodecContext *videoCtx = nullptr;
    int videoStreamIndex = -1;

    /**
     * 解复用后待解码的包
     *
     * ★ 视频与音频必须各用各的 AVPacket，绝不能共用一个！
     *
     *   这是一次真实 bug 的教训（两轮才定位到）：
     *   第一轮发现两条线程并发调用 av_read_frame() 读同一个 AVFormatContext，
     *   加了 demuxMutex 保护 fmtCtx —— 但那只解决了一半问题：
     *   两条线程当时还共用同一个 s->packet 对象。
     *
     *   avcodec_send_packet() 并**不保证**拷贝包数据（解码器可以直接持有
     *   这块缓冲的引用，返回 0 后仍在读它）。所以：
     *     视频线程 send 完 → 音频线程立刻在同一对象上 av_read_frame
     *     → 解码器正在读的内存被覆盖 → 解出乱码或报
     *       "avcodec_send_packet: Invalid data found when processing input"
     *     → 严重时直接段错误（历史崩溃日志里那几次 libavformat/libavcodec 崩溃）。
     *
     *   锁只能串行化"谁在读"，无法阻止"后一次读覆盖前一次的数据" ——
     *   因为覆盖发生在锁释放之后，而解码器还在用那块内存。
     *   所以：一个线程一个 packet，这是唯一正确的做法。
     */
    AVPacket *packet = nullptr;
    /** 音频线程专用的包（与 packet 分开，避免互相覆盖） */
    AVPacket *audioPacket = nullptr;
    /**
     * 视频解码专用的私有副本
     *
     * ★ 为什么还要再来一份（2026-09-29 定位到的 bug）：
     *   上面的注释说「不保证拷贝包数据」，但当时的修法只做到
     *   「视频/音频各用一个 packet 对象」—— 这还不够，因为
     *   【送包发生在 demuxMutex 锁外】：
     *     视频线程：锁内 av_read_frame 写入 packet → 解锁
     *               → 锁外 avcodec_send_packet(packet)
     *     音频线程：此刻拿到锁，av_read_frame 可能复用同一块底层缓冲
     *   FFmpeg 的 avcodec_send_packet 不保证拷贝，解码器返回后仍在读它，
     *   于是解码器读到的是被音频线程改写过的数据。
     *
     *   实测证据：
     *     · 带音轨的 720p VP9（.webm）→ 第 10 个包被解码器拒绝，
     *       报 AVERROR_INVALIDDATA(-1094995529)，一帧都上不了屏
     *     · 同一编码、同分辨率、**去掉音轨** → 完美播放，已上屏 120 帧
     *     唯一差别就是有没有第二条线程在读同一个 AVFormatContext。
     *
     *   修法：锁内 av_packet_ref 拷一份到这里，锁外只操作这份副本。
     */
    AVPacket *videoPacket = nullptr;

    /** 解码器输出的原始帧 */
    AVFrame *rawFrame = nullptr;
    /** 需要色彩转换/缩放时用的中间帧（目标是 RGBA8888） */
    AVFrame *convFrame = nullptr;
    /** 色彩转换上下文，按需创建 */
    SwsContext *sws = nullptr;
    /** 当前 sws 的源格式与尺寸，变化时要重建 */
    int swsSrcFmt = -1;
    int swsSrcW = 0;
    int swsSrcH = 0;
    /** 当前 sws 的目标尺寸，与源尺寸一起决定"要不要重建" */
    int swsDstW = 0;
    int swsDstH = 0;

    /** 流时间基，用于把 pts 换算成毫秒 */
    AVRational timeBase{1, 1000};

    // ---------- 音频相关 ----------
    /** 音频解码器上下文；文件没有音频轨时为 nullptr */
    AVCodecContext *audioCtx = nullptr;
    int audioStreamIndex = -1;
    /** 音频流时间基 */
    AVRational audioTimeBase{1, 1000};
    /** 解码器输出的音频帧 */
    AVFrame *audioFrame = nullptr;
    /** 重采样上下文：把任意格式转成 S16LE/立体声/48kHz */
    SwrContext *swr = nullptr;
    /** 重采样后的临时缓冲（交错 S16LE） */
    uint8_t *resampleBuf = nullptr;
    int resampleBufSize = 0;

    /**
     * 解复用器互斥锁
     *
     * ★ 这个锁是必需的，不是保守起见 —— 它对应的是一次真实的崩溃：
     *
     *   现象：反复打开/关闭 .rm 文件会闪退
     *   崩溃日志：SIGSEGV(SEGV_MAPERR)@0xb8, NULL pointer dereference
     *             #00 libavformat.so.61
     *             #02 FfmpegEngine::DecodeLoop()
     *   根因：视频解码线程（DecodeLoop）和音频解码线程（AudioLoop）
     *         各自调用了 av_read_frame()，而它们操作的是**同一个 AVFormatContext**。
     *
     *   FFmpeg 的 AVFormatContext 不是线程安全的：它内部维护读缓冲、
     *   packet 位置、demuxer 私有状态机。两个线程同时读会互相踩坏这些状态，
     *   之后某个指针就成了野指针/空指针，一访问就崩。
     *   .rm 的解复用器内部状态比 mp4 复杂得多，所以只有 .rm 能稳定复现。
     *
     * 保护范围：所有会改动 fmtCtx 内部状态的操作（av_read_frame / av_seek_frame）
     * 注意不保护 avcodec_* —— 视频与音频各有独立的 AVCodecContext，
     * 那些本来就该并行，锁住反而会拖慢解码。
     */
    std::mutex demuxMutex;

    // ---------- 单解复用线程 + 双队列（2026-09-29 架构修复）----------
    /**
     * 视频包队列 / 音频包队列
     *
     * 由 demuxThread 独占生产，分别由视频解码线程、音频解码线程消费。
     * 这样 av_read_frame 全进程只被一条线程调用 —— 从根上满足
     * 「AVFormatContext 不是线程安全的」这条约束，不再依赖锁的粒度。
     * 详见 PacketQueue 的说明。
     */
    std::unique_ptr<PacketQueue> videoQueue;
    std::unique_ptr<PacketQueue> audioQueue;
    /**
     * 字幕包队列
     *
     * 只在 selectedSubtitleIndex >= 0 时创建并投递。没选字幕轨时
     * 解复用线程仍然会读到字幕包（容器里就是有这些包），但直接丢弃 ——
     * 不建队列、不占内存，也就没有解码开销。
     */
    std::unique_ptr<PacketQueue> subtitleQueue;
    /** 专职解复用线程 */
    std::thread demuxThread;
    /** 线程对象是否已创建（决定要不要 join） */
    std::atomic<bool> demuxThreadStarted{false};

    // ---------- 字幕（2026-09-29 新增）----------
    /**
     * 字幕解码器上下文
     *
     * 这里有个必须写下来的结论：**本构建的 FFmpeg 没有编入任何字幕解码器**。
     * 回读 config_components.h 全是 0：
     *     CONFIG_SUBRIP_DECODER 0 / CONFIG_ASS_DECODER 0 /
     *     CONFIG_MOVTEXT_DECODER 0 / CONFIG_WEBVTT_DECODER 0 /
     *     CONFIG_TEXT_DECODER 0 / CONFIG_SSA_DECODER 0
     * 所以 subtitleCtx **实际上一直是 nullptr**，走的是下面 SelfDecodeSubtitle()
     * 那条自实现的解析路径。
     *
     * 保留这个字段而不是删掉，是为了：
     *   ① 将来若重编 FFmpeg 带上字幕解码器，改一处就能切回官方解码器；
     *   ② 代码意图清楚 —— 「优先用官方解码器、没有才自己解」。
     */
    AVCodecContext *subtitleCtx = nullptr;
    int subtitleStreamIndex = -1;
    /** 字幕流时间基 */
    AVRational subtitleTimeBase{1, 1000};
    /** 字幕解码器输出的帧（仅当 subtitleCtx 非空时使用） */
    AVFrame *subtitleFrame = nullptr;
    /**
     * 自实现解析用的 AVPacket 容器
     *
     * 与 videoPacket / audioPacket 同理：每个消费者必须有自己的一份。
     * 见上面那段"一个线程一个 packet"的说明。
     */
    AVPacket *subtitlePacket = nullptr;
    /** 诊断用：已产出的字幕条数 */
    int32_t subtitleCount = 0;

    /**
     * 待执行的 seek 目标（毫秒），-1 表示没有
     *
     * seek 不能在调用线程里直接做 —— av_seek_frame 会重置 fmtCtx 的
     * 读位置与内部缓冲，必须由独占 fmtCtx 的解复用线程执行。
     * 这里只是个「请求信箱」，解复用线程每轮开头取走。
     */
    std::atomic<int64_t> pendingSeekMs{-1};

    /**
     * 解复用线程的致命错误（av_read_frame 返回真错误时记下）
     * 0 表示无错。解码线程看到它就直接报错，避免静默卡死。
     */
    std::atomic<int32_t> demuxError{0};

    /**
     * 关闭标志：置位后中断回调会让阻塞中的 av_read_frame 立即返回
     *
     * 为什么必须有它：Close 时要 join 解复用线程，而那条线程可能正卡在
     * 文件 I/O 上（首次读盘、网络文件、慢速存储都可能阻塞较久）。
     * 没有中断回调的话 join 会一直等 —— 表现为「退出播放页卡住」。
     */
    std::atomic<bool> demuxAbort{false};

    /**
     * 诊断用：已打印的视频包个数（只打前几个，避免刷屏）
     *
     * 定位「VP9 拒绝包」那个问题时，正是靠把「正常包」与「被拒包」
     * 的 size / pts / 首字节放在一起对照，才确认码流本身没问题、
     * 问题出在帧数据被并发改写。
     */
    int32_t dbgPacketCount = 0;
    /** 诊断用：最近一个视频包的快照（unref 后字段就没了） */
    int32_t dbgLastSize = 0;
    int64_t dbgLastPts = 0;
    int32_t dbgLastFlags = 0;

    // ---------- 时间戳兜底用 ----------
    /**
     * 已解出的视频帧数
     *
     * 用途：某些容器/编码（实测 .rm 的 RealVideo）里帧的 pts/dts **全部缺失**，
     * 只能按帧序 × 帧间隔合成时间轴，否则时间轴恒为 0。
     */
    int64_t frameCounter = 0;
    /**
     * 默认帧间隔（毫秒），来自流帧率；取不到时退回 40ms（25fps）
     *
     * 为什么必须有这个兜底：帧 pts 全缺时，播放器只能靠帧序推算时间，
     * 而推算需要知道每帧该占多久。
     */
    double defaultFrameMs = 40.0;
};

/** 把解码器的错误码转成可读文本 */
std::string AvErr(int err) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, buf, sizeof(buf));
    return std::string(buf);
}

// ==================== 字幕支持（2026-09-29 新增） ====================
//
// ★ 先写清楚为什么这里要"自己解字幕"，而不是调 avcodec：
//
//   回读本构建的 config_components.h，**所有字幕解码器都是 0**：
//       CONFIG_SUBRIP_DECODER 0    CONFIG_ASS_DECODER 0
//       CONFIG_SSA_DECODER 0       CONFIG_MOVTEXT_DECODER 0
//       CONFIG_WEBVTT_DECODER 0    CONFIG_TEXT_DECODER 0
//       CONFIG_DVDSUB_DECODER 0    CONFIG_PGSSUB_DECODER 0
//   也就是说 avcodec_find_decoder(AV_CODEC_ID_SUBRIP) 会返回 nullptr，
//   这条路根本走不通。
//
//   两条备选：
//     (a) 重编 FFmpeg 带上 --enable-decoder=subrip,ass,ssa,mov_text,webvtt,text
//     (b) 自己做文本字幕的解析
//
//   选了 (b)，理由是**风险与收益不成比例**：
//     · 文本字幕的"解码"本质就是把包里的字节转成字符串，再按各自格式
//       取一下起止时间。subrip / mov_text / webvtt / ASS 四种格式的解析
//       加起来不到两百行，而且完全在我们自己代码里，不会被 FFmpeg
//       版本变化或组件开关影响。
//     · 重编 FFmpeg 要动已经验证过的 .so（AV1/VP9/RV/DTS 都测过了），
//       一次配置漂移就可能悄悄改掉别的东西 —— 之前已经吃过一次
//       "两个 configure 脚本漂移"的亏。
//     · 唯一真正需要 FFmpeg 的是**位图字幕**（PGS / VobSub / DVB），
//       那需要按调色板还原成图片再叠加，成本高得多，本次不做。
//
//   所以：文本字幕自解析，位图字幕明确列为"不支持"。

/**
 * 字幕编码 → 是否支持（文本型）+ 显示名
 *
 * @param codecId 流里的编码
 * @param outName 输出：界面展示用的短名
 * @return true 表示能用 SelfDecodeSubtitle 解出文本
 */
bool IsTextSubtitleCodec(AVCodecID codecId, std::string &outName) {
    switch (codecId) {
        case AV_CODEC_ID_SUBRIP:  outName = "SRT";      return true;
        case AV_CODEC_ID_ASS:     outName = "ASS";      return true;
        case AV_CODEC_ID_SSA:     outName = "SSA";      return true;
        case AV_CODEC_ID_MOV_TEXT:outName = "MP4文字";  return true;
        case AV_CODEC_ID_WEBVTT:  outName = "WebVTT";   return true;
        case AV_CODEC_ID_TEXT:    outName = "文本";     return true;
        // 以下都是位图字幕：列出来但标记不支持，让用户知道"轨道在、但放不了"
        case AV_CODEC_ID_HDMV_PGS_SUBTITLE: outName = "PGS图形";   return false;
        case AV_CODEC_ID_DVD_SUBTITLE:      outName = "DVD图形";   return false;
        case AV_CODEC_ID_DVB_SUBTITLE:      outName = "DVB图形";   return false;
        case AV_CODEC_ID_XSUB:              outName = "XSUB图形";  return false;
        default:
            outName = "未知字幕";
            return false;
    }
}

/**
 * 把 "00:01:23,456" / "00:01:23.456" / "1:23:45.6" 这类时间串转成毫秒
 *
 * 为什么自己写而不调 av_parse_time：
 *   这些字幕时间串的格式比 av_parse_time 支持的更宽松（毫秒位数不定、
 *   小时位可能只有一位、分隔符是逗号或点），自己按冒号切最稳。
 *
 * @return 毫秒；解析失败返回 -1
 */
int64_t ParseSubtitleTime(const std::string &s) {
    // 先去掉首尾空白
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) {
        return -1;
    }
    size_t e = s.find_last_not_of(" \t\r\n");
    std::string t = s.substr(b, e - b + 1);
    // 逗号统一成点，方便后面统一处理小数
    for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == ',') {
            t[i] = '.';
        }
    }

    // 按冒号切，最后一段带小数
    std::vector<std::string> parts;
    size_t start = 0;
    while (true) {
        const size_t colon = t.find(':', start);
        if (colon == std::string::npos) {
            parts.push_back(t.substr(start));
            break;
        }
        parts.push_back(t.substr(start, colon - start));
        start = colon + 1;
        if (parts.size() > 3) {
            return -1;   // 冒号太多，不是时间
        }
    }
    if (parts.size() < 2 || parts.size() > 3) {
        return -1;
    }

    // 解析 "秒.毫秒"
    const size_t dot = parts.back().find('.');
    std::string secStr = (dot == std::string::npos) ? parts.back()
                                                    : parts.back().substr(0, dot);
    std::string msStr = (dot == std::string::npos) ? "" : parts.back().substr(dot + 1);

    // 全部必须是数字，否则不是时间（避免把正文误判成时间）
    auto allDigits = [](const std::string &x) {
        if (x.empty()) {
            return false;
        }
        for (char c : x) {
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    };
    if (!allDigits(secStr) || (!msStr.empty() && !allDigits(msStr))) {
        return -1;
    }

    int64_t hours = 0;
    int64_t minutes = 0;
    int64_t seconds = 0;
    try {
        if (parts.size() == 3) {
            if (!allDigits(parts[0]) || !allDigits(parts[1])) {
                return -1;
            }
            hours = std::stoll(parts[0]);
            minutes = std::stoll(parts[1]);
        } else {
            minutes = std::stoll(parts[0]);
        }
        seconds = std::stoll(secStr);
    } catch (...) {
        return -1;
    }

    // 毫秒：把小数部分补齐/截断到 3 位
    int64_t millis = 0;
    if (!msStr.empty()) {
        std::string m = msStr;
        if (m.size() > 3) {
            m = m.substr(0, 3);
        }
        while (m.size() < 3) {
            m += '0';
        }
        try {
            millis = std::stoll(m);
        } catch (...) {
            millis = 0;
        }
    }

    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis;
}

/**
 * 清洗字幕文本
 *
 * 做三件事：
 *   ① 去掉 ASS/SSA 的样式覆写标签 {\...}（例如 {\an8}{\pos(320,50)}）
 *   ② 把 ASS 的硬换行 \N 和 \n 换成真换行
 *   ③ 去掉 HTML 风格标签（<i> <b> <font ...>）—— WebVTT 和部分 SRT 里有
 *
 * 为什么不做完整 ASS 渲染：本构建没有 libass（CONFIG_ASS_DECODER=0，
 * 且 libass 在 HarmonyOS 上还依赖字体配置）。取舍是明确的：
 * **能看到字幕文字** 比 **还原字体/位置/描边** 重要得多。
 */
std::string CleanSubtitleText(const std::string &in) {
    std::string out;
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); i++) {
        const char c = in[i];
        if (c == '{') {
            // 跳到匹配的 '}'；ASS 的标签不允许嵌套
            const size_t close = in.find('}', i + 1);
            if (close == std::string::npos) {
                break;              // 没有闭合，后面全是标签残渣，丢掉
            }
            i = close;
            continue;
        }
        if (c == '\\' && i + 1 < in.size()) {
            const char n = in[i + 1];
            if (n == 'N' || n == 'n') {
                out += '\n';
                i++;
                continue;
            }
            if (n == 'h') {         // \h 是 ASS 的不换行空格
                out += ' ';
                i++;
                continue;
            }
        }
        if (c == '<') {
            const size_t close = in.find('>', i + 1);
            // 只在看起来像标签时才跳过，避免把正文里的 "a < b" 吃掉
            if (close != std::string::npos && close - i <= 32) {
                i = close;
                continue;
            }
        }
        if (c == '\r') {
            continue;
        }
        out += c;
    }
    // 去掉首尾空白
    const size_t b = out.find_first_not_of(" \t\n");
    if (b == std::string::npos) {
        return std::string();
    }
    const size_t e = out.find_last_not_of(" \t\n");
    return out.substr(b, e - b + 1);
}

/**
 * 自实现字幕解析：把一个字幕包的原始字节解成 (startMs, endMs, text)
 *
 * 支持四种容器里常见的存放方式：
 *
 *   ① MKV 里的 SRT / ASS/SSA
 *      MKV 把每条字幕存成一个包，文本明文放在包数据里。
 *      ASS 包形如：  "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
 *      注意它**没有起止时间** —— 时间在容器的时间戳里（用包的 pts）。
 *      所以 endMs 只能靠"下一条的开始"来补（见 pendingSubtitle* 字段）。
 *
 *   ② MP4 / MOV 里的 mov_text
 *      包数据是 "2字节大端长度 + UTF-8 文本"，同样没有持续时间，
 *      时间来自包的 pts / duration。
 *
 *   ③ 独立的 SRT 文本（整块，含 "序号 / 时间行 / 正文"）
 *      起止时间都在文本里，直接解析。
 *
 *   ④ WebVTT 文本块（形如 "00:00:01.000 --> 00:00:04.000"）
 *
 * ★ 关键设计：包的 pts 是**权威时间**。文本里若自带时间行（情况 ③④），
 *   那只在 pts 不可用时才用 —— 否则会出现"字幕时间被文本里的时间覆盖"
 *   与"容器时间"打架的情况（实测 MKV 里的 SRT 包同时带 pts 和内嵌时间行）。
 *
 * @param data      包数据
 * @param size      字节数
 * @param ptsMs     包的显示时间戳（毫秒）；AV_NOPTS_VALUE 表示没有
 * @param durMs     包的持续时间（毫秒）；<=0 表示未知
 * @param out       输出字幕事件
 * @return true 解出了一条有效字幕
 */
bool SelfDecodeSubtitle(const uint8_t *data, int size, int64_t ptsMs, int64_t durMs,
                        softplayer::SubtitleEvent &out) {
    if (data == nullptr || size <= 0) {
        return false;
    }

    // 转成字符串（文本字幕都是 UTF-8 或 Latin-1；这里按字节处理，
    // 中文的正常情况是 UTF-8，原样传给 ArkTS 即可）
    std::string raw(reinterpret_cast<const char *>(data), static_cast<size_t>(size));

    // 去掉结尾的 NUL（mov_text 的填充字节）
    while (!raw.empty() && raw.back() == '\0') {
        raw.pop_back();
    }
    if (raw.empty()) {
        return false;
    }

    int64_t startMs = (ptsMs == AV_NOPTS_VALUE) ? -1 : ptsMs;
    int64_t endMs = (durMs > 0 && startMs >= 0) ? (startMs + durMs) : 0;
    std::string text;

    // ---- ② mov_text：2 字节大端长度前缀 ----
    if (size >= 2) {
        const int len = (static_cast<int>(data[0]) << 8) | static_cast<int>(data[1]);
        // 长度必须自洽：>=0 且不超过剩余字节数（允许有填充）
        if (len >= 0 && len <= size - 2) {
            const std::string candidate(raw, 2, static_cast<size_t>(len));
            // 判定依据：正文里不应该含控制字符，且长度前缀要"像"
            bool printable = !candidate.empty();
            for (char c : candidate) {
                const unsigned char u = static_cast<unsigned char>(c);
                if (u < 0x09 || (u > 0x0d && u < 0x20)) {
                    printable = false;
                    break;
                }
            }
            // 同时要求：raw 去掉前缀与文本后剩下的基本都是 0 填充
            if (printable) {
                bool tailClean = true;
                for (size_t i = 2 + static_cast<size_t>(len); i < raw.size(); i++) {
                    if (raw[i] != '\0') {
                        tailClean = false;
                        break;
                    }
                }
                if (tailClean) {
                    text = CleanSubtitleText(candidate);
                }
            }
        }
    }

    // ---- ③ / ④ 文本块自带时间行（SRT / WebVTT）----
    if (text.empty()) {
        // 找 "-->"，它前面是起始时间、后面是结束时间
        const size_t arrow = raw.find("-->");
        if (arrow != std::string::npos) {
            // 起始时间：从行首到 arrow
            size_t lineStart = raw.rfind('\n', arrow);
            lineStart = (lineStart == std::string::npos) ? 0 : lineStart + 1;
            // 跳过可能的序号行残留（SRT 的 "1\n00:00:01,000 --> ..."）
            const int64_t t1 = ParseSubtitleTime(raw.substr(lineStart, arrow - lineStart));
            // 结束时间：arrow 之后到行尾
            size_t lineEnd = raw.find('\n', arrow);
            const size_t endFrom = arrow + 3;
            const std::string endStr = (lineEnd == std::string::npos)
                ? raw.substr(endFrom) : raw.substr(endFrom, lineEnd - endFrom);
            int64_t t2 = ParseSubtitleTime(endStr);
            if (t1 >= 0) {
                // ★ 包自带时间才用它覆盖容器时间（见函数头的说明）
                if (startMs < 0) {
                    startMs = t1;
                }
                if (t2 > 0) {
                    endMs = t2;
                }
                // 正文 = 时间行之后的所有内容
                const size_t bodyFrom = (lineEnd == std::string::npos) ? raw.size()
                                                                      : lineEnd + 1;
                text = CleanSubtitleText(raw.substr(bodyFrom));
            }
        }
    }

    // ---- ① 明文包：ASS 的 Dialogue 行，或 MKV 里直接放的纯文本 ----
    if (text.empty()) {
        size_t bodyFrom = 0;
        // ASS/SSA 的完整行可能以 "Dialogue: " 开头
        const std::string dlg = "Dialogue:";
        if (raw.compare(0, dlg.size(), dlg) == 0) {
            bodyFrom = dlg.size();
        }
        std::string body = raw.substr(bodyFrom);

        // ASS 的字段顺序：ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
        // 所以从左边数第 8 个逗号之后才是正文
        if (dlg.size() > 0 || raw.find(',') != std::string::npos) {
            int commas = 0;
            size_t pos = 0;
            for (; pos < body.size(); pos++) {
                if (body[pos] == ',') {
                    commas++;
                    if (commas == 8) {
                        break;
                    }
                }
            }
            if (commas == 8 && pos + 1 <= body.size()) {
                body = body.substr(pos + 1);
            }
        }
        text = CleanSubtitleText(body);
    }

    if (text.empty() || startMs < 0) {
        return false;
    }

    out.startMs = startMs;
    out.endMs = endMs;
    out.text = text;
    return true;
}

/**
 * 取出一个解码帧的显示时间戳（毫秒），并推算它该显示多久
 *
 * ★★ 这里曾经有一个严重 bug（2026-09-28 真机实测定位）★★
 *
 *   原实现是 `use->pts` / `use->best_effort_timestamp`，而 `use` 指向
 *   **sws_scale 的输出帧 convFrame** —— 那个帧是我们自己分配来装 RGBA 的，
 *   从未被赋过时间戳，FFmpeg 也不会给它赋。于是两条分支都拿到
 *   AV_NOPTS_VALUE，最后落到 `pts = 0`：**每帧的时间戳都是 0**。
 *
 *   症状链（全都能对上实测现象）：
 *     · 进度条永远停在 00:00（位置按已上屏帧的 pts 上报）
 *     · 10 秒的视频瞬间播完（没有时间轴就没法按时间节流）
 *     · 续播的 startMs 恒为 0 —— 这曾被误判为"缓存/续播逻辑坏了"，
 *       也一度被误判成"软解 seek 有问题"，实际只是时间戳全是 0
 *
 *   正确做法：时间戳必须从**原始解码帧 raw** 上取。
 *   FFmpeg 的约定是优先用 best_effort_timestamp（它对 B 帧和缺失 pts
 *   的流做过修正），拿不到再退 pts / pkt_dts。
 *
 * @param s     会话（读写 frameCounter；读 defaultFrameMs / timeBase）
 * @param raw   原始解码帧，时间戳来源
 * @param ptsMs 输出：显示时间戳（毫秒）
 * @return 该帧应显示多久（毫秒），供上层做帧间隔兜底
 */
int64_t ResolveFrameTimestamp(DecoderSession *s, const AVFrame *raw, int64_t &ptsMs) {
    int64_t pts = raw->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) {
        pts = raw->pts;
    }
    if (pts == AV_NOPTS_VALUE) {
        pts = raw->pkt_dts;
    }
    if (pts != AV_NOPTS_VALUE) {
        ptsMs = av_rescale_q(pts, s->timeBase, AVRational{1, 1000});
        s->frameCounter++;
        return (s->defaultFrameMs > 1.0) ? static_cast<int64_t>(s->defaultFrameMs) : 40;
    }
    // ★ 完全没有时间戳的流（实测 .rm 的 RealVideo 就是这种）：
    //   按帧序 × 帧间隔合成一条时间轴。
    //   否则 ptsMs 恒为 0，播放器就没了时间基准。
    const int64_t step = (s->defaultFrameMs > 1.0)
        ? static_cast<int64_t>(s->defaultFrameMs) : 40;
    ptsMs = s->frameCounter * step;
    s->frameCounter++;
    return step;
}

/**
 * 确保 sws 上下文匹配当前帧与目标尺寸
 * 源分辨率/像素格式/目标尺寸任一变化都必须重建，否则会花屏或越界
 *
 * 目标格式固定为 RGBA8888 —— 理由是 surface 的 buffer 就是 4 字节/像素：
 *   stride 4352 ÷ 1084 = 4.0，且 size 2838528 = 1084 × 650 × 4，完全吻合。
 *   写 2 字节/像素的 RGB565 会让画面变成紫绿条纹（实测过）。
 */
bool EnsureSws(DecoderSession *s, const AVFrame *src, int dstW, int dstH) {
    if (s->sws != nullptr && s->swsSrcFmt == src->format
        && s->swsSrcW == src->width && s->swsSrcH == src->height
        && s->swsDstW == dstW && s->swsDstH == dstH) {
        return true;
    }
    if (s->sws != nullptr) {
        sws_freeContext(s->sws);
        s->sws = nullptr;
    }
    // SWS_FAST_BILINEAR：缩放到接近 1:1 的常见情形下质量与 BILINEAR 无差别，
    // 但速度快不少；软解 + 每帧转换的场景下这个取舍划算
    s->sws = sws_getContext(src->width, src->height, static_cast<AVPixelFormat>(src->format),
                            dstW, dstH, AV_PIX_FMT_RGBA,
                            SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
    if (s->sws == nullptr) {
        LOGE("sws_getContext 失败 %{public}dx%{public}d -> %{public}dx%{public}d",
             src->width, src->height, dstW, dstH);
        return false;
    }
    s->swsSrcFmt = src->format;
    s->swsSrcW = src->width;
    s->swsSrcH = src->height;
    s->swsDstW = dstW;
    s->swsDstH = dstH;
    return true;
}

/**
 * 把 AVFrame 拷成自己的 VideoFrame
 * 必须拷贝：解码器下一轮就会覆盖这块缓冲
 *
 * @param dstW/dstH 期望输出尺寸；<=0 表示保持原始尺寸。
 *        surface 的 buffer 是显示区域尺寸，必须缩放到这个尺寸，
 *        否则画面只会出现在左上角一小块（实测踩过）。
 */
int32_t CopyFrame(DecoderSession *s, const AVFrame *src, VideoFrame &out,
                  int32_t dstW, int32_t dstH) {
    // 目标尺寸：surface 的 buffer 是显示区域尺寸，必须缩放到它
    const int tw = (dstW > 0) ? dstW : src->width;
    const int th = (dstH > 0) ? dstH : src->height;

    // ★ 统一转成 RGBA8888 输出。
    //   不再有"YUV 直通"的快路径：快路径只在消费端也是 YUV 时才成立，
    //   而这里的消费端（surface buffer）是 RGBA。
    if (!EnsureSws(s, src, tw, th)) {
        return kDecodeFailed;
    }
    if (s->convFrame == nullptr) {
        s->convFrame = av_frame_alloc();
        if (s->convFrame == nullptr) {
            return kDecodeFailed;
        }
    }
    if (s->convFrame->width != tw || s->convFrame->height != th
        || s->convFrame->format != AV_PIX_FMT_RGBA) {
        av_frame_unref(s->convFrame);
        s->convFrame->format = AV_PIX_FMT_RGBA;
        s->convFrame->width = tw;
        s->convFrame->height = th;
        const int ret = av_frame_get_buffer(s->convFrame, 32);
        if (ret < 0) {
            LOGE("av_frame_get_buffer 失败: %{public}s", AvErr(ret).c_str());
            return kDecodeFailed;
        }
    }
    sws_scale(s->sws, src->data, src->linesize, 0, src->height,
              s->convFrame->data, s->convFrame->linesize);
    const AVFrame *use = s->convFrame;

    out.width = use->width;
    out.height = use->height;
    out.stride = use->linesize[0];

    // ★ 时间戳必须从【原始解码帧 src】上取，不能从 convFrame 取！
    //   convFrame 是 sws_scale 的输出帧，我们只往里写像素、从不设时间戳，
    //   从它读 pts 会永远得到 AV_NOPTS_VALUE（这段曾是真实 bug，详见
    //   ResolveFrameTimestamp 的说明）。
    int64_t ptsMs = 0;
    out.durationMs = ResolveFrameTimestamp(s, src, ptsMs);
    out.ptsMs = ptsMs;

    // RGBA 是打包格式（单平面），按行拷进自有缓冲
    const size_t size = static_cast<size_t>(out.stride) * use->height;
    out.data.resize(size);
    memcpy(out.data.data(), use->data[0], size);
    return kOk;
}

/**
 * 把单个平面按 90/180/270 度顺时针旋转
 *
 * 单独抽出来是因为 YUV420 有三个平面（Y 全分辨率、U/V 各半分辨率），
 * 三者的旋转逻辑完全相同，只是宽高不同 —— 写三遍容易改漏其中一个。
 *
 * @param src 源平面首地址
 * @param srcStride 源每行字节数（可能大于宽度，必须按它取行首）
 * @param dst 目标平面首地址
 * @param dstStride 目标每行字节数
 * @param w 源平面宽度（像素）
 * @param h 源平面高度（像素）
 * @param deg 旋转角度（90 / 180 / 270）
 */
void RotatePlane(const uint8_t *src, int srcStride,
                 uint8_t *dst, int dstStride,
                 int w, int h, int deg) {
    for (int y = 0; y < h; y++) {
        const uint8_t *srcRow = src + static_cast<size_t>(y) * srcStride;
        for (int x = 0; x < w; x++) {
            int dx = 0;
            int dy = 0;
            if (deg == 90) {
                // 顺时针 90：源 (x,y) -> 目标 (h-1-y, x)
                dx = h - 1 - y;
                dy = x;
            } else if (deg == 180) {
                dx = w - 1 - x;
                dy = h - 1 - y;
            } else {  // 270
                // 顺时针 270（= 逆时针 90）：源 (x,y) -> 目标 (y, w-1-x)
                dx = y;
                dy = w - 1 - x;
            }
            dst[static_cast<size_t>(dy) * dstStride + dx] = srcRow[x];
        }
    }
}

/**
 * 按角度旋转整帧 YUV420
 *
 * ★ 色度平面要注意用半分辨率：U/V 的宽高都是亮度的一半。
 *   如果拿全分辨率的宽高去转 U/V，会读到越界内存（比写越界更隐蔽，
 *   因为不一定立刻崩，而是画面错乱）。
 */
void RotateYuv420(const AVFrame *src, AVFrame *dst, int deg) {
    const int w = src->width;
    const int h = src->height;
    RotatePlane(src->data[0], src->linesize[0], dst->data[0], dst->linesize[0], w, h, deg);

    // 色度平面：尺寸各减半。用 (w+1)/2 而不是 w/2，
    // 是为了在奇数尺寸下也能覆盖到最后一块（YUV420 的色度是向上取整）
    const int cw = (w + 1) / 2;
    const int ch = (h + 1) / 2;
    RotatePlane(src->data[1], src->linesize[1], dst->data[1], dst->linesize[1], cw, ch, deg);
    RotatePlane(src->data[2], src->linesize[2], dst->data[2], dst->linesize[2], cw, ch, deg);
}

}  // namespace

std::string VersionString() {
    return std::string(av_version_info());
}
bool IsIntegrated() {
    return true;
}

/**
 * 在解复用线程内部执行 seek（定义见 Open 之后）
 *
 * ★ 前置声明的位置是有讲究的：必须与定义【同处一个作用域】。
 *   匿名命名空间在 RotateYuv420 之后就结束了，而 Open / SeekInternal
 *   都定义在它外面（codecapi 命名空间下）。
 *   把声明放进匿名命名空间会让它变成另一个符号，
 *   链接期报 undefined symbol: ...(anonymous namespace)::SeekInternal。
 */
int SeekInternal(DecoderSession *s, int64_t positionMs);

/**
 * 不带轨道选择的 Open：等价于全 -1（自动）
 *
 * 单独保留这个重载是为了让 ThumbnailExtractor 之类的老调用点一行都不用改。
 */
int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg);

int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg, const TrackRequest &tracks) {
    outSession = nullptr;

    // ---- 打开容器 ----
    AVFormatContext *fmt = nullptr;
    int ret = avformat_open_input(&fmt, path.c_str(), nullptr, nullptr);
    if (ret < 0) {
        errMsg = "avformat_open_input: " + AvErr(ret);
        return kOpenFailed;
    }

    // 会话要提前建出来：中断回调需要拿到 demuxAbort 标志的地址
    // （见 InterruptCallback 与 demuxAbort 的说明）。
    auto *s = new DecoderSession();
    s->fmtCtx = fmt;
    fmt->interrupt_callback.callback = InterruptCallback;
    fmt->interrupt_callback.opaque = &s->demuxAbort;

    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        errMsg = "avformat_find_stream_info: " + AvErr(ret);
        avformat_close_input(&fmt);
        delete s;
        return kOpenFailed;
    }

    // ---- 找流 ----
    // av_find_best_stream 会顺带把解码器找出来，比自己遍历更省事
    const AVCodec *vdec = nullptr;
    int vIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &vdec, 0);

    // ---- 音频流：枚举全部可解码的音轨，再决定用哪一条 ----
    //
    // 为什么不能只留 av_find_best_stream 的结果：
    //   多语言影片 / 带导演评论的片子有 2~8 条音轨，自动挑的"最好"那条
    //   常常不是用户想要的那条（例如自动挑了 5.1 英语，用户要国语立体声）。
    //   所以这里把全部可解码的音轨列给界面，并允许 TrackRequest 指定。
    std::vector<int32_t> audioCandidates;   // 能真正解码的音轨下标
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        const AVStream *st = fmt->streams[i];
        // codecpar 理论上一定非空，但畸形容器下见过空指针 —— 这里挡一下，
        // 一个坏流不该让整个文件打不开
        if (st == nullptr || st->codecpar == nullptr) {
            continue;
        }
        if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            continue;
        }
        if (avcodec_find_decoder(st->codecpar->codec_id) == nullptr) {
            LOGW("音轨 #%{public}u（%{public}s）没有可用解码器，不列入可切换列表",
                 i, avcodec_get_name(st->codecpar->codec_id));
            continue;
        }
        AudioTrackInfo info;
        info.index = static_cast<int32_t>(i);
        info.codec = avcodec_get_name(st->codecpar->codec_id);
        info.channels = st->codecpar->ch_layout.nb_channels;
        info.sampleRate = st->codecpar->sample_rate;
        info.bitRate = st->codecpar->bit_rate;
        info.isDefault = (st->disposition & AV_DISPOSITION_DEFAULT) != 0;
        const AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", nullptr, 0);
        if (lang != nullptr && lang->value != nullptr) {
            info.language = lang->value;
        }
        const AVDictionaryEntry *title = av_dict_get(st->metadata, "title", nullptr, 0);
        if (title != nullptr && title->value != nullptr) {
            info.title = title->value;
        }
        out.audioTracks.push_back(info);
        audioCandidates.push_back(static_cast<int32_t>(i));
    }

    // 决定实际用哪条音轨
    int aIdx = -1;
    if (tracks.audioStreamIndex >= 0) {
        // 调用方明确指定：必须是上面列出的可解码音轨之一
        if (std::find(audioCandidates.begin(), audioCandidates.end(),
                      tracks.audioStreamIndex) != audioCandidates.end()) {
            aIdx = tracks.audioStreamIndex;
        } else {
            // 指定了切不过去的音轨：不静默退回自动选，而是明确告诉调用方
            errMsg = "指定的音轨下标 " + std::to_string(tracks.audioStreamIndex)
                     + " 不可用（该流不存在或没有解码器）";
            avformat_close_input(&fmt);
            delete s;
            return kNoStream;
        }
    } else if (!audioCandidates.empty()) {
        // 没指定：沿用 av_find_best_stream 的判断（它会考虑默认轨、声道数、
        // 码率等）；如果它挑中的那条恰恰不可解码，则退到第一条可解码的
        const int best = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
        if (best >= 0
            && std::find(audioCandidates.begin(), audioCandidates.end(), best)
               != audioCandidates.end()) {
            aIdx = best;
        } else {
            aIdx = audioCandidates.front();
        }
    }
    out.selectedAudioIndex = aIdx;

    // ---- 字幕流：枚举全部，并决定启用哪一条 ----
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        const AVStream *st = fmt->streams[i];
        if (st == nullptr || st->codecpar == nullptr) {
            continue;
        }
        if (st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
            continue;
        }
        SubtitleTrackInfo info;
        info.index = static_cast<int32_t>(i);
        info.codec = avcodec_get_name(st->codecpar->codec_id);
        info.isDefault = (st->disposition & AV_DISPOSITION_DEFAULT) != 0;
        std::string shortName;
        info.supported = IsTextSubtitleCodec(st->codecpar->codec_id, shortName);
        // 把短名（SRT/ASS/PGS图形…）放进 title 的兜底位：容器没写 title 时，
        // 界面至少能显示字幕格式，而不是一行空白
        if (info.title.empty() && !shortName.empty()) {
            info.title = shortName;
        }
        const AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", nullptr, 0);
        if (lang != nullptr && lang->value != nullptr) {
            info.language = lang->value;
        }
        const AVDictionaryEntry *title = av_dict_get(st->metadata, "title", nullptr, 0);
        if (title != nullptr && title->value != nullptr) {
            info.title = title->value;
        }
        out.subtitleTracks.push_back(info);
    }

    // 决定启用的字幕轨：只接受 supported 的
    if (tracks.subtitleStreamIndex >= 0) {
        bool usable = false;
        for (const SubtitleTrackInfo &ti : out.subtitleTracks) {
            if (ti.index == tracks.subtitleStreamIndex && ti.supported) {
                usable = true;
                break;
            }
        }
        if (!usable) {
            errMsg = "指定的字幕轨 " + std::to_string(tracks.subtitleStreamIndex)
                     + " 不可用（不存在，或是本播放器不支持的图形字幕）";
            avformat_close_input(&fmt);
            delete s;
            return kNoStream;
        }
        s->subtitleStreamIndex = tracks.subtitleStreamIndex;
        out.selectedSubtitleIndex = tracks.subtitleStreamIndex;
        // 字幕的时间基必须从流里取 —— 不同容器的字幕时间基差别很大
        // （MKV 常见 1/1000，MP4 常见 1/媒体时基），写死就会算错时间轴
        s->subtitleTimeBase = fmt->streams[tracks.subtitleStreamIndex]->time_base;
        LOGI("字幕轨已选中: 流下标 %{public}d time_base %{public}d/%{public}d",
             tracks.subtitleStreamIndex,
             s->subtitleTimeBase.num, s->subtitleTimeBase.den);
    }

    if (vIdx < 0 && aIdx < 0) {
        errMsg = "没有找到任何音视频流";
        avformat_close_input(&fmt);
        delete s;
        return kNoStream;
    }

    if (vIdx >= 0) {
        if (vdec == nullptr) {
            errMsg = "找到视频流但拿不到解码器";
            delete s;
            avformat_close_input(&fmt);
            return kNoStream;
        }
        AVCodecContext *vctx = avcodec_alloc_context3(vdec);
        if (vctx == nullptr) {
            errMsg = "avcodec_alloc_context3 失败";
            delete s;
            avformat_close_input(&fmt);
            return kDecoderOpenFailed;
        }
        ret = avcodec_parameters_to_context(vctx, fmt->streams[vIdx]->codecpar);
        if (ret < 0) {
            errMsg = "avcodec_parameters_to_context: " + AvErr(ret);
            avcodec_free_context(&vctx);
            delete s;
            avformat_close_input(&fmt);
            return kDecoderOpenFailed;
        }
        // 多线程解码：软解 1080p 单线程跟不上，thread_count=0 表示按核心数自动
        vctx->thread_count = 0;
        ret = avcodec_open2(vctx, vdec, nullptr);
        if (ret < 0) {
            errMsg = "avcodec_open2(" + std::string(vdec->name) + "): " + AvErr(ret);
            avcodec_free_context(&vctx);
            delete s;
            avformat_close_input(&fmt);
            return kDecoderOpenFailed;
        }
        s->videoCtx = vctx;
        s->videoStreamIndex = vIdx;
        s->timeBase = fmt->streams[vIdx]->time_base;

        out.hasVideo = true;
        out.width = vctx->width;
        out.height = vctx->height;
        out.videoCodec = vdec->name != nullptr ? vdec->name : "unknown";
        const AVRational fr = fmt->streams[vIdx]->avg_frame_rate;
        if (fr.num > 0 && fr.den > 0) {
            out.frameRate = av_q2d(fr);
        }
        // 帧间隔兜底值：优先用解码器帧率，其次容器帧率，都取不到就用 40ms（25fps）。
        // 用途见 ResolveFrameTimestamp —— 时间戳全缺的流要靠它合成时间轴。
        if (vctx->framerate.num > 0 && vctx->framerate.den > 0) {
            s->defaultFrameMs = 1000.0 * vctx->framerate.den / vctx->framerate.num;
        } else if (out.frameRate > 0.1) {
            s->defaultFrameMs = 1000.0 / out.frameRate;
        }
        if (s->defaultFrameMs < 1.0 || s->defaultFrameMs > 1000.0) {
            s->defaultFrameMs = 40.0;   // 异常值一律退回 25fps
        }
        const char *pf = av_get_pix_fmt_name(vctx->pix_fmt);
        out.pixelFormat = pf != nullptr ? pf : "unknown";

        // ---- 读出画面旋转角度 ----
        //
        // 为什么必须读：
        //   手机竖着拍的视频通常以横向像素存储，只靠容器里的旋转矩阵说明
        //   "播放时该转 90 度"。系统 AVPlayer 会自动照做，但我们是自己解码上屏，
        //   不读这个标记画面就是歪的。
        //
        // 两个来源都要看，因为不同容器放的位置不同：
        //   ① 流级 side data（mp4/mov 的 tkhd 矩阵、mkv 的 ProjectionPoseRoll
        //      被 FFmpeg 归一化到这里）—— 首选
        //   ② 逐帧 side data —— 少数文件只在帧上带
        // 这里只处理流级；逐帧的在解码时处理（见 CopyFrame 的说明）。
        const AVPacketSideData *sd = av_packet_side_data_get(
            fmt->streams[vIdx]->codecpar->coded_side_data,
            fmt->streams[vIdx]->codecpar->nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX);
        if (sd != nullptr && sd->size >= 9 * sizeof(int32_t)) {
            // av_display_rotation_get 返回的是**逆时针**角度（数学约定），
            // 而我们要的是顺时针，所以取负；再归一化到 [0,360)
            const double ccw = av_display_rotation_get(
                reinterpret_cast<const int32_t *>(sd->data));
            if (!std::isnan(ccw)) {
                int32_t deg = static_cast<int32_t>(-ccw);
                deg = ((deg % 360) + 360) % 360;
                // 只接受 90 的整数倍：非直角旋转需要重采样，播放器通常不支持，
                // 硬转反而会因插值把画面弄糊
                if (deg % 90 == 0) {
                    out.rotationDeg = deg;
                }
            }
        }
        if (out.rotationDeg != 0) {
            LOGI("该视频带旋转元数据: %{public}d 度（画面将按此旋转上屏）", out.rotationDeg);
        }
    }

    if (aIdx >= 0) {
        out.hasAudio = true;
        const AVCodecParameters *apar = fmt->streams[aIdx]->codecpar;
        const char *an = avcodec_get_name(apar->codec_id);
        out.audioCodec = an != nullptr ? an : "unknown";

        // ---- 真正打开音频解码器 ----
        // 注意：这里失败不算致命。有些文件音频编码我们没编进去（例如冷门无损格式），
        // 但视频仍然可以正常播 —— 那就"有声就播、没声就静音"，不要整个文件都打不开。
        const AVCodec *adec = avcodec_find_decoder(apar->codec_id);
        if (adec != nullptr) {
            AVCodecContext *actx = avcodec_alloc_context3(adec);
            if (actx != nullptr
                && avcodec_parameters_to_context(actx, apar) >= 0
                && avcodec_open2(actx, adec, nullptr) >= 0) {
                s->audioCtx = actx;
                s->audioStreamIndex = aIdx;
                s->audioTimeBase = fmt->streams[aIdx]->time_base;
                s->audioFrame = av_frame_alloc();

                // 建重采样上下文：源参数 = 解码器实际输出的参数，目标 = 固定输出格式。
                // 用 av_opt_set_chlayout 而不是已废弃的 av_opt_set_int("channel_layout")，
                // 后者在新版 FFmpeg 会报警告且行为不确定。
                AVChannelLayout outLayout;
                av_channel_layout_default(&outLayout, kAudioChannels);
                AVChannelLayout inLayout;
                if (actx->ch_layout.nb_channels > 0) {
                    av_channel_layout_copy(&inLayout, &actx->ch_layout);
                } else {
                    av_channel_layout_default(&inLayout, 2);
                }
                const int swrRet = swr_alloc_set_opts2(&s->swr,
                                                       &outLayout, AV_SAMPLE_FMT_S16, kAudioSampleRate,
                                                       &inLayout, actx->sample_fmt, actx->sample_rate,
                                                       0, nullptr);
                av_channel_layout_uninit(&outLayout);
                av_channel_layout_uninit(&inLayout);
                if (swrRet < 0 || s->swr == nullptr || swr_init(s->swr) < 0) {
                    LOGE("音频重采样初始化失败，本次播放将没有声音");
                    if (s->swr != nullptr) {
                        swr_free(&s->swr);
                        s->swr = nullptr;
                    }
                    avcodec_free_context(&s->audioCtx);
                    s->audioCtx = nullptr;
                    s->audioStreamIndex = -1;
                } else {
                    LOGI("音频解码就绪: %{public}s %{public}dHz %{public}dch -> %{public}dHz %{public}dch S16",
                         out.audioCodec.c_str(), actx->sample_rate, actx->ch_layout.nb_channels,
                         kAudioSampleRate, kAudioChannels);
                }
            } else {
                if (actx != nullptr) {
                    avcodec_free_context(&actx);
                }
                LOGW("音频解码器打开失败（%{public}s），本次播放将静音", out.audioCodec.c_str());
            }
        } else {
            LOGW("找不到音频解码器（%{public}s），本次播放将静音", out.audioCodec.c_str());
        }
    }

    if (fmt->duration > 0) {
        out.durationMs = fmt->duration / (AV_TIME_BASE / 1000);
    } else if (vIdx >= 0 && fmt->streams[vIdx]->duration > 0) {
        out.durationMs = av_rescale_q(fmt->streams[vIdx]->duration,
                                      fmt->streams[vIdx]->time_base,
                                      AVRational{1, 1000});
    }

    // ---- 时长兜底：裸音频流容器里根本没有时长 ----
    //
    // 实测踩到：DTS-HD MA 的 .dtshd 纯音频文件能正常播（XLL 解出 6ch，
    // 全程零欠载），但进度条显示 00:19 / 00:00 —— 总时长为 0。
    // 后果不只是显示难看：PlayerPage 里滑块的上限写的是
    //     max: this.durationMs > 0 ? this.durationMs : 1
    // 于是 max=1，滑块永远贴在最右，**用户根本没法拖进度**。
    //
    // 根因：上面两个分支都取不到值。裸流（.dts/.dtshd/.ac3/.thd 这类）
    // 没有容器层，fmt->duration 是 AV_NOPTS_VALUE；而 vIdx < 0（纯音频，
    // 没有视频轨），第二个分支也不成立。
    //
    // 为什么只给纯音频（vIdx < 0）做兜底，而不给视频做：
    //   视频缺时长的是 raw H.264/H.265 这类，码率跨度从几十 kbps 到几十 Mbps，
    //   采样开头一小段外推整个文件同样不可靠，而且视频文件通常很大、
    //   采样成本也高。纯音频则满足两个条件：文件通常不大，且码率在
    //   整个文件里相对平稳，采样外推的可信度高得多。
    if (out.durationMs <= 0 && vIdx < 0 && aIdx >= 0) {
        // 文件总大小（avio_size 对 fd:// 与普通路径都有效）
        const int64_t fileSize = (fmt->pb != nullptr) ? avio_size(fmt->pb) : -1;

        if (fileSize > 0) {
            // 一级：容器/流里声明的码率，有就直接用，最省事也最准
            int64_t bitRate = fmt->bit_rate;
            if (bitRate <= 0) {
                bitRate = fmt->streams[aIdx]->codecpar->bit_rate;
            }

            // 二级：实测。读开头 800 个包量出「字节跨度 / 精确时长」得到真实码率。
            // 为什么不用理论 PCM 码率：DTS-HD MA 是有损 core + 无损残差两层叠加，
            // 真实码率与理论值的比值在实测样本里从 0.59 跨到 1.16
            //（2.0/16bit 反而超理论值，因为 core 层是额外开销），
            // 常数无法拟合，只能实测。详见 MeasureStreamBitRate 的注释。
            bool measured = false;
            if (bitRate <= 0) {
                bitRate = MeasureStreamBitRate(path, 800);
                measured = bitRate > 0;
            }

            if (bitRate > 0) {
                out.durationMs = fileSize * 8 * 1000 / bitRate;
                LOGI("容器未提供时长（裸流），%{public}s码率 %{public}lld bps × "
                     "%{public}lld 字节 -> %{public}lld ms",
                     measured ? "实测" : "声明",
                     static_cast<long long>(bitRate),
                     static_cast<long long>(fileSize),
                     static_cast<long long>(out.durationMs));
            }
        }
    }

    // packet 是「解复用线程读包用」，audioPacket / videoPacket 分别是
    // 音频、视频解码线程从自己队列取包用的容器
    s->packet = av_packet_alloc();
    s->audioPacket = av_packet_alloc();
    s->videoPacket = av_packet_alloc();
    s->subtitlePacket = av_packet_alloc();
    s->rawFrame = av_frame_alloc();
    if (s->packet == nullptr || s->audioPacket == nullptr
        || s->videoPacket == nullptr || s->subtitlePacket == nullptr
        || s->rawFrame == nullptr) {
        errMsg = "av_packet_alloc / av_frame_alloc 失败";
        delete s;
        return kDecoderOpenFailed;
    }

    // ---------- 启动单解复用线程 ----------
    // 队列容量 512 个包：解复用远快于解码，不设上限会把整个文件读进内存；
    // 512 大约相当于十几秒的数据，足够吸收解码抖动，又不会占太多内存。
    s->videoQueue = std::make_unique<PacketQueue>();
    s->audioQueue = std::make_unique<PacketQueue>();
    s->videoQueue->limit = 512;
    s->audioQueue->limit = 512;
    // 字幕队列只在启用字幕时才建。容量小得多（128）：
    // 字幕包很小，而且一次只需要"当前时间附近"的几条 ——
    // 队列太长只会让已经过期的字幕堆积（消费端会丢弃过期的，见 ReadSubtitleEvent）。
    if (s->subtitleStreamIndex >= 0) {
        s->subtitleQueue = std::make_unique<PacketQueue>();
        s->subtitleQueue->limit = 128;
        LOGI("字幕轨已启用: 流下标 %{public}d", s->subtitleStreamIndex);
    }
    try {
        // 线程体直接内联写在 lambda 里，不抽成独立函数。
        //  抽成 DemuxLoop() 会有个坑：本函数在匿名命名空间内、而 DemuxLoop
        //  定义在本函数之后，前置声明与定义若跨了命名空间边界就会变成
        //  两个不同符号，链接期报 undefined。内联写法没有这个风险。
        s->demuxThread = std::thread([s]() {
            AVPacket *pkt = av_packet_alloc();
            if (pkt == nullptr) {
                s->demuxError.store(AVERROR(ENOMEM));
                s->videoQueue->SetEof();
                s->audioQueue->SetEof();
                if (s->subtitleQueue != nullptr) {
                    s->subtitleQueue->SetEof();
                }
                return;
            }
            while (true) {
                // ① 先处理 seek 请求（av_seek_frame 必须由独占 fmtCtx 的
                //    本线程执行，见 Seek() 与 SeekInternal() 的说明）
                const int64_t target = s->pendingSeekMs.exchange(-1);
                if (target >= 0) {
                    const int sret = SeekInternal(s, target);
                    if (sret < 0) {
                        LOGE("解复用线程 seek 失败: %{public}s", AvErr(sret).c_str());
                        s->demuxError.store(sret);
                        break;
                    }
                    LOGI("解复用线程已 seek 到 %{public}lld ms 并清空队列",
                         static_cast<long long>(target));
                }
                // ② 读一个包
                av_packet_unref(pkt);
                const int rret = av_read_frame(s->fmtCtx, pkt);
                if (rret == AVERROR_EOF) {
                    // 正常结束：标记各队列 EOF，让解码线程冲刷完缓冲的帧
                    s->videoQueue->SetEof();
                    s->audioQueue->SetEof();
                    if (s->subtitleQueue != nullptr) {
                        s->subtitleQueue->SetEof();
                    }
                    break;
                }
                if (rret < 0) {
                    LOGE("解复用失败: %{public}s", AvErr(rret).c_str());
                    s->demuxError.store(rret);
                    s->videoQueue->SetEof();
                    s->audioQueue->SetEof();
                    if (s->subtitleQueue != nullptr) {
                        s->subtitleQueue->SetEof();
                    }
                    break;
                }
                // ③ 按流索引分流；未启用的流（未选中的音轨/字幕轨）直接丢弃
                bool pushed = true;
                if (pkt->stream_index == s->videoStreamIndex) {
                    pushed = s->videoQueue->Push(pkt);
                } else if (s->audioStreamIndex >= 0
                           && pkt->stream_index == s->audioStreamIndex) {
                    pushed = s->audioQueue->Push(pkt);
                } else if (s->subtitleStreamIndex >= 0
                           && pkt->stream_index == s->subtitleStreamIndex
                           && s->subtitleQueue != nullptr) {
                    pushed = s->subtitleQueue->Push(pkt);
                }
                if (!pushed) {
                    break;   // 队列被中止（会话正在关闭）
                }
            }
            av_packet_free(&pkt);
            LOGI("解复用线程退出");
        });
        s->demuxThreadStarted.store(true);
        LOGI("解复用线程已启动（单线程独占 av_read_frame）");
    } catch (...) {
        // 线程创建失败：不是致命错误，退化为「解码线程自己读包」不可行，
        // 所以这里直接报失败，让上层给出明确提示而不是静默卡死
        errMsg = "创建解复用线程失败";
        delete s;
        return kDecoderOpenFailed;
    }

    outSession = s;
    return kOk;
}

/**
 * 在解复用线程内部执行 seek
 *
 * 为什么必须是内部函数：av_seek_frame 会重置 fmtCtx 的读位置和内部缓冲，
 * 必须由独占 fmtCtx 的解复用线程来做。外部接口只写 pendingSeekMs，
 * 由本线程在每轮开头取走执行 —— 免除了「seek 与 read 并发」这个老问题
 * （之前靠 demuxMutex 串行，代价是 seek 期间两边互相等待、播放卡顿）。
 *
 * @return 0 成功
 */
int SeekInternal(DecoderSession *s, int64_t positionMs) {
    const int64_t ts = av_rescale_q(positionMs, AVRational{1, 1000}, s->timeBase);
    // 必须往前找关键帧：不加 BACKWARD 会跳到目标之后，画面接不上
    const int ret = av_seek_frame(s->fmtCtx, s->videoStreamIndex, ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        return ret;
    }
    // 三个缓冲都要清，否则 seek 后会先闪旧画面 / 先出残音
    if (s->videoCtx != nullptr) {
        avcodec_flush_buffers(s->videoCtx);
    }
    if (s->audioCtx != nullptr) {
        avcodec_flush_buffers(s->audioCtx);
    }
    if (s->swr != nullptr) {
        swr_close(s->swr);
        swr_init(s->swr);
    }
    // 旧位置的包全部作废
    //
    // ★ 只清**包队列**，不清字幕缓存 —— 这是个必须讲清的取舍。
    //
    //   字幕缓存（FfmpegEngine::subtitleCues_）与包队列是两回事：
    //     · 包队列里是"还没解析的原始包"，seek 后旧位置的包确实没用了 → 清
    //     · 缓存里是"已经解析成 起止时间+文本 的字幕" → **不该清**
    //
    //   踩过的坑：曾经在引擎侧跟着 seek 一起把缓存也清了，
    //   结果是"长字幕永远不显示"：
    //     一条字幕覆盖 0.5s~38s，seek 把它从缓存里清掉之后，
    //     解复用线程从新的位置继续往前读，**永远不会再读到这条已经在
    //     身后的字幕包**，于是屏幕上一直空白。
    //   保留缓存就没有这个问题：新位置的包到来时会自然补齐/替换，
    //   而 GetActiveSubtitle 本来就是按当前播放位置去缓存里**匹配**的，
    //   多留一些过期条目完全无害（这也是当初选"缓存+查询"而非
    //   "收到即显示"的原因之一）。
    s->videoQueue->Clear();
    s->audioQueue->Clear();
    if (s->subtitleQueue != nullptr) {
        s->subtitleQueue->Clear();
    }
    return 0;
}

int32_t DecodeVideoFrame(Session session, VideoFrame &frame, std::string &errMsg,
                         int32_t scaleWidth, int32_t scaleHeight) {
    auto *s = static_cast<DecoderSession *>(session);
    if (s == nullptr || s->videoCtx == nullptr) {
        errMsg = "会话无效或没有视频流";
        return kDecodeFailed;
    }

    // demux → decode 循环：一次调用可能吃掉多个 packet 才出一帧
    for (int guard = 0; guard < 200; guard++) {
        const int ret = avcodec_receive_frame(s->videoCtx, s->rawFrame);
        if (ret == 0) {
            const int32_t r = CopyFrame(s, s->rawFrame, frame, scaleWidth, scaleHeight);
            av_frame_unref(s->rawFrame);
            return r;
        }
        if (ret == AVERROR(EAGAIN)) {
            // 解码器要更多输入，继续送包
        } else if (ret == AVERROR_EOF) {
            return kEof;
        } else {
            errMsg = "avcodec_receive_frame: " + AvErr(ret);
            return kDecodeFailed;
        }

        // 送一个包（视频）—— 从队列取，不再自己读 fmtCtx
        //
        // ★ 架构修复（2026-09-29）：这里原来是
        //     「锁内 av_read_frame + av_packet_ref → 锁外 send_packet」，
        //   也就是视频/音频两条线程各自读同一个 AVFormatContext。
        //   现在 av_read_frame 只由 DemuxLoop 一条线程调用，
        //   本函数只从队列取已经独立成包的 AVPacket —— 不存在并发读，
        //   连「包数据被覆盖」这类问题的土壤都没有了。
        av_packet_unref(s->videoPacket);
        const int32_t qret = s->videoQueue->Pop(s->videoPacket, 20);
        if (qret == kEof) {
            // 队列已空且解复用结束：送空包冲刷解码器里缓冲的帧
            avcodec_send_packet(s->videoCtx, nullptr);
            continue;
        }
        if (qret != kOk) {
            // 超时或会话中止：让上层稍后重试（引擎那边会处理暂停/退出）
            const int32_t de = s->demuxError.load();
            if (de != 0) {
                errMsg = "解复用失败: " + AvErr(de);
                return kDecodeFailed;
            }
            return kAgain;
        }
        AVPacket *vpkt = s->videoPacket;
        // 先留一份包的关键信息 —— unref 之后这些字段就没了，
        // 而失败日志要靠它们说明「被拒的是哪个包」
        s->dbgLastSize = vpkt->size;
        s->dbgLastPts = vpkt->pts;
        s->dbgLastFlags = vpkt->flags;
        int rret = avcodec_send_packet(s->videoCtx, vpkt);
        av_packet_unref(vpkt);
        if (rret < 0 && rret != AVERROR(EAGAIN)) {
            // 诊断：只在失败时打印（原先逐包打印会刷屏）。
            // 这个日志是定位 VP9 拒绝包问题的关键：它说明解码器从哪个包开始失败。
            LOGE("avcodec_send_packet 失败: ret=%{public}d (%{public}s) "
                 "size=%{public}d pts=%{public}lld flags=%{public}d",
                 rret, AvErr(rret).c_str(),
                 s->dbgLastSize, static_cast<long long>(s->dbgLastPts), s->dbgLastFlags);
            errMsg = "avcodec_send_packet: " + AvErr(rret);
            return kDecodeFailed;
        }
    }
    return kAgain;
}

int32_t DecodeAudioChunk(Session session, AudioChunk &chunk, std::string &errMsg) {
    auto *s = static_cast<DecoderSession *>(session);
    if (s == nullptr || s->audioCtx == nullptr || s->swr == nullptr) {
        errMsg = "无音频轨或音频解码不可用";
        return kEof;
    }

    // demux → decode → resample 循环：一次调用可能吃掉多个 packet
    for (int guard = 0; guard < 200; guard++) {
        const int ret = avcodec_receive_frame(s->audioCtx, s->audioFrame);
        if (ret == 0) {
            // ---- 重采样成 S16LE / 立体声 / 48kHz ----
            // 输出样本数按源样本数与采样率比例估算并留余量，
            // 因为 swr 内部可能还有缓冲（尤其上采样时）
            const int64_t delay = swr_get_delay(s->swr, s->audioCtx->sample_rate);
            const int maxOut = static_cast<int>(
                av_rescale_rnd(delay + s->audioFrame->nb_samples,
                               kAudioSampleRate, s->audioCtx->sample_rate, AV_ROUND_UP));
            const int outBytes = maxOut * kAudioChannels * 2;  // S16LE = 2 字节

            if (s->resampleBufSize < outBytes) {
                if (s->resampleBuf != nullptr) {
                    av_freep(&s->resampleBuf);
                    s->resampleBuf = nullptr;
                }
                if (av_samples_alloc(&s->resampleBuf, nullptr, kAudioChannels,
                                     maxOut, AV_SAMPLE_FMT_S16, 0) < 0) {
                    errMsg = "音频输出缓冲分配失败";
                    av_frame_unref(s->audioFrame);
                    return kDecodeFailed;
                }
                s->resampleBufSize = outBytes;
            }

            uint8_t *outPlanes[1] = {s->resampleBuf};
            const uint8_t **inPlanes = const_cast<const uint8_t **>(s->audioFrame->extended_data);
            const int converted = swr_convert(s->swr, outPlanes, maxOut,
                                              inPlanes, s->audioFrame->nb_samples);
            if (converted < 0) {
                errMsg = "swr_convert 失败: " + AvErr(converted);
                av_frame_unref(s->audioFrame);
                return kDecodeFailed;
            }

            // pts：源帧可能没有 pts，此时用 0 兜底（音频时钟会自行推进）
            int64_t pts = s->audioFrame->pts;
            if (pts == AV_NOPTS_VALUE) {
                pts = s->audioFrame->best_effort_timestamp;
            }
            if (pts == AV_NOPTS_VALUE) {
                pts = 0;
            }
            chunk.ptsMs = av_rescale_q(pts, s->audioTimeBase, AVRational{1, 1000});

            const int bytes = converted * kAudioChannels * 2;
            chunk.data.resize(static_cast<size_t>(bytes));
            if (bytes > 0) {
                memcpy(chunk.data.data(), s->resampleBuf, static_cast<size_t>(bytes));
            }
            // 时长按输出样本数算
            chunk.durationMs = (converted > 0)
                ? static_cast<int64_t>(converted) * 1000 / kAudioSampleRate : 0;

            av_frame_unref(s->audioFrame);
            return kOk;
        }
        if (ret == AVERROR(EAGAIN)) {
            // 需要更多输入，继续送包
        } else if (ret == AVERROR_EOF) {
            return kEof;
        } else {
            errMsg = "avcodec_receive_frame(audio): " + AvErr(ret);
            return kDecodeFailed;
        }

        // 送一个包（音频）—— 从队列取，不再自己读 fmtCtx
        // 与视频同理：av_read_frame 只由 DemuxLoop 调用
        av_packet_unref(s->audioPacket);
        const int32_t qret = s->audioQueue->Pop(s->audioPacket, 20);
        if (qret == kEof) {
            // 队列已空且解复用结束：送空包冲刷音频解码器
            avcodec_send_packet(s->audioCtx, nullptr);
            continue;
        }
        if (qret != kOk) {
            const int32_t de = s->demuxError.load();
            if (de != 0) {
                errMsg = "解复用失败(音频): " + AvErr(de);
                return kDecodeFailed;
            }
            return kAgain;
        }
        const int rret = avcodec_send_packet(s->audioCtx, s->audioPacket);
        av_packet_unref(s->audioPacket);
        if (rret < 0 && rret != AVERROR(EAGAIN)) {
            errMsg = "avcodec_send_packet(audio): " + AvErr(rret);
            return kDecodeFailed;
        }
    }
    return kAgain;
}

bool HasAudio(Session session) {
    auto *s = static_cast<DecoderSession *>(session);
    return s != nullptr && s->audioCtx != nullptr && s->swr != nullptr;
}

bool HasSubtitle(Session session) {
    auto *s = static_cast<DecoderSession *>(session);
    return s != nullptr && s->subtitleStreamIndex >= 0 && s->subtitleQueue != nullptr;
}

int32_t ReadSubtitleEvent(Session session, softplayer::SubtitleEvent &out,
                          std::string &errMsg) {
    auto *s = static_cast<DecoderSession *>(session);
    if (s == nullptr || s->subtitleQueue == nullptr || s->subtitleStreamIndex < 0) {
        // 没启用字幕：这不是错误，只是"没有内容"
        return kAgain;
    }

    // 每次调用最多尝试若干个包就返回 kAgain。
    //
    // 为什么要限量：库里可能大片区域没有字幕（比如开场几分钟），
    // 如果这里一直循环到取出字幕为止，调用线程（视频解码线程）会被
    // 拖住在字幕解析上，视频反而卡顿。限量 + 让调用方下次再来，
    // 就能把"找字幕"的成本摊到多帧之间。
    for (int guard = 0; guard < 64; guard++) {
        // ★ 用字幕专用的 AVPacket，绝不能借用 audioPacket：
        //   那个归音频解码线程所有。借用同一对象正是历史上"包数据被并发
        //   覆盖"那类 bug 的根源（见 DecoderSession 里那段长注释）。
        av_packet_unref(s->subtitlePacket);
        const int32_t qret = s->subtitleQueue->Pop(s->subtitlePacket, 0);
        if (qret == kEof) {
            return kEof;
        }
        if (qret != kOk) {
            return kAgain;   // 队列暂时空
        }

        // 取时间戳：pts 优先，其次 dts
        int64_t pts = s->subtitlePacket->pts;
        if (pts == AV_NOPTS_VALUE) {
            pts = s->subtitlePacket->dts;
        }
        const int64_t ptsMs = (pts == AV_NOPTS_VALUE)
            ? AV_NOPTS_VALUE
            : av_rescale_q(pts, s->subtitleTimeBase, AVRational{1, 1000});
        const int64_t durMs = (s->subtitlePacket->duration > 0)
            ? av_rescale_q(s->subtitlePacket->duration, s->subtitleTimeBase,
                           AVRational{1, 1000})
            : 0;

        SubtitleEvent ev;
        if (!SelfDecodeSubtitle(s->subtitlePacket->data, s->subtitlePacket->size,
                                ptsMs, durMs, ev)) {
            continue;   // 这个包解不出东西（空行、样式行等），换下一个
        }

        // ---- 产出策略：立即输出，不等下一条 ----
        //
        // 多数容器（MKV / MP4）的文本字幕包**只有开始时间、没有持续时间**。
        // 按常规可以"攒着这条，等下一条到来时用它的开始时间当结束时间"，
        // 时间最准。但这里刻意不那么做，理由是上层（引擎）本来就不是
        // "收到就显示"，而是按**当前播放位置**去匹配字幕：
        //   · 延迟一条输出，会让字幕相对画面整体晚一条；
        //   · 拖动进度条后更明显（缓存里全是过期字幕，匹配不上当前的）。
        // 而兜底时长即使偏长也无害 —— 匹配到下一条时会自然替换。
        // 包自带结束时间的（SRT 文本块 / WebVTT）当然用真实值。
        if (ev.endMs <= 0) {
            ev.endMs = ev.startMs + kSubtitleFallbackMs;
        }
        out = ev;
        s->subtitleCount++;
        return kOk;
    }
    return kAgain;
}

int32_t AudioSampleRate() {
    return kAudioSampleRate;
}

int32_t AudioChannels() {
    return kAudioChannels;
}

/**
 * 抽一帧画面并存成 JPEG（用于生成缩略图）
 *
 * 为什么自己抽帧而不是继续用系统的 AVImageGenerator：
 *   实测系统对 .rm / .wmv / .ogv 完全无能为力 ——
 *   日志里一直是 "THUMB FAIL ... 12_rv10.rm :: SYNC@500000 err=5400106"，
 *   结果这些格式在首页和搜索页永远是灰底占位，用户一眼就能看出缺陷。
 *   而 FFmpeg 本来就能解这些格式，抽一帧是顺手的事。
 *
 * 实现上直接输出 JPEG，不再走 PixelMap：
 *   原来那条路要"解码出 PixelMap → 编码 JPEG → 再解码回来 → 存文件"，
 *   中间那次往返是为了摆脱解码器资源（PixelMap 可能依赖已释放的解码器）。
 *   既然在原生侧解码，直接用 FFmpeg 的 mjpeg 编码器写文件，
 *   既不依赖任何外部资源，也少一次编解码。
 *
 * 几个要点：
 *   ① 缩放必须保持宽高比，缩略图被拉伸变形很难看
 *   ② 宽高都要取偶数：mjpeg 编码器对此有硬要求
 *   ③ 不放大：放大只会更糊更慢
 *   ④ 解码设上限：坏文件上不能无限循环，否则会把界面卡住
 *   ⑤ **必须处理旋转元数据** —— 手机竖拍视频存储是横向的，
 *      不转的话缩略图是躺着的（手机视频里这类很常见）
 */
int32_t ExtractFrameToJpeg(const std::string &srcPath, const std::string &dstPath,
                           int64_t atMs, int32_t targetW, std::string &errMsg) {
    // ---- 打开源文件 ----
    AVFormatContext *fmt = nullptr;
    int ret = avformat_open_input(&fmt, srcPath.c_str(), nullptr, nullptr);
    if (ret < 0) {
        errMsg = "avformat_open_input: " + AvErr(ret);
        return kOpenFailed;
    }
    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        errMsg = "avformat_find_stream_info: " + AvErr(ret);
        avformat_close_input(&fmt);
        return kOpenFailed;
    }

    const AVCodec *vdec = nullptr;
    const int vIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &vdec, 0);
    if (vIdx < 0 || vdec == nullptr) {
        errMsg = "找不到视频流";
        avformat_close_input(&fmt);
        return kNoStream;
    }

    AVCodecContext *vctx = avcodec_alloc_context3(vdec);
    if (vctx == nullptr) {
        errMsg = "avcodec_alloc_context3 失败";
        avformat_close_input(&fmt);
        return kDecoderOpenFailed;
    }
    ret = avcodec_parameters_to_context(vctx, fmt->streams[vIdx]->codecpar);
    if (ret < 0) {
        errMsg = "avcodec_parameters_to_context: " + AvErr(ret);
        avcodec_free_context(&vctx);
        avformat_close_input(&fmt);
        return kDecoderOpenFailed;
    }
    ret = avcodec_open2(vctx, vdec, nullptr);
    if (ret < 0) {
        errMsg = "avcodec_open2: " + AvErr(ret);
        avcodec_free_context(&vctx);
        avformat_close_input(&fmt);
        return kDecoderOpenFailed;
    }

    // ---- seek 到目标位置 ----
    // 往前找关键帧：抽帧不需要精确到那一毫秒，能拿到画面就行
    if (atMs > 0) {
        const int64_t ts = av_rescale_q(atMs, AVRational{1, 1000}, fmt->streams[vIdx]->time_base);
        av_seek_frame(fmt, vIdx, ts, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(vctx);
    }

    // ---- 解码直到拿到一帧 ----
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    bool gotFrame = false;
    if (frame != nullptr && pkt != nullptr) {
        // 上限 400 个包：足够跨过 seek 之后的一小段，又不会在坏文件上死循环
        for (int guard = 0; guard < 400 && !gotFrame; guard++) {
            ret = avcodec_receive_frame(vctx, frame);
            if (ret == 0) {
                gotFrame = true;
                break;
            }
            if (ret == AVERROR_EOF) {
                break;
            }
            if (ret != AVERROR(EAGAIN)) {
                errMsg = "avcodec_receive_frame: " + AvErr(ret);
                break;
            }
            ret = av_read_frame(fmt, pkt);
            if (ret == AVERROR_EOF) {
                avcodec_send_packet(vctx, nullptr);
                continue;
            }
            if (ret < 0) {
                errMsg = "av_read_frame: " + AvErr(ret);
                break;
            }
            if (pkt->stream_index == vIdx) {
                avcodec_send_packet(vctx, pkt);
            }
            av_packet_unref(pkt);
        }
    } else {
        errMsg = "分配 AVFrame/AVPacket 失败";
    }

    if (!gotFrame) {
        if (errMsg.empty()) {
            errMsg = "在目标位置附近没有解出任何画面";
        }
        if (pkt != nullptr) { av_packet_free(&pkt); }
        if (frame != nullptr) { av_frame_free(&frame); }
        avcodec_free_context(&vctx);
        avformat_close_input(&fmt);
        return kDecodeFailed;
    }

    // ---- 读出旋转角度（见 ExtractFrameToJpeg 注释⑤）----
    int rotDeg = 0;
    {
        const AVPacketSideData *rsd = av_packet_side_data_get(
            fmt->streams[vIdx]->codecpar->coded_side_data,
            fmt->streams[vIdx]->codecpar->nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX);
        if (rsd != nullptr && rsd->size >= 9 * sizeof(int32_t)) {
            const double ccw = av_display_rotation_get(
                reinterpret_cast<const int32_t *>(rsd->data));
            if (!std::isnan(ccw)) {
                int d = static_cast<int32_t>(-ccw);
                d = ((d % 360) + 360) % 360;
                if (d % 90 == 0) {
                    rotDeg = d;
                }
            }
        }
    }

    // ---- 计算缩略图尺寸（保持宽高比，且宽高都取偶数）----
    //
    // ★ 旋转 90/270 时"显示宽高"是存储宽高互换，必须按互换后的比例算，
    //   否则算出来的缩略图比例是错的（竖拍视频会得到又扁又小的图）。
    const int dispW = (rotDeg == 90 || rotDeg == 270) ? frame->height : frame->width;
    const int dispH = (rotDeg == 90 || rotDeg == 270) ? frame->width : frame->height;

    int outW = (targetW > 0) ? targetW : dispW;
    if (outW > dispW) {
        outW = dispW;   // 不放大
    }
    outW = outW & ~1;          // mjpeg 要求偶数
    if (outW < 2) { outW = 2; }
    int outH = static_cast<int>(static_cast<int64_t>(dispH) * outW / dispW);
    outH = outH & ~1;
    if (outH < 2) { outH = 2; }

    // ---- 缩放 ----
    //
    // 分两步做：① sws_scale 缩放到"旋转前的尺寸" ② 再按角度搬像素。
    // 为什么不一步到位（直接让 sws 输出旋转后的尺寸）：sws_scale 只能缩放，
    // 不会旋转 —— 直接按 (outH,outW) 输出只会把画面拉扁，不是旋转。
    //
    // 中间尺寸 (midW, midH)：旋转 90/270 时与最终尺寸互换，180 时相同
    const bool swap = (rotDeg == 90 || rotDeg == 270);
    const int midW = swap ? outH : outW;
    const int midH = swap ? outW : outH;

    SwsContext *sws = sws_getContext(frame->width, frame->height,
                                     static_cast<AVPixelFormat>(frame->format),
                                     midW, midH, AV_PIX_FMT_YUVJ420P,
                                     SWS_BILINEAR, nullptr, nullptr, nullptr);
    AVFrame *scaled = (sws != nullptr) ? av_frame_alloc() : nullptr;
    bool scaledOk = false;
    if (sws != nullptr && scaled != nullptr) {
        scaled->format = AV_PIX_FMT_YUVJ420P;
        scaled->width = midW;
        scaled->height = midH;
        if (av_frame_get_buffer(scaled, 32) >= 0) {
            sws_scale(sws, frame->data, frame->linesize, 0, frame->height,
                      scaled->data, scaled->linesize);
            scaledOk = true;
        }
    }
    if (!scaledOk) {
        errMsg = "缩略图缩放失败";
        if (scaled != nullptr) { av_frame_free(&scaled); }
        if (sws != nullptr) { sws_freeContext(sws); }
        av_packet_free(&pkt);
        av_frame_free(&frame);
        avcodec_free_context(&vctx);
        avformat_close_input(&fmt);
        return kDecodeFailed;
    }

    // ---- 按角度旋转到最终尺寸 ----
    AVFrame *rotated = nullptr;
    if (rotDeg != 0) {
        rotated = av_frame_alloc();
        bool rotOk = false;
        if (rotated != nullptr) {
            rotated->format = AV_PIX_FMT_YUVJ420P;
            rotated->width = outW;
            rotated->height = outH;
            if (av_frame_get_buffer(rotated, 32) >= 0) {
                RotateYuv420(scaled, rotated, rotDeg);
                rotOk = true;
            }
        }
        if (!rotOk) {
            // 旋转失败不算致命：交回未旋转的画面，总比什么都没有好。
            // 但要留下日志，否则"缩略图躺着了"会很难查。
            LOGW("缩略图旋转失败，回退为未旋转画面（旋转 %{public}d 度）", rotDeg);
            if (rotated != nullptr) { av_frame_free(&rotated); }
            rotated = nullptr;
        }
    }

    // 后续编码用 effective 指向真正要编码的那一帧
    const AVFrame *effective = (rotated != nullptr) ? rotated : scaled;
    const int encW = (rotated != nullptr) ? outW : midW;
    const int encH = (rotated != nullptr) ? outH : midH;
    if (rotated == nullptr && rotDeg != 0) {
        // 旋转失败时尺寸用的是中间尺寸，outW/outH 要跟着改，
        // 否则后面编码器按错误的宽高配置，出来的图会错位
        LOGW("尺寸回退为中间尺寸 %{public}dx%{public}d", midW, midH);
    }

    // ---- 用 image2 + mjpeg 编码写文件 ----
    // image2 复用器的用途就是"把单张图片写成一个文件"，正好是这个场景
    int32_t result = kOk;
    AVFormatContext *outCtx = nullptr;
    AVCodecContext *jctx = nullptr;
    AVPacket *jpkt = nullptr;
    do {
        if (avformat_alloc_output_context2(&outCtx, nullptr, "image2", dstPath.c_str()) < 0
            || outCtx == nullptr) {
            errMsg = "创建 image2 输出上下文失败";
            result = kOpenFailed;
            break;
        }
        const AVCodec *jenc = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
        if (jenc == nullptr) {
            errMsg = "找不到 mjpeg 编码器（这份 FFmpeg 构建未启用）";
            result = kDecoderOpenFailed;
            break;
        }
        AVStream *outStream = avformat_new_stream(outCtx, nullptr);
        jctx = avcodec_alloc_context3(jenc);
        jpkt = av_packet_alloc();
        if (outStream == nullptr || jctx == nullptr || jpkt == nullptr) {
            errMsg = "分配编码器资源失败";
            result = kDecoderOpenFailed;
            break;
        }
        // 用 encW/encH 而不是 outW/outH：旋转成功时两者相同，
        // 旋转失败时会退回中间尺寸 —— 编码器必须按实际要编码的那一帧配置，
        // 否则 mjpeg 会因为尺寸不符而报错或产出错位的图
        jctx->width = encW;
        jctx->height = encH;
        jctx->pix_fmt = AV_PIX_FMT_YUVJ420P;
        jctx->time_base = AVRational{1, 25};
        // 缩略图不需要最高质量，但也不能太糊；5 是常用的折中值
        jctx->compression_level = 5;
        if (avcodec_open2(jctx, jenc, nullptr) < 0
            || avcodec_parameters_from_context(outStream->codecpar, jctx) < 0) {
            errMsg = "mjpeg 编码器初始化失败";
            result = kDecoderOpenFailed;
            break;
        }
        if (avio_open(&outCtx->pb, dstPath.c_str(), AVIO_FLAG_WRITE) < 0) {
            errMsg = "无法写入 " + dstPath;
            result = kOpenFailed;
            break;
        }
        if (avformat_write_header(outCtx, nullptr) < 0) {
            errMsg = "写 JPEG 文件头失败";
            result = kOpenFailed;
            break;
        }
        scaled->pts = 0;
        if (effective != scaled) {
            // 旋转过：编码旋转后的帧。它的尺寸已按需互换/翻转，直接可用。
            const_cast<AVFrame *>(effective)->pts = 0;
        }
        if (avcodec_send_frame(jctx, effective) < 0
            || avcodec_receive_packet(jctx, jpkt) < 0) {
            errMsg = "JPEG 编码失败";
            result = kDecodeFailed;
            break;
        }
        jpkt->stream_index = outStream->index;
        if (av_write_frame(outCtx, jpkt) < 0) {
            errMsg = "写 JPEG 数据失败";
            result = kDecodeFailed;
            break;
        }
        av_write_trailer(outCtx);
    } while (false);

    // ---- 清理（无论成败都要走完，否则会泄漏）----
    if (jpkt != nullptr) { av_packet_free(&jpkt); }
    if (jctx != nullptr) { avcodec_free_context(&jctx); }
    if (outCtx != nullptr) {
        if (outCtx->pb != nullptr) {
            avio_closep(&outCtx->pb);
        }
        avformat_free_context(outCtx);
    }
    sws_freeContext(sws);
    if (rotated != nullptr) { av_frame_free(&rotated); }
    av_frame_free(&scaled);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&vctx);
    avformat_close_input(&fmt);

    if (result == kOk) {
        LOGI("抽帧成功: %{public}s @%{public}lldms -> %{public}dx%{public}d JPEG（旋转%{public}d度）",
             srcPath.c_str(), static_cast<long long>(atMs), encW, encH, rotDeg);
    } else {
        LOGE("抽帧失败: %{public}s @%{public}lldms: %{public}s",
             srcPath.c_str(), static_cast<long long>(atMs), errMsg.c_str());
    }
    return result;
}

int32_t Seek(Session session, int64_t positionMs, std::string &errMsg) {
    auto *s = static_cast<DecoderSession *>(session);
    if (s == nullptr) {
        errMsg = "会话无效";
        return kSeekFailed;
    }
    if (positionMs < 0) {
        positionMs = 0;
    }
    // ★ 架构修复后这里只是「投递请求」：
    //   av_seek_frame 会重置 fmtCtx 的读位置与内部缓冲，必须由独占 fmtCtx 的
    //   解复用线程执行（见 DemuxLoop / SeekInternal）。
    //   旧实现是在调用线程里直接 seek，靠 demuxMutex 与解码线程串行 ——
    //   代价是 seek 期间两边互相等待、播放明显卡顿。
    //   新实现是异步的：投递后立即返回，解复用线程在下一轮开头执行。
    //
    //   注意：因为是异步，调用方在 seek 之后应清掉自己队列里已解出的帧
    //   （引擎侧 DoSeek 里的 frameQueue_->Clear() 就是这个作用）。
    s->pendingSeekMs.store(positionMs);
    // 唤醒可能正阻塞在「队列满」上的解复用线程，让它尽快处理 seek
    if (s->videoQueue != nullptr) {
        s->videoQueue->notFull.notify_all();
    }
    if (s->audioQueue != nullptr) {
        s->audioQueue->notFull.notify_all();
    }
    return kOk;
}

void Close(Session session) {
    auto *s = static_cast<DecoderSession *>(session);
    if (s == nullptr) {
        return;
    }

    // ---------- ① 先停解复用线程，再释放任何它可能用到的资源 ----------
    //
    // 顺序是决定性的：解复用线程持有 fmtCtx、并且可能正阻塞在
    // av_read_frame 的文件 I/O 上。如果先释放 fmtCtx 再 join，
    // 就是「一边用一边释放」—— 直接段错误。
    s->demuxAbort.store(true);            // 让中断回调把 av_read_frame 打断
    if (s->videoQueue != nullptr) {
        s->videoQueue->Abort();           // 唤醒可能阻塞在「队列满」上的生产者
    }
    if (s->audioQueue != nullptr) {
        s->audioQueue->Abort();
    }
    if (s->subtitleQueue != nullptr) {
        s->subtitleQueue->Abort();
    }
    if (s->demuxThreadStarted.load() && s->demuxThread.joinable()) {
        s->demuxThread.join();
    }

    // ---- 字幕资源 ----
    if (s->subtitleFrame != nullptr) {
        av_frame_free(&s->subtitleFrame);
    }
    if (s->subtitleCtx != nullptr) {
        avcodec_free_context(&s->subtitleCtx);
    }
    if (s->subtitlePacket != nullptr) {
        av_packet_free(&s->subtitlePacket);
    }

    // ---- 音频资源 ----
    if (s->resampleBuf != nullptr) {
        av_freep(&s->resampleBuf);
    }
    if (s->swr != nullptr) {
        swr_free(&s->swr);
    }
    if (s->audioFrame != nullptr) {
        av_frame_free(&s->audioFrame);
    }
    if (s->audioCtx != nullptr) {
        avcodec_free_context(&s->audioCtx);
    }
    // ---- 视频资源 ----
    if (s->sws != nullptr) {
        sws_freeContext(s->sws);
    }
    if (s->convFrame != nullptr) {
        av_frame_free(&s->convFrame);
    }
    if (s->rawFrame != nullptr) {
        av_frame_free(&s->rawFrame);
    }
    // 三个包各自释放：读包用、音频解码用、视频解码用
    if (s->packet != nullptr) {
        av_packet_free(&s->packet);
    }
    if (s->audioPacket != nullptr) {
        av_packet_free(&s->audioPacket);
    }
    if (s->videoPacket != nullptr) {
        av_packet_free(&s->videoPacket);
    }
    if (s->videoCtx != nullptr) {
        avcodec_free_context(&s->videoCtx);
    }
    // 队列必须在 fmtCtx 之后释放（队列析构会 av_packet_free 里面的包，
    // 而那些包是 fmtCtx 解出来的 —— 虽然包本身自带引用计数、
    // 顺序其实无所谓，但保持「先关输入、再清缓存」更符合直觉）
    if (s->fmtCtx != nullptr) {
        avformat_close_input(&s->fmtCtx);
    }
    s->videoQueue.reset();
    s->audioQueue.reset();
    s->subtitleQueue.reset();
    delete s;
}

/**
 * 不带轨道选择的 Open：等价于全 -1（自动选音轨、不开字幕）
 *
 * 放在真正实现之后定义，这样上面那个五参数版本不需要前置声明。
 */
int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg) {
    TrackRequest autoPick;   // audioStreamIndex = -1, subtitleStreamIndex = -1
    return Open(path, outSession, out, errMsg, autoPick);
}

#else  // !SOFT_PLAYER_WITH_FFMPEG

std::string VersionString() {
    return "not-integrated";
}

bool IsIntegrated() {
    return false;
}

int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg) {
    (void)path;
    (void)outSession;
    (void)out;
    errMsg = "编译时未定义 SOFT_PLAYER_WITH_FFMPEG，本构建不含软解";
    return kNotIntegrated;
}

int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg, const TrackRequest &tracks) {
    (void)tracks;
    return Open(path, outSession, out, errMsg);
}

int32_t ReadSubtitleEvent(Session session, SubtitleEvent &out, std::string &errMsg) {
    (void)session;
    (void)out;
    errMsg = "未集成 FFmpeg";
    return kNotIntegrated;
}

bool HasSubtitle(Session session) {
    (void)session;
    return false;
}

int32_t DecodeVideoFrame(Session session, VideoFrame &frame, std::string &errMsg,
                         int32_t scaleWidth, int32_t scaleHeight) {
    (void)session;
    (void)frame;
    (void)scaleWidth;
    (void)scaleHeight;
    errMsg = "未集成 FFmpeg";
    return kNotIntegrated;
}

int32_t Seek(Session session, int64_t positionMs, std::string &errMsg) {
    (void)session;
    (void)positionMs;
    errMsg = "未集成 FFmpeg";
    return kNotIntegrated;
}

int32_t DecodeAudioChunk(Session session, AudioChunk &chunk, std::string &errMsg) {
    (void)session;
    (void)chunk;
    errMsg = "未集成 FFmpeg";
    return kNotIntegrated;
}

bool HasAudio(Session session) {
    (void)session;
    return false;
}

int32_t AudioSampleRate() {
    return 48000;
}

int32_t AudioChannels() {
    return 2;
}

int32_t ExtractFrameToJpeg(const std::string &srcPath, const std::string &dstPath,
                           int64_t atMs, int32_t targetW, std::string &errMsg) {
    (void)srcPath;
    (void)dstPath;
    (void)atMs;
    (void)targetW;
    errMsg = "未集成 FFmpeg";
    return kNotIntegrated;
}

void Close(Session session) {
    (void)session;
}

#endif  // SOFT_PLAYER_WITH_FFMPEG

}  // namespace codecapi
}  // namespace softplayer
