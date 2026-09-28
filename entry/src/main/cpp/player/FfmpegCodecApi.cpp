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
