#ifndef SOFT_PLAYER_FFMPEG_CODEC_API_H
#define SOFT_PLAYER_FFMPEG_CODEC_API_H

#include "FfmpegTypes.h"

#include <cstdint>
#include <string>
#include <vector>

/**
 * FFmpeg 调用边界
 *
 * 为什么要把 FFmpeg 关在这一层里：
 *   FFmpeg 的头文件不能出现在任何被 NAPI 层 include 的头里 ——
 *   否则一旦 FFmpeg 尚未交叉编译好，整个原生模块就编不过，
 *   NAPI 层和状态机也就没法单独验证了。
 *
 *   所以这里只暴露「不透明句柄 + 纯 POD 参数」，
 *   libav* 的真实类型全部藏在 CodecApi.cpp 内部。
 *
 * 编译开关 SOFT_PLAYER_WITH_FFMPEG：
 *   定义时  → 调真实的 libav*（需要交叉编译好的 FFmpeg）
 *   未定义  → 所有函数返回 kNotIntegrated，上层给出清晰的错误提示
 *             框架本身（线程/队列/时钟/surface）仍可完整编译与运行
 */
namespace softplayer {
namespace codecapi {

/** 业务错误码，与 IPlayerEngine::Prepare 的返回值约定一致 */
enum : int32_t {
    kOk = 0,
    /** FFmpeg 未集成（当前默认状态） */
    kNotIntegrated = -100,
    kOpenFailed = -101,
    kNoStream = -102,
    kDecoderOpenFailed = -103,
    kDecodeFailed = -104,
    kSeekFailed = -105,
    kEof = -106,
    /** 需要更多输入数据（不是错误） */
    kAgain = -107
};

/** 媒体概况，open 成功后填充 */
struct MediaSummary {
    int64_t durationMs = 0;
    int32_t width = 0;
    int32_t height = 0;
    double frameRate = 0.0;
    std::string videoCodec;
    std::string audioCodec;
    bool hasVideo = false;
    bool hasAudio = false;
    /** 视频像素格式名，便于诊断（yuv420p / yuv422p10le ...） */
    std::string pixelFormat;
    /**
     * 画面旋转角度（0 / 90 / 180 / 270，顺时针）
     *
     * 为什么必须取出来：
     *   手机竖着拍的视频通常以横向存储，靠容器里的旋转矩阵标记"播放时该转 90 度"。
     *   系统 AVPlayer 会自动照做，但我们自己解码上屏时**必须自己转** ——
     *   否则画面是歪的（实测日志里见过 rotation_angle=90、video_orientation_type=3
     *   这类文件）。C++ 侧原先是完全没处理这个的。
     */
    int32_t rotationDeg = 0;

    /**
     * 文件里的全部音轨（按流下标升序）
     *
     * 只包含**能真正解码**的音轨：avcodec_find_decoder 找得到解码器的。
     * 找不到解码器的（例如没编进去的冷门编码）不列出来 —— 列了也切不过去，
     * 反而让用户以为可以选。
     */
    std::vector<AudioTrackInfo> audioTracks;

    /**
     * 文件里的全部字幕轨（按流下标升序）
     *
     * 包含位图字幕（supported=false），理由见 SubtitleTrackInfo。
     */
    std::vector<SubtitleTrackInfo> subtitleTracks;

    /**
     * 本次会话实际选中的音轨下标
     *
     * 为什么要在结果里回报：调用方可能请求了一条不存在的音轨，
     * 或者文件里根本没有音轨。回报真实生效的下标，界面才能正确显示
     * "当前正在用哪一条"，而不是显示用户点的那条（可能根本没生效）。
     */
    int32_t selectedAudioIndex = -1;

    /** 本次会话实际选中的字幕轨下标；-1 表示不显示字幕 */
    int32_t selectedSubtitleIndex = -1;
};

/**
 * 打开媒体时选择音轨 / 字幕轨
 *
 * 全部字段都可以用 -1（= 自动）。
 *
 * 为什么用"打开时指定"而不是"打开后切换"：
 *   切换音轨最稳妥的做法就是把解码器重建一次 —— 音频解码上下文、
 *   重采样上下文、包队列都跟具体那条流绑定，就地热替换要处理
 *   线程停顿、队列清空、解码器冲刷，出错面大得多。
 *   实测重开一次的成本也完全可以接受（打开 + 定位到原位置）。
 *   所以引擎层把"切换"实现成「Close 再用新下标 Open + Seek 回原位置」。
 */
struct TrackRequest {
    /** 期望的音频流下标；-1 = 自动（交给 av_find_best_stream 挑） */
    int32_t audioStreamIndex = -1;
    /**
     * 期望的字幕流下标；-1 = 不启用字幕
     *
     * 默认不开字幕是刻意的：现有行为是"不放字幕"，
     * 改成默认自动开会让老用户的体验突然变化。
     */
    int32_t subtitleStreamIndex = -1;
};

/**
 * 解码器会话句柄
 * 真实类型是 CodecApi.cpp 里的 Session 结构体，外面只当它是 void*
 */
using Session = void *;

/**
 * 打开媒体文件并初始化解码器
 * @param path 文件绝对路径
 * @param outSession 成功时写入会话句柄（失败时保持 nullptr）
 * @param out 成功时填充媒体概况
 * @param errMsg 失败时填充可读原因
 * @return kOk 或错误码
 */
int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg);

/**
 * 打开媒体文件并初始化解码器，同时指定音轨 / 字幕轨
 *
 * 与上面的 Open 是同一个实现，上面那个等于传一个全 -1 的 TrackRequest。
 * 之所以保留两个重载而不是加默认参数：ThumbnailExtractor 等调用方
 * 不该关心轨道选择，让它们的调用点保持原样。
 */
int32_t Open(const std::string &path, Session &outSession, MediaSummary &out,
             std::string &errMsg, const TrackRequest &tracks);

/**
 * 试着用指定的音轨 / 字幕轨打开一次，随即关闭
 *
 * 用途：给"播放中切换轨道"做**预检**。
 *   切换的实现是「关掉旧会话 → 用新轨道重开」，而这个清理过程不可逆
 *   （线程要停、会话要释放、音频设备要停）。如果重开失败就没法回滚，
 *   正在播的内容会直接挂掉。
 *   先用本函数确认"这组轨道开得起来"，再去拆旧的，失败路径就消失了。
 *
 * 本函数**不碰任何已有会话**，只是自己开一次再关，因此可以在播放中安全调用。
 *
 * @return kOk 表示这组轨道可打开；否则返回具体错误码，errMsg 说明原因
 */
int32_t ProbeTracks(const std::string &path, int32_t audioStreamIndex,
                    int32_t subtitleStreamIndex, std::string &errMsg);

/**
 * 取一条字幕事件
 *
 * 只在 TrackRequest::subtitleStreamIndex >= 0 时有内容 —— 没选字幕轨时
 * 解复用线程根本不会往字幕队列里放包，这里会立刻返回 kAgain。
 *
 * 返回的字幕是**按时间顺序**的。调用方（引擎）需要自己按当前播放位置
 * 决定显示哪一条：字幕的解码与视频解码是异步的，两者之间没有严格的
 * 一一对应关系。
 *
 * @return kOk 取到一条 / kAgain 暂时没有 / kEof 字幕流已结束 / 错误码
 *
 * 参数类型写全 softplayer:: 前缀：SubtitleEvent 定义在**外层** softplayer
 * 命名空间（FfmpegTypes.h 里，与 VideoFrame / AudioChunk 同一处），
 * 不在 codecapi 内。在 codecapi 里写裸名 SubtitleEvent 编译器找不到。
 */
int32_t ReadSubtitleEvent(Session session, softplayer::SubtitleEvent &out,
                          std::string &errMsg);

/** 本次会话是否启用了字幕轨 */
bool HasSubtitle(Session session);

/**
 * 解出一个视频帧
 *
 * 内部会连续读包直到拿到一帧（demux → decode 循环），
 * 所以一次调用可能消耗多个 packet。
 *
 * @param session 会话
 * @param frame 成功时填充（YUV420P，已拷贝）
 * @param errMsg 失败时填充原因
 * @param scaleWidth  期望输出宽度，<=0 表示按原始分辨率
 * @param scaleHeight 期望输出高度，<=0 表示按原始分辨率
 * @return kOk / kAgain（需要更多数据，调用方可重试）/ kEof / 错误码
 *
 * 为什么需要缩放：
 *   surface 分配的 buffer 是【显示区域尺寸】（例如 1084x650），不是视频尺寸。
 *   如果把 320x192 的画面按 1:1 拷进去，画面只会出现在左上角一小块 ——
 *   实测就是这样。所以解码后要缩放到 buffer 尺寸再写。
 */
int32_t DecodeVideoFrame(Session session, VideoFrame &frame, std::string &errMsg,
                         int32_t scaleWidth, int32_t scaleHeight);

/**
 * 跳到指定位置
 *
 * 实现里要同时做两件事：
 *   ① av_seek_frame 到最近的关键帧
 *   ② avcodec_flush_buffers 丢掉解码器里的旧帧
 * 漏掉 ② 会看到"seek 之后先闪几帧旧画面"的经典 bug。
 *
 * @return kOk 或错误码
 */
int32_t Seek(Session session, int64_t positionMs, std::string &errMsg);

/** 关闭会话，释放全部 FFmpeg 资源；传入 nullptr 安全 */
void Close(Session session);

/**
 * 解出一段音频 PCM
 *
 * 输出格式统一为 S16LE / 立体声 / 48kHz（见 AudioChunk 的说明）。
 * 内部会连续读包直到拿到音频帧，因此一次调用可能消耗多个 packet。
 *
 * @param session 会话
 * @param chunk 成功时填充
 * @param errMsg 失败时填充原因
 * @return kOk / kAgain（需要更多数据）/ kEof / 错误码
 */
int32_t DecodeAudioChunk(Session session, AudioChunk &chunk, std::string &errMsg);

/**
 * 音频会话是否可用（文件中确实有可解码的音频轨）
 */
bool HasAudio(Session session);

/** 音频输出采样率（固定 48000） */
int32_t AudioSampleRate();
/** 音频输出声道数（固定 2） */
int32_t AudioChannels();

/**
 * 抽一帧画面并存成 JPEG 文件（用于生成缩略图）
 *
 * 为什么自己抽帧而不是继续用系统的 AVImageGenerator：
 *   实测系统对 .rm / .wmv / .ogv 完全无能为力 ——
 *   日志里一直是 "THUMB FAIL ... 12_rv10.rm :: SYNC@500000 err=5400106"，
 *   结果这些格式在首页和搜索页永远是灰底占位，用户一眼就能看出缺陷。
 *   而 FFmpeg 本来就能解这些格式，抽一帧是顺手的事。
 *
 * 实现上直接输出 JPEG，不再走 PixelMap：
 *   原来那条路要"解码出 PixelMap → 编码成 JPEG → 再解码回来 → 存文件"，
 *   中间那次往返是为了摆脱解码器资源（PixelMap 可能依赖已释放的解码器）。
 *   既然在原生侧解码，直接用 FFmpeg 的 mjpeg 编码器写文件，
 *   既不依赖任何外部资源，也少一次编解码。
 *
 * @param srcPath 源视频绝对路径
 * @param dstPath 输出 JPEG 路径
 * @param atMs 取帧位置（毫秒）。实际会跳到该位置之前最近的关键帧再解，
 *             所以拿到的画面可能略早于 atMs —— 缩略图场景可以接受
 * @param targetW 期望宽度（会等比缩放；<=0 表示用原始宽度）
 * @param errMsg 失败时填充可读原因
 * @return kOk 或错误码
 */
int32_t ExtractFrameToJpeg(const std::string &srcPath, const std::string &dstPath,
                           int64_t atMs, int32_t targetW, std::string &errMsg);

/**
 * 注：这里曾经有一个 RemuxLoop（把短片循环拼成长片，用于 seek 压测）。
 * 已删除 —— 实测走不通：这份构建里 matroska 复用器装不了 RV10
 * （报 "Not yet implemented in FFmpeg, patches welcome"），
 * 而 FFmpeg 本身没有 rm 复用器。要做长文件 seek 压测需要一个
 * 真实的长 RMVB 样本。相关结论记在 `内置软解引擎框架说明.md`。
 */
/**
 * 取 FFmpeg 版本串，用于诊断日志
 * 未集成时返回 "not-integrated"
 */
std::string VersionString();

/** 本次编译是否真的链接了 FFmpeg */
bool IsIntegrated();

}  // namespace codecapi
}  // namespace softplayer

#endif  // SOFT_PLAYER_FFMPEG_CODEC_API_H
