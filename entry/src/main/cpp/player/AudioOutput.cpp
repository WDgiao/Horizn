#include "AudioOutput.h"

#include <hilog/log.h>
#include <multimedia/native_audio_channel_layout.h>

#include <cstring>

#undef LOG_TAG
#define LOG_TAG "SoftPlayerAudio"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)
#define LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)

namespace softplayer {

namespace {
/** 缓冲时长（毫秒）：2 秒足够吸收解码抖动 */
constexpr int32_t kBufferMs = 2000;
/** 每次回调希望的帧数（不设的话由系统决定） */
constexpr int32_t kFrameSizeInCallback = 0;
}  // namespace

/**
 * 构造：按默认参数先建好 PCM 缓冲
 *
 * 注意必须用成员初始化列表 —— PcmRingBuffer 是可移动/不可拷贝的，
 * 在函数体里再赋值（ring_ = PcmRingBuffer(...)）会因为拷贝赋值被 delete 而编不过。
 * 反正 Start() 里真正使用的采样率固定是 48kHz / 立体声，
 * 这里按同样的参数建缓冲即可，不存在尺寸不符的问题。
 */
AudioOutput::AudioOutput()
    : ring_(static_cast<size_t>(48000) * 2 * 2 * kBufferMs / 1000) {}

AudioOutput::~AudioOutput() {
    Stop();
}

bool AudioOutput::Start(int32_t sampleRate, int32_t channels) {
    if (renderer_ != nullptr) {
        LOGW("音频流已在运行，先停止再重启");
        Stop();
    }
    if (sampleRate <= 0 || channels <= 0) {
        LOGE("音频参数非法: rate=%{public}d ch=%{public}d", sampleRate, channels);
        return false;
    }
    sampleRate_ = sampleRate;
    channels_ = channels;
    bytesPerFrame_ = channels_ * 2;  // S16LE

    OH_AudioStreamBuilder *builder = nullptr;
    OH_AudioStream_Result r = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
    if (r != AUDIOSTREAM_SUCCESS || builder == nullptr) {
        LOGE("创建音频流 builder 失败: %{public}d", static_cast<int>(r));
        return false;
    }

    // ---- 配置输出参数 ----
    // 必须与解码侧重采样后的格式严格一致，否则声音会变调或全是噪声
    OH_AudioStreamBuilder_SetSamplingRate(builder, sampleRate_);
    OH_AudioStreamBuilder_SetChannelCount(builder, channels_);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    // MOVIE：让系统按影音场景处理（会走更合适的音量/音效策略）
    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MOVIE);
    // NORMAL 延迟模式：影音播放不需要 FAST（FAST 是为实时通话/游戏准备的）
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_NORMAL);

    // 指定声道布局：不设的话系统按声道数猜，5.1 源下采样到立体声时可能出错
    OH_AudioStreamBuilder_SetChannelLayout(builder,
        channels_ == 2 ? CH_LAYOUT_STEREO : CH_LAYOUT_MONO);

    // ---- 注册写入回调 ----
    // 系统会周期性调这个函数来"取"数据，这是拉模式的核心
    r = OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, AudioOutput::OnWriteData, this);
    if (r != AUDIOSTREAM_SUCCESS) {
        LOGE("注册音频写入回调失败: %{public}d", static_cast<int>(r));
        OH_AudioStreamBuilder_Destroy(builder);
        return false;
    }

    r = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer_);
    OH_AudioStreamBuilder_Destroy(builder);
    if (r != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
        LOGE("生成音频渲染器失败: %{public}d", static_cast<int>(r));
        renderer_ = nullptr;
        return false;
    }

    r = OH_AudioRenderer_Start(renderer_);
    if (r != AUDIOSTREAM_SUCCESS) {
        LOGE("启动音频渲染器失败: %{public}d", static_cast<int>(r));
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
        return false;
    }

    paused_.store(false);
    LOGI("音频输出已启动: %{public}dHz %{public}dch S16LE, 缓冲 %{public}zu 字节",
         sampleRate_, channels_, ring_.Capacity());
    return true;
}

void AudioOutput::Pause() {
    if (renderer_ == nullptr) {
        return;
    }
    paused_.store(true);
    const OH_AudioStream_Result r = OH_AudioRenderer_Pause(renderer_);
    if (r != AUDIOSTREAM_SUCCESS) {
        LOGW("暂停音频失败: %{public}d", static_cast<int>(r));
    }
}

void AudioOutput::Resume() {
    if (renderer_ == nullptr) {
        return;
    }
    paused_.store(false);
    const OH_AudioStream_Result r = OH_AudioRenderer_Start(renderer_);
    if (r != AUDIOSTREAM_SUCCESS) {
        LOGW("恢复音频失败: %{public}d", static_cast<int>(r));
    }
}

void AudioOutput::Stop() {
    OH_AudioRenderer *r = renderer_;
    renderer_ = nullptr;
    if (r == nullptr) {
        return;
    }
    // 先停再释放：直接 release 可能在回调进行中，行为不确定
    OH_AudioRenderer_Stop(r);
    const OH_AudioStream_Result ret = OH_AudioRenderer_Release(r);
    if (ret != AUDIOSTREAM_SUCCESS) {
        LOGW("释放音频渲染器返回 %{public}d", static_cast<int>(ret));
    }
    LOGI("音频输出已停止（欠载 %{public}lld 次，缓冲满 %{public}lld 次）",
         static_cast<long long>(underrunCount_.load()),
         static_cast<long long>(overflowCount_.load()));
}

size_t AudioOutput::Write(const uint8_t *data, size_t bytes) {
    const size_t n = ring_.Write(data, bytes);
    if (n == 0) {
        overflowCount_.fetch_add(1);
    }
    return n;
}

size_t AudioOutput::BufferedBytes() const {
    return ring_.Available();
}

size_t AudioOutput::CapacityBytes() const {
    return ring_.Capacity();
}

void AudioOutput::FlushBuffer() {
    ring_.Clear();
}

/**
 * OHAudio 写入回调 —— 运行在系统的音频线程上
 *
 * 这里的要求就三条：
 *   ① 快：只做 memcpy，不做任何可能阻塞的事
 *   ② 永不失败：取不到数据就补静音，并返回 VALID
 *   ③ 不分配内存
 *
 * 为什么"取不到就补静音"而不是返回 INVALID：
 *   返回 INVALID 会让这一整块数据都不播（包括已经填好的那部分），
 *   相当于多丢一段音频；补静音则只是这一小段安静，听感上更容易接受。
 */
OH_AudioData_Callback_Result AudioOutput::OnWriteData(OH_AudioRenderer *renderer, void *userData,
                                                      void *audioData, int32_t audioDataSize) {
    // renderer 在这里用不到（数据源是 userData 里的环缓冲），显式忽略避免编译告警
    (void)renderer;
    auto *self = static_cast<AudioOutput *>(userData);
    if (self == nullptr || audioData == nullptr || audioDataSize <= 0) {
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    // 暂停时静音输出：不能什么都不做，否则会不断累积 underrun 计数
    if (self->paused_.load()) {
        memset(audioData, 0, static_cast<size_t>(audioDataSize));
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    const size_t want = static_cast<size_t>(audioDataSize);
    const size_t got = self->ring_.Read(static_cast<uint8_t *>(audioData), want);

    if (got < want) {
        // 欠载：剩余部分补静音
        memset(static_cast<uint8_t *>(audioData) + got, 0, want - got);
        self->underrunCount_.fetch_add(1);
    }

    // 已播放帧数按"实际从缓冲取走的字节"计，而不是按 want 计 ——
    // 否则欠载时补的静音也会被算成播放时间，音频时钟会跑在真实进度前面
    self->framesPlayed_.fetch_add(static_cast<int64_t>(got) / self->bytesPerFrame_);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

}  // namespace softplayer
