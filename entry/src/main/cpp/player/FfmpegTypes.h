#ifndef SOFT_PLAYER_FFMPEG_TYPES_H
#define SOFT_PLAYER_FFMPEG_TYPES_H

#include <cstdint>
#include <chrono>
#include <deque>
#include <mutex>
#include <condition_variable>
#include <string>
#include <vector>

namespace softplayer {

/**
 * 解码出的一帧画面
 *
 * ★ 用 RGB565 而不是 YUV420 —— 这是实测逼出来的结论：
 *   surface 的 buffer 格式是 NATIVEBUFFER_PIXEL_FMT_RGBX_8888（枚举值 12，
 *   实为 2 字节/像素的 RGB565：stride 4352 = 1084*4，buffer 2838528 ≈ 1084*650*4）。
 *   按 NV12 往里写会导致：
 *     ① 布局完全错 → 画面是彩色噪点或全黑
 *     ② 尺寸对不上 → Y 平面就吃掉 2654720 字节，色度平面越界 → SIGSEGV
 *   所以直接在 FFmpeg 侧转成 RGB565，再逐行拷进 buffer。
 *
 * 为什么不做 YUV→RGB 的"零拷贝"幻想：
 *   硬解可以直出 YUV 并交给 GPU 转换，但我们是软解（FFmpeg 出 YUV420），
 *   而消费端是 RGB 的 surface，中间这次转换省不掉。
 *   sws_scale 用 SWS_FAST_BILINEAR，1080p 每帧约 2~4ms，可接受。
 */
struct VideoFrame {
    /** 紧凑存放的像素数据（RGB565 打包，行间按 stride 对齐） */
    std::vector<uint8_t> data;
    /** 每行字节数（RGB565 时 = 宽度*2，可能有对齐填充） */
    int stride = 0;
    /** 画面宽高 */
    int width = 0;
    int height = 0;
    /** 显示时间戳（毫秒） */
    int64_t ptsMs = 0;
    /**
     * 该帧应显示多久（毫秒）
     *
     * 用途：帧间隔兜底。某些流（实测 .rm 的 RealVideo）相邻帧时间戳相同或缺失，
     * 那时播放器只能按这个值给每帧安排时长，否则整片会被瞬间播完。
     */
    int64_t durationMs = 0;

    /**
     * 释放内存，避免大帧在队列里堆积
     *
     * ★ 2026-10-03：这里【故意不调 shrink_to_fit】。
     *   像素缓冲现在是按池复用的（见 codecapi::RecycleFrameBuffer）：
     *   清空长度、保留容量，下次解码才能直接拿回去接着写。
     *   一旦 shrink_to_fit，容量被放掉，池子就等于不存在，
     *   会退回"每帧重新分配 3.7MB"的老路（实测 79ms/帧，是 .rmvb 卡顿的主因）。
     *   真正的内存回收交给对象析构（帧被队列挤掉时 vector 自然释放）。
     */
    void Clear() {
        data.clear();
        stride = 0;
        width = 0;
        height = 0;
        ptsMs = 0;
        durationMs = 0;
    }
};

/**
 * 线程安全的帧队列
 *
 * 设计要点：
 *   - 有上限（maxSize），满了就丢最旧的帧 —— 这是播放器的常规做法：
 *     宁愿掉帧也不要让解码线程阻塞，否则 seek 和暂停响应会卡住
 *   - 丢帧时记录丢了多少，便于诊断"卡顿"到底是解码慢还是渲染慢
 *   - 可中断：Release 时用 Abort 唤醒所有等待者，避免线程卡在 wait 上退不出去
 */
class FrameQueue {
public:
    explicit FrameQueue(size_t maxSize) : maxSize_(maxSize) {}

    /** 入队；队列满时丢弃最旧的一帧 */
    void Push(VideoFrame &frame) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (aborted_) {
            return;
        }
        while (queue_.size() >= maxSize_) {
            queue_.pop_front();
            dropped_++;
        }
        queue_.push_back(std::move(frame));
        notEmpty_.notify_one();
    }

    /**
     * 出队，队列空时最多等 waitMs 毫秒
     * @return true 取到帧；false 超时或被中断
     */
    bool Pop(VideoFrame &out, int waitMs) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (queue_.empty() && !aborted_) {
            notEmpty_.wait_for(lock, std::chrono::milliseconds(waitMs),
                               [this] { return !queue_.empty() || aborted_; });
        }
        if (aborted_ || queue_.empty()) {
            return false;
        }
        out = std::move(queue_.front());
        queue_.pop_front();
        return true;
    }

    /** 清空队列（seek 时调用） */
    void Clear() {
        std::unique_lock<std::mutex> lock(mutex_);
        queue_.clear();
    }

    /**
     * 看一眼队头帧的 pts，但不取走（2026-10-03 新增）
     *
     * 用途：上层要按主时钟决定"现在该不该显示队头这一帧"。
     * 必须有它，是因为"取出来再等"和"先看再取"完全不是一回事：
     *   · 取出来 = 这一帧已经离开队列，只能选择显示或丢掉，没法再放回去；
     *   · 先看再取 = 还没到显示时刻就让它在队列里继续待着，
     *     解码线程也自然被队列上限挡住，画面**领先量被压在一个队列深度内**。
     * 这正是修掉"画面 2.5 倍速狂奔"的关键（旧写法把帧取出来后才判断，
     * 一旦判断成"领先"就只能把等待置 0，等于关闭节流）。
     *
     * @return true 表示取到队头的 pts；false 表示队列空（或已中止）
     */
    bool Peek(int64_t &ptsMs) const {
        std::unique_lock<std::mutex> lock(mutex_);
        if (aborted_ || queue_.empty()) {
            return false;
        }
        ptsMs = queue_.front().ptsMs;
        return true;
    }

    /** 唤醒所有等待者并让后续操作直接返回，用于线程退出 */
    void Abort() {
        std::unique_lock<std::mutex> lock(mutex_);
        aborted_ = true;
        notEmpty_.notify_all();
    }

    /** 累计丢帧数 */
    size_t DroppedCount() const {
        std::unique_lock<std::mutex> lock(mutex_);
        return dropped_;
    }

    /** 队列当前长度 */
    size_t Size() const {
        std::unique_lock<std::mutex> lock(mutex_);
        return queue_.size();
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable notEmpty_;
    std::deque<VideoFrame> queue_;
    size_t maxSize_;
    size_t dropped_ = 0;
    bool aborted_ = false;
};

/**
 * 可打断的 sleep
 *
 * 主循环里要"精确睡到下一帧的时间点"，但 sleep 期间必须能被
 * pause / seek / release 立刻打断，否则操作要等一整帧才生效。
 */
class InterruptibleSleep {
public:
    /** 睡 ms 毫秒，期间若被 Wake 则提前返回 */
    void Sleep(int ms) {
        if (ms <= 0) {
            return;
        }
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait_for(lock, std::chrono::milliseconds(ms), [this] { return woken_; });
        woken_ = false;
    }

    /** 立刻唤醒正在 Sleep 的线程 */
    void Wake() {
        std::unique_lock<std::mutex> lock(mutex_);
        woken_ = true;
        cv_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool woken_ = false;
};

/**
 * 音频轨信息
 *
 * 为什么需要它：
 *   原先 Open() 用 av_find_best_stream 只挑"最好"的一条音轨，用户完全看不到
 *   文件里还有别的音轨，更没法切换（多语言影片、导演评论轨都取不到）。
 *   这里把可切换的音轨列出来交给界面做选择。
 */
struct AudioTrackInfo {
    /**
     * 在 AVFormatContext->streams[] 里的下标
     *
     * 这是切换音轨时传给引擎的唯一标识 —— 切换的实现是
     * 「用新的下标重新 Open 一次 + seek 回原位置」，所以必须有稳定标识。
     */
    int32_t index = -1;
    /** 编码名，例如 "aac" / "ac3" / "dca" */
    std::string codec;
    /** 语言标签（容器里的 metadata language，可能是 "chi" / "eng" / "jpn"） */
    std::string language;
    /** 轨道标题（例如 "国语" / "Director's Commentary"） */
    std::string title;
    /** 声道数，0 表示未知 */
    int32_t channels = 0;
    /** 采样率，0 表示未知 */
    int32_t sampleRate = 0;
    /** 码率（bps），0 表示未知 */
    int64_t bitRate = 0;
    /** 是否为容器标记的默认轨 */
    bool isDefault = false;
};

/**
 * 字幕轨信息
 *
 * 只列「文本型」字幕。位图字幕（PGS / VobSub / DVB）虽然也在这里列出，
 * 但 supported 为 false —— 原因见 SubtitleEvent 的说明。
 */
struct SubtitleTrackInfo {
    /** 在 AVFormatContext->streams[] 里的下标 */
    int32_t index = -1;
    /** 编码名，例如 "subrip" / "ass" / "mov_text" / "hdmv_pgs_subtitle" */
    std::string codec;
    std::string language;
    std::string title;
    /** 是否为容器标记的默认轨 */
    bool isDefault = false;
    /**
     * 是否支持解码成文本
     *
     * 位图字幕（pgs / dvd_subtitle / dvb_subtitle / xsub）需要按调色板
     * 还原成图片再叠加，本播放器只做文本字幕，所以这些会列出来但标记为
     * 不支持 —— 让用户知道"这条轨道存在但放不了"，比直接隐藏更诚实。
     */
    bool supported = false;
};

/**
 * 一条字幕事件
 *
 * 为什么用「开始/结束时间 + 文本」这种简单模型，而不是复用 FFmpeg 的 ASS 样式：
 *   本播放器不支持 libass 渲染（那份 FFmpeg 构建里 CONFIG_ASS_DECODER=0，
 *   而且 libass 依赖字体配置，HarmonyOS 上落地成本很高）。
 *   所以 ASS 只取出纯文本，丢掉样式与定位 —— 这是有意取舍：
 *   「能看到字幕」比「字幕样式完全还原」重要得多。
 */
struct SubtitleEvent {
    /** 该条字幕开始显示的时间（毫秒） */
    int64_t startMs = 0;
    /** 该条字幕结束显示的时间（毫秒）；0 表示由下一条的到来或固定时长兜底 */
    int64_t endMs = 0;
    /** 文本内容（多行用 '\n' 分隔，ASS 已经换成换行） */
    std::string text;
};

/** 音频输出参数 */
struct AudioSpec {
    int sampleRate = 0;
    int channels = 0;
    /** 每样本字节数（S16LE = 2） */
    int bytesPerSample = 2;
};

/**
 * 解码出的一段 PCM 音频
 *
 * 为什么统一成固定的输出格式（48kHz / 立体声 / S16LE）：
 *   片源里的音频五花八门（RMVB 里 cook 常见 22050Hz 单声道，
 *   AC3 常见 48kHz 5.1），而音频设备只接受一个固定配置。
 *   与其在每次播放时按片源重建音频流，不如统一用 swr 重采样到
 *   最常见的 48kHz 立体声 —— 设备兼容性最好，代码也只有一条路径。
 *
 * 为什么音频数据不做 VideoFrame 那样的队列：
 *   音频不能丢帧（丢了就是断音），所以走环形缓冲而不是"满了丢最旧"的队列。
 */
struct AudioChunk {
    /** 交错存放的 S16LE PCM 数据 */
    std::vector<uint8_t> data;
    /** 这段音频对应的起始时间戳（毫秒） */
    int64_t ptsMs = 0;
    /** 这段音频的时长（毫秒），用于推进音频时钟 */
    int64_t durationMs = 0;

    void Clear() {
        data.clear();
        data.shrink_to_fit();
        ptsMs = 0;
        durationMs = 0;
    }
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_FFMPEG_TYPES_H
