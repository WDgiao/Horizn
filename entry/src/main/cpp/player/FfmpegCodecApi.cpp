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
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <cstring>
#include <mutex>

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

namespace {

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
};

/** 把解码器的错误码转成可读文本 */
std::string AvErr(int err) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, buf, sizeof(buf));
    return std::string(buf);
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

    // pts 可能是 AV_NOPTS_VALUE，此时退回用 best_effort_timestamp
    int64_t pts = use->pts;
    if (pts == AV_NOPTS_VALUE) {
        pts = use->best_effort_timestamp;
    }
    if (pts == AV_NOPTS_VALUE) {
        pts = 0;
    }
    out.ptsMs = av_rescale_q(pts, s->timeBase, AVRational{1, 1000});

    // RGBA 是打包格式（单平面），按行拷进自有缓冲
    const size_t size = static_cast<size_t>(out.stride) * use->height;
    out.data.resize(size);
    memcpy(out.data.data(), use->data[0], size);
    return kOk;
}

}  // namespace

std::string VersionString() {
    return std::string(av_version_info());
}

bool IsIntegrated() {
    return true;
}

int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg) {
    outSession = nullptr;

    // ---- 打开容器 ----
    AVFormatContext *fmt = nullptr;
    int ret = avformat_open_input(&fmt, path.c_str(), nullptr, nullptr);
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

    // ---- 找流 ----
    // av_find_best_stream 会顺带把解码器找出来，比自己遍历更省事
    const AVCodec *vdec = nullptr;
    const int vIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &vdec, 0);
    const int aIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);

    if (vIdx < 0 && aIdx < 0) {
        errMsg = "没有找到任何音视频流";
        avformat_close_input(&fmt);
        return kNoStream;
    }

    auto *s = new DecoderSession();
    s->fmtCtx = fmt;

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
        const char *pf = av_get_pix_fmt_name(vctx->pix_fmt);
        out.pixelFormat = pf != nullptr ? pf : "unknown";
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

    s->packet = av_packet_alloc();
    s->audioPacket = av_packet_alloc();
    s->rawFrame = av_frame_alloc();
    if (s->packet == nullptr || s->audioPacket == nullptr || s->rawFrame == nullptr) {
        errMsg = "av_packet_alloc / av_frame_alloc 失败";
        delete s;
        return kDecoderOpenFailed;
    }

    outSession = s;
    return kOk;
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

        // 送一个包（视频）
        // ★ 必须持锁：av_read_frame 会改动 fmtCtx 的内部读状态，
        //   而音频线程也在读同一个 fmtCtx —— 不加锁就是上面注释里那次崩溃
        // ★ 必须用视频自己的 packet：与音频共用会让解码器读到被覆盖的数据
        int rret = 0;
        {
            std::lock_guard<std::mutex> lock(s->demuxMutex);
            rret = av_read_frame(s->fmtCtx, s->packet);
        }
        if (rret == AVERROR_EOF) {
            // 输入结束：送一个空包冲刷解码器里缓冲的帧
            avcodec_send_packet(s->videoCtx, nullptr);
            continue;
        }
        if (rret < 0) {
            errMsg = "av_read_frame: " + AvErr(rret);
            return kDecodeFailed;
        }
        if (s->packet->stream_index != s->videoStreamIndex) {
            // 音频/字幕包先丢掉（音频由另一条线程单独解）
            av_packet_unref(s->packet);
            continue;
        }
        rret = avcodec_send_packet(s->videoCtx, s->packet);
        av_packet_unref(s->packet);
        if (rret < 0 && rret != AVERROR(EAGAIN)) {
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

        // 送一个包（音频）—— 必须持锁读 fmtCtx，且必须用音频自己的 packet
        int rret = 0;
        {
            std::lock_guard<std::mutex> lock(s->demuxMutex);
            rret = av_read_frame(s->fmtCtx, s->audioPacket);
        }
        if (rret == AVERROR_EOF) {
            avcodec_send_packet(s->audioCtx, nullptr);
            continue;
        }
        if (rret < 0) {
            errMsg = "av_read_frame(audio): " + AvErr(rret);
            return kDecodeFailed;
        }
        if (s->audioPacket->stream_index != s->audioStreamIndex) {
            av_packet_unref(s->audioPacket);
            continue;
        }
        rret = avcodec_send_packet(s->audioCtx, s->audioPacket);
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

int32_t AudioSampleRate() {
    return kAudioSampleRate;
}

int32_t AudioChannels() {
    return kAudioChannels;
}

int32_t Seek(Session session, int64_t positionMs, std::string &errMsg) {
    auto *s = static_cast<DecoderSession *>(session);
    if (s == nullptr) {
        errMsg = "会话无效";
        return kSeekFailed;
    }
    const int64_t ts = av_rescale_q(positionMs, AVRational{1, 1000}, s->timeBase);
    // ★ 持锁做 seek：av_seek_frame 会重置 fmtCtx 的读位置与内部缓冲，
    //   而此刻音频线程可能正在 av_read_frame —— 并发同样是崩溃来源。
    //   这也是为什么 seek 期间播放会短暂卡顿：两边在抢同一把锁，必须串行。
    int ret = 0;
    {
        std::lock_guard<std::mutex> lock(s->demuxMutex);
        // 必须往前找关键帧：不加 BACKWARD 会跳到目标之后，画面接不上
        ret = av_seek_frame(s->fmtCtx, s->videoStreamIndex, ts, AVSEEK_FLAG_BACKWARD);
    }
    if (ret < 0) {
        errMsg = "av_seek_frame: " + AvErr(ret);
        return kSeekFailed;
    }
    if (s->videoCtx != nullptr) {
        // 不清解码器缓冲的话，seek 之后会先闪几帧旧画面
        avcodec_flush_buffers(s->videoCtx);
    }
    // 音频同样要清：否则 seek 后会先播出跳转前的残音
    if (s->audioCtx != nullptr) {
        avcodec_flush_buffers(s->audioCtx);
    }
    if (s->swr != nullptr) {
        // swr 内部也缓存了样本，必须一并丢弃
        swr_close(s->swr);
        swr_init(s->swr);
    }
    return kOk;
}

void Close(Session session) {
    auto *s = static_cast<DecoderSession *>(session);
    if (s == nullptr) {
        return;
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
    // 两个包各自释放：视频与音频不共用 AVPacket
    if (s->packet != nullptr) {
        av_packet_free(&s->packet);
    }
    if (s->audioPacket != nullptr) {
        av_packet_free(&s->audioPacket);
    }
    if (s->videoCtx != nullptr) {
        avcodec_free_context(&s->videoCtx);
    }
    if (s->fmtCtx != nullptr) {
        avformat_close_input(&s->fmtCtx);
    }
    delete s;
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

void Close(Session session) {
    (void)session;
}

#endif  // SOFT_PLAYER_WITH_FFMPEG

}  // namespace codecapi
}  // namespace softplayer
