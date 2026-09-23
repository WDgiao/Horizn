#ifndef SOFT_PLAYER_AUDIO_OUTPUT_H
#define SOFT_PLAYER_AUDIO_OUTPUT_H

#include "PcmRingBuffer.h"

// OHAudio 的头必须在这里引入，不能靠前向声明。
// 原因：它们把 OH_AudioRenderer / OH_AudioData_Callback_Result 定义成
// typedef（`typedef struct OH_AudioRendererStruct OH_AudioRenderer;`），
// 而我们若写 `struct OH_AudioRenderer;` 声明的是另一个类型，
// 编译器会报 "typedef redefinition with different types"。
// 这几条 include 本身很轻量，代价可以接受。
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiostream_base.h>

#include <atomic>
#include <cstdint>

namespace softplayer {

/**
 * OHAudio 播放输出
 *
 * 职责：把 PCM 送到扬声器。
 *   生产者（解码线程）调 Write() 填数据；
 *   消费者是 OHAudio 自己的音频回调线程，它来取数据 —— 取不到就补静音。
 *
 * ★ 关键约定：音频回调线程里绝不能做重活。
 *   不能加锁等（会爆音）、不能分配内存、不能解码。
 *   所以回调只做一件事：从环形缓冲 memcpy，不足部分补 0。
 *
 * 为什么用「拉模式」（系统回调我们）而不是「推模式」（我们主动写）：
 *   拉模式由音频硬件驱动节奏，天然与设备时钟对齐，不需要我们自己算
 *   "现在该送多少数据" —— 音画同步的基准也因此更稳。
 */
class AudioOutput {
public:
    AudioOutput();
    ~AudioOutput();

    AudioOutput(const AudioOutput &) = delete;
    AudioOutput &operator=(const AudioOutput &) = delete;

    /**
     * 创建并启动音频流
     * @param sampleRate 采样率（我们用固定的 48000）
     * @param channels 声道数（固定的 2）
     * @return 是否成功
     */
    bool Start(int32_t sampleRate, int32_t channels);

    /** 暂停输出（保留缓冲内容，可继续） */
    void Pause();

    /** 恢复输出 */
    void Resume();

    /**
     * 停止并释放音频流
     * 会等待回调线程退出，因此调用前应先停止生产者写入
     */
    void Stop();

    /** 是否已启动 */
    bool IsRunning() const { return renderer_ != nullptr; }

    /** 是否处于暂停态（用于避免对已运行的流重复调 Start） */
    bool IsPaused() const { return paused_.load(); }

    /**
     * 写入 PCM（仅生产者线程调用）
     * @return 实际写入字节数；返回 0 表示缓冲已满，调用方应稍后再试
     */
    size_t Write(const uint8_t *data, size_t bytes);

    /** 缓冲里还有多少字节没播 */
    size_t BufferedBytes() const;

    /** 缓冲容量（字节） */
    size_t CapacityBytes() const;

    /** 累计欠载次数（数据没跟上导致补静音的次数）——诊断用 */
    int64_t UnderrunCount() const { return underrunCount_.load(); }

    /** 累计已播放样本帧数（用于音频时钟） */
    int64_t FramesPlayed() const { return framesPlayed_.load(); }

    /** 因缓冲满而写入失败的次数 */
    int64_t OverflowCount() const { return overflowCount_.load(); }

    /** 清空缓冲（seek 时用，调用方需保证生产者已暂停写入） */
    void FlushBuffer();

private:
    /**
     * OHAudio 回调：从这里取数据填进 audioData
     *
     * 返回值用 ohaudio 的枚举（这里前向声明成同名 enum），
     * 不是 int32_t —— 写成 int32_t 会导致回调注册时类型不匹配编不过。
     */
    static OH_AudioData_Callback_Result OnWriteData(OH_AudioRenderer *renderer, void *userData,
                                                   void *audioData, int32_t audioDataSize);

    /** 音频流句柄（OH_AudioRenderer*） */
    OH_AudioRenderer *renderer_ = nullptr;
    /** PCM 缓冲：2 秒容量。足够吸收解码抖动，又不会让 seek 太迟滞 */
    PcmRingBuffer ring_;
    int32_t sampleRate_ = 48000;
    int32_t channels_ = 2;
    /** 每帧字节数 = 声道数 × 2（S16LE） */
    int32_t bytesPerFrame_ = 4;

    std::atomic<int64_t> underrunCount_{0};
    std::atomic<int64_t> framesPlayed_{0};
    std::atomic<int64_t> overflowCount_{0};
    std::atomic<bool> paused_{false};
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_AUDIO_OUTPUT_H
