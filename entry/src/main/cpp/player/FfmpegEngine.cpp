#include "FfmpegEngine.h"

#include <hilog/log.h>

#include <native_window/external_window.h>
#include <native_window/buffer_handle.h>

#include <chrono>
#include <cmath>
#include <cstring>
#include <sys/mman.h>

#undef LOG_TAG
#define LOG_TAG "SoftPlayerFfmpeg"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)
#define LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)

namespace softplayer {

namespace {

/** 取系统单调时钟毫秒，用于音视频同步 */
int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

/** 取系统单调时钟微秒，用于性能统计（解码/上屏各占多少） */
int64_t NowUs() {
    using namespace std::chrono;
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

/** 帧队列深度：8 帧 ≈ 0.13 秒 @60fps，够平滑又不会让 seek 迟滞 */
constexpr size_t kFrameQueueSize = 8;

/** 解码循环里每轮最多连续解多少帧，避免一次占满队列 */
constexpr int kMaxDecodeBurst = 4;

/**
 * 字幕缓存上限（条数）
 *
 * 取 4000 的理由：
 *   · 一条字幕平均显示 2~4 秒，4000 条约等于 2~4 小时的播放量 ——
 *     覆盖绝大多数影片，正着看/往回拖一点都够用。
 *   · 每条字幕的文本 + 两个时间戳约 100~200 字节，4000 条约 0.5 MB，
 *     在手机上是可忽略的量级。
 *   · 不设上限的话，一部带几万条字幕的长片（评论轨字幕很常见）
 *     会一直涨下去，而真正会用到的只是当前位置附近那几百条。
 */
constexpr size_t kSubtitleCacheMax = 4000;

}  // namespace

FfmpegEngine::FfmpegEngine() {
    frameQueue_ = std::make_unique<FrameQueue>(kFrameQueueSize);
    sleeper_ = std::make_unique<InterruptibleSleep>();
}

FfmpegEngine::~FfmpegEngine() {
    Release();
}

void FfmpegEngine::SetCallback(EventCallback cb) {
    callback_ = std::move(cb);
}

void FfmpegEngine::Emit(PlayerEvent type, int64_t data1, int64_t data2, const std::string &text) {
    // 回调可能在解码线程被调用，NAPI 层负责把它投递回 JS 线程
    const EventCallback &cb = callback_;
    if (cb) {
        cb(type, data1, data2, text);
    }
}

void FfmpegEngine::SetState(PlayerState st) {
    state_.store(st);
    Emit(PlayerEvent::STATE_CHANGED, static_cast<int64_t>(st), 0, "");
}

int32_t FfmpegEngine::Prepare(const std::string &path) {
    // 全 -1 = 音轨自动选、不开字幕（与加入轨道选择之前的行为一致），
    // manageAudio=true 表示这是"首次打开"，音频设备要按需创建/启动
    std::string err;
    return PrepareWithTracks(path, -1, -1, /*manageAudio=*/true, err);
}

int32_t FfmpegEngine::PrepareWithTracks(const std::string &path,
                                       int32_t audioStreamIndex,
                                       int32_t subtitleStreamIndex,
                                       bool manageAudio,
                                       std::string &outErr) {
    if (state_.load() == PlayerState::RELEASED) {
        return -1;
    }

    // ---- 验证：带新轨道能不能打开 ----
    //
    // ★ 为什么要在拆掉旧会话之前先验一遍（这是一个真实缺陷的修法）
    //
    //   本函数的清理阶段是**不可逆**的：它会停掉三条线程、关掉旧会话、
    //   并且为了让音频线程能安全 join 而 Stop 掉音频设备。
    //   如果在那之后再 codecapi::Open 失败（文件被删/被占用、U 盘被拔出、
    //   指定流下标在当前文件里不存在……），就**没有任何东西可以回滚**：
    //   旧会话已经没了、音频设备停了，引擎直接卡在 ERROR_STATE，
    //   用户只能退出重进。
    //
    //   而"切换音轨/字幕"本该是**非破坏性**操作 —— 切不过去，
    //   就应该老老实实保持原样继续播，而不是把正在播的东西弄没。
    //
    //   所以这里先用同一组参数做一次"试打开"：确认能开，再走不可逆的清理。
    //
    // ★★ 2026-09-29 自检修正：上面这段预检上一版有两个错，导致
    //    **软解路径首次播放必然失败**（真机复现：点开 SubCover_vp9.mkv
    //    直接显示"软解失败：prepare 返回错误码 -101"）。
    //
    //    错误一：预检传的是成员 path_，而不是传进来的 path。
    //      而 path_ 是在下面清理阶段末尾（"path_ = path;"）才赋值的 ——
    //      也就是说**首次打开时它还是空的**：
    //        avformat_open_input("") -> "No such file or directory"
    //        -> 预检返回失败 -> 整个 Prepare 带着这个错误码退出，
    //        真实的 Open 根本没机会执行。
    //      顺带一提，换成第二个文件时 path_ 还是"上一个文件"：
    //      旧文件若已删除，新文件也会被同一个错拦住。
    //
    //    错误二：**本来就没有会话时也做预检**。
    //      预检的全部意义是"别把正在播的旧会话拆掉、结果又开不起来"。
    //      首次打开 / 换文件时若 session_ 为空，没有任何东西需要保护，
    //      预检纯属白跑一趟（多一次 open+close），还要承担上面那个错。
    //
    //    现在的规则：**有会话才预检，且预检的是即将打开的那个 path。**
    //      · 换音轨 / 换字幕：path 与当前文件相同 -> 正是要保护的场景
    //      · 换文件：path 是新文件 -> 提前验证新文件可开
    //      · 首次打开：session_ 为空 -> 跳过，直接走正常流程
    if (session_ != nullptr) {
        std::string probeErr;
        const int32_t probe = codecapi::ProbeTracks(path, audioStreamIndex,
                                                     subtitleStreamIndex, probeErr);
        if (probe != codecapi::kOk) {
            const std::string reason = "换轨被拒绝（新轨道无法打开）：" + probeErr;
            LOGW("%{public}s", reason.c_str());
            outErr = reason;
            // 注意：这里**什么都不动** —— 旧会话、线程、音频设备全部保持原状，
            // 调用方可以直接告诉用户"这条轨道切不过去"，播放继续
            return probe;
        }
        LOGI("换轨预检通过（音轨=%{public}d 字幕=%{public}d），开始切换",
             audioStreamIndex, subtitleStreamIndex);
    }

    // ==================== 清理顺序（这里有一个必须讲清的坑） ====================
    //
    // ★★ 先停线程，再关会话 —— 顺序反了必然崩溃（真机 SIGABRT 实测）★★
    //
    //   第一版写成了「先 codecapi::Close(session_)，再 join 音频/字幕线程」，
    //   逻辑上看着没错（都是清理），实际是**释放后使用**：
    //     音频线程当时可能正卡在 DecodeAudioChunk(session_, ...) 里，
    //     字幕线程可能正卡在 ReadSubtitleEvent(session_, ...) 里，
    //     而 session_ 指向的 DecoderSession 已经被 Close 里的 delete 释放了。
    //   → 解引用已释放内存 → SIGABRT / SIGSEGV。
    //
    //   为什么原来的 Prepare 没暴露这个问题：
    //     它只在"换文件"时被调用，而那时播放是停的、线程早就退出了，
    //     所以"先关会话"恰好是安全的 —— 属于**侥幸正确**。
    //     一旦新增"播放中换音轨/换字幕"（本函数的新调用方），
    //     线程是活的，侥幸立刻变成崩溃。
    //
    //   正确顺序：置退出标志 → join 全部线程 → 再关会话。
    //   注意 quitting_ 一旦置位，后续 Start() 会重新置 false（见 Start），
    //   所以不需要在这里恢复。
    quitting_.store(true);
    if (sleeper_ != nullptr) {
        sleeper_->Wake();
    }
    // 解码线程先停：它持有 frameQueue_，且会往 surface 写帧
    if (threadStarted_) {
        if (frameQueue_ != nullptr) {
            frameQueue_->Abort();
        }
        if (decodeThread_.joinable()) {
            decodeThread_.join();
        }
        threadStarted_ = false;
        // 队列被 Abort 过，换一个新的，否则后续 Pop 永远返回 false
        frameQueue_ = std::make_unique<FrameQueue>(kFrameQueueSize);
    }
    // ★ 先停音频输出，再 join 音频线程。
    //   反过来的话，音频线程可能正卡在 Write（缓冲满在等），
    //   而音频回调已经停了、缓冲永远不消耗 —— 就死锁了。
    //
    //   manageAudio == false（换轨路径）时这里也不是白停：
    //   音频设备必须停下来，线程才可能从阻塞的 Write 里出来。
    //   代价是设备被 Stop 之后需要重启（见下方音频准备处的分支）。
    //   那点重启延迟是主动接受的 —— **正确性优先**；
    //   想省掉它就会变成"边写边 join"，反而引入新的竞态。
    if (audio_ != nullptr) {
        audio_->Stop();
    }
    if (audioThreadStarted_ && audioThread_.joinable()) {
        audioThread_.join();
    }
    audioThreadStarted_ = false;
    // 字幕线程同样要在关会话之前 join
    if (subtitleThreadStarted_ && subtitleThread_.joinable()) {
        subtitleThread_.join();
    }
    subtitleThreadStarted_ = false;

    // ---- 线程全部停下之后，才可以安全关闭会话 ----
    if (session_ != nullptr) {
        codecapi::Close(session_);
        session_ = nullptr;
    }

    // 清掉上一轮的字幕缓存。
    //
    // ★ 注意这里与 SeekTo 的区别：**换文件/换字幕轨时要清，单纯的 seek 不能清。**
    //   · 换文件：旧文件的行星字幕对新文件毫无意义 → 清
    //   · 换字幕轨：旧轨的文本不该混进新轨 → 清
    //   · 单纯 seek：缓存里的旧条目无害（查询是按当前播放位置匹配的），
    //     而清掉会丢掉"已经解析好、但新位置之后不会再读到"的长字幕
    //     —— 那条字幕会从此永远不显示。详见 FfmpegCodecApi.cpp 里
    //     SeekInternal 的说明。
    {
        std::lock_guard<std::mutex> lk(subtitleMutex_);
        subtitleCues_.clear();
    }
    subtitleCachedCount_.store(0);
    subtitleDecodedUntilMs_.store(0);
    LOGI("换轨/换文件：已清空字幕缓存");

    audioReady_ = false;
    audioEof_.store(false);
    audioWrittenMs_.store(0);

    path_ = path;
    SetState(PlayerState::PREPARING);

    // 没集成 FFmpeg 时，这里给出明确原因而不是一个笼统的失败码，
    // 这样上层能直接提示"需要内置软解"，而不是让用户面对黑屏
    if (!codecapi::IsIntegrated()) {
        const std::string reason =
            "内置软解未集成（FFmpeg " + codecapi::VersionString() + "）："
            "该格式系统解码器不支持，需要编译 FFmpeg 后才能播放";
        LOGE("Prepare 失败: %{public}s", reason.c_str());
        Emit(PlayerEvent::ERROR, codecapi::kNotIntegrated, 0, reason);
        SetState(PlayerState::ERROR_STATE);
        return codecapi::kNotIntegrated;
    }

    codecapi::MediaSummary summary;
    std::string errMsg;
    codecapi::Session newSession = nullptr;
    codecapi::TrackRequest req;
    req.audioStreamIndex = audioStreamIndex;
    req.subtitleStreamIndex = subtitleStreamIndex;
    const int32_t ret = codecapi::Open(path_, newSession, summary, errMsg, req);
    if (ret != codecapi::kOk) {
        const std::string reason = "打开失败(" + std::to_string(ret) + "): " + errMsg;
        LOGE("Prepare 失败: %{public}s", reason.c_str());
        Emit(PlayerEvent::ERROR, ret, 0, reason);
        SetState(PlayerState::ERROR_STATE);
        return ret;
    }
    session_ = newSession;

    // ---- 音频准备 ----
    // 音频初始化失败不视为致命错误：静音播视频也比整个文件打不开好
    audioReady_ = codecapi::HasAudio(session_);
    if (audioReady_) {
        if (audio_ == nullptr) {
            audio_ = std::make_unique<AudioOutput>();
        }
        if (manageAudio) {
            if (audio_->Start(codecapi::AudioSampleRate(), codecapi::AudioChannels())) {
                LOGI("音频输出就绪");
            } else {
                LOGW("音频输出启动失败，本次播放将静音");
                audioReady_ = false;
            }
        } else if (audio_->IsRunning()) {
            // 换轨路径，但设备居然还在跑（理论上不该发生：清理阶段已经 Stop 过）。
            // 保留这条分支是为了"设备复用"这个优化将来重新启用时不用再想一遍；
            // 现在它几乎不会命中。
            LOGI("换音轨：沿用已有音频输出设备");
            audio_->FlushBuffer();
        } else {
            // 换轨路径的常态：清理阶段为了安全 join 线程而 Stop 过设备，
            // 这里把它重新启动（会有几百毫秒延迟，见清理阶段的说明）
            if (audio_->Start(codecapi::AudioSampleRate(), codecapi::AudioChannels())) {
                LOGI("换音轨：音频输出已重启");
            } else {
                LOGW("换音轨：音频输出重启失败，本次播放将静音");
                audioReady_ = false;
            }
        }
    } else {
        LOGI("该文件没有可解码的音频轨，静音播放");
    }

    // 填 MediaInfo 给上层
    info_.durationMs = summary.durationMs;
    info_.width = summary.width;
    info_.height = summary.height;
    info_.frameRate = summary.frameRate;
    info_.videoCodec = summary.videoCodec;
    info_.audioCodec = summary.audioCodec;
    info_.hasVideo = summary.hasVideo;
    info_.hasAudio = summary.hasAudio;
    info_.rotationDeg = summary.rotationDeg;
    // ---- 轨道信息（供界面做选择）----
    info_.audioTracks = summary.audioTracks;
    info_.subtitleTracks = summary.subtitleTracks;
    info_.currentAudioIndex = summary.selectedAudioIndex;
    info_.currentSubtitleIndex = summary.selectedSubtitleIndex;
    subtitleEnabled_.store(summary.selectedSubtitleIndex >= 0);
    LOGI("轨道枚举: 音轨 %{public}zu 条（当前 %{public}d）, "
         "字幕轨 %{public}zu 条（当前 %{public}d）",
         info_.audioTracks.size(), info_.currentAudioIndex,
         info_.subtitleTracks.size(), info_.currentSubtitleIndex);

    positionMs_.store(0);
    pendingSeekMs_.store(-1);
    lastFramePtsMs_ = -1;
    lastFrameSysMs_ = 0;

    Emit(PlayerEvent::DURATION, info_.durationMs, 0, "");
    // VIDEO_SIZE 的 data2 借用来带旋转角度：上层需要知道该不该把宽高互换来计算
    // 画面比例（竖拍视频存储是 1920x1080、实际观看是 1080x1920，差一个屏幕方向）
    Emit(PlayerEvent::VIDEO_SIZE, info_.width,
         info_.height | (static_cast<int64_t>(info_.rotationDeg) << 32), "");
    Emit(PlayerEvent::PREPARED, 0, 0, "");
    SetState(PlayerState::READY);
    LOGI("Prepare 成功: %{public}s %{public}s/%{public}s %{public}dx%{public}d 旋转%{public}d度",
         path_.c_str(), info_.videoCodec.c_str(), info_.audioCodec.c_str(),
         info_.width, info_.height, info_.rotationDeg);

    // ★★ 2026-10-03：视频解码线程提前到 Prepare 启动（原来在 Start 里）★★
    //
    //   为什么必须提前：上层改成了"先等首帧上屏，再开始播"（避免先响声音、
    //   画面还黑着），而首帧是**解码线程**渲染的 —— 如果解码线程要等 play()
    //   才起来，就会变成
    //     「等首帧 → 才 play → 才有解码线程 → 才有首帧」
    //   互相等，只能靠上层 8 秒兜底超时打破。真机实测就是这个现象：
    //     native window 就绪 16:01:47.48
    //     （整整 8.0 秒空档 = 兜底超时）
    //     解码线程启动      16:01:55.52
    //     已上屏 1 帧       16:01:55.82
    //   提前启动之后，READY 时就能预渲染出一帧，上层立刻收到信号开始播，
    //   起播只花解码这一帧的时间。
    //
    //   代价：准备阶段解码线程会先把帧队列填满（最多 kFrameQueueSize 帧）然后
    //   停在"未播放"的等待里 —— 这点解码量换来的是"点开即出画面"，
    //   而且它本来在 play() 之后也要做同样的工作。
    //   音频线程**不提前**：音频设备虽然在 Prepare 就开着（环形缓冲是空的、
    //   没有声音），但音频解码线程仍在 Start 里启动，声音因此不会抢在画面之前。
    if (!threadStarted_ && info_.hasVideo) {
        quitting_.store(false);
        lastFramePtsMs_ = -1;
        lastFrameSysMs_ = 0;
        // ★ 2026-10-03：如果上层在 Prepare 之前给了起播位置（续播），
        //   在这里把它转成一次内部 seek —— 解码线程一启动就会处理它
        //   （见 DecodeLoop ①），于是"预渲染的第一帧"就是续播位置那一帧。
        //   为什么不能等上层 READY 之后再 seek：那时候预渲染早就把
        //   "文件开头"那帧渲染出去了，上层据此判断"画面已就绪"会出错，
        //   实测只能靠上层 8 秒兜底超时才能开播。
        const int64_t startMs = startPositionMs_.load();
        if (startMs > 0) {
            pendingSeekMs_.store(startMs);
            LOGI("起播位置 %{public}lld ms（解码线程启动后立即执行内部 seek）",
                 static_cast<long long>(startMs));
        }
        // 顺序同下面 Start() 里的说明：先置标志再构造线程，否则清理路径
        // 可能跳过 join，导致线程持有已释放的会话（真机 SIGABRT）
        threadStarted_ = true;
        decodeThread_ = std::thread(&FfmpegEngine::DecodeLoop, this);
        LOGI("解码线程已启动（Prepare 阶段，用于预渲染首帧）");
    } else if (!threadStarted_ && !info_.hasVideo) {
        LOGI("该文件没有视频轨，不启动视频解码线程（仅音频播放）");
    }
    return 0;
}

int32_t FfmpegEngine::Start() {
    if (state_.load() == PlayerState::RELEASED || session_ == nullptr) {
        return -1;
    }

    if (!threadStarted_ && info_.hasVideo) {
        quitting_.store(false);
        // 从 READY 起步时，时钟基准必须重置，
        // 否则首帧会按一个陈旧的 lastFrameSysMs_ 去算等待，导致开头卡住
        lastFramePtsMs_ = -1;
        lastFrameSysMs_ = 0;
        // ★ 先置标志、再构造线程 —— 顺序不能反（踩过一次真机 SIGABRT）
        //
        //   原来写的是「构造线程 → threadStarted_ = true」。
        //   如果线程在标志被置位之前就跑到退出分支（快速失败/瞬间 EOF），
        //   而此刻 PrepareWithTracks 正好在跑（播放中换轨/换字幕），
        //   就会出现：
        //     · PrepareWithTracks 看到 threadStarted_ == false → **跳过 join**
        //     · 随后 codecapi::Close(session_) 释放会话
        //     · 那条"没人 join"的线程仍持有 session_ 并继续解引用 → 崩溃
        //   置位提前之后，清理路径永远能看到它并 join。
        threadStarted_ = true;
        decodeThread_ = std::thread(&FfmpegEngine::DecodeLoop, this);
    } else if (!threadStarted_ && !info_.hasVideo) {
        // ★ 纯音频文件（没有视频轨）不能启动视频解码线程。
        //
        //   实测踩到：5.1 的 .dts 音频文件走软解通道后，
        //   DecodeLoop 因为拿不到 videoCtx 立刻返回
        //   "会话无效或没有视频流" 并把状态置为 ERROR_STATE，
        //   于是整个播放（包括本来正常的音频）一起失败 ——
        //   日志表现为「解码失败(-104) → 音频线程也退出」。
        //
        //   上面的音频线程本来就是条件启动的（audioReady_），
        //   视频这边之前漏了同样的判断。纯音频走软解时只需要音频线程。
        LOGI("该文件没有视频轨，不启动视频解码线程（仅音频播放）");
    }

    // ★ 看门狗起搏：开始播放时就算"刚出过帧"，这样即使一帧都还没解出来，
    //   kStallDetectMs 之后也能被检测到（见 DecodeLoop ①.5）
    lastDecodeOkMs_ = NowMs();
    stallRecoverCount_ = 0;

    // 音频输出：启动失败不算致命（有些设备/权限下拿不到音频流），
    // 静音继续播视频比整个播放失败更合理
    if (audioReady_ && audio_ != nullptr && !audioThreadStarted_) {
        // ★ 音频流在 Prepare 里已经 Start 过了（因为 Create 出来就是 running 态），
        //   这里绝不能再调一次 Resume —— 那会报 "恢复音频失败: 2"
        //   （操作不允许：流已经在 running）。所以只在"确实处于暂停态"时才恢复。
        if (audio_->IsPaused()) {
            audio_->Resume();
        }
        audioEof_.store(false);
        // 先置标志再构造，理由同上面视频线程那段（防"没人 join"）
        audioThreadStarted_ = true;
        audioThread_ = std::thread(&FfmpegEngine::AudioLoop, this);
        LOGI("音频线程已启动");
    }

    // 字幕线程：只在启用了字幕轨时启动。
    // 与视频线程不同的地方：字幕线程**不依赖 playing_**，暂停时也继续把
    // 字幕读进来 —— 这样暂停状态下往回拖进度条，字幕能立刻显示，
    // 不用等恢复播放。字幕解析很轻，暂停期间继续读没有负担。
    if (subtitleEnabled_.load() && session_ != nullptr && !subtitleThreadStarted_) {
        // ★ 同样是先置标志再构造。
        //   这条线程尤其危险：它立刻就会调 ReadSubtitleEvent(session_,...)，
        //   而"播放中启用字幕"这条路径紧接着就会重开会话并 Close(session_)。
        //   一旦标志晚了，PrepareWithTracks 跳过 join，Close 就把正在被
        //   这条线程使用的会话释放掉 —— 这正是真机上实测到的 SIGABRT。
        subtitleThreadStarted_ = true;
        subtitleThread_ = std::thread(&FfmpegEngine::SubtitleLoop, this);
        LOGI("字幕线程已启动");
    }

    playing_.store(true);
    sleeper_->Wake();
    SetState(PlayerState::PLAYING);
    return 0;
}

int32_t FfmpegEngine::Pause() {
    if (state_.load() == PlayerState::RELEASED) {
        return -1;
    }
    playing_.store(false);
    // 音频要一起暂停：只停视频不停音频，暂停期间声音还在放，
    // 而且音频时钟会继续走，恢复播放时画面会突然跳一大段
    if (audio_ != nullptr && audio_->IsRunning()) {
        audio_->Pause();
    }
    // 必须打断睡眠：否则主循环可能正睡在一帧的等待里，
    // 要等它睡完才看到暂停标志，用户感受就是"点了暂停还在播"
    sleeper_->Wake();
    SetState(PlayerState::PAUSED);
    return 0;
}

void FfmpegEngine::SetStartPositionMs(int64_t positionMs) {
    // 只在 Prepare 之前有意义：Prepare 会把它转成一次内部 seek（见那里的说明）。
    startPositionMs_.store(positionMs < 0 ? -1 : positionMs);
}

/**
 * 清空帧队列，并把每帧的缓冲**还回解码器的缓冲池**
 *
 * 为什么不能直接用 FrameQueue::Clear()：
 *   它只把长度清零，帧结构体里那块 3.7MB 的 RGBA 缓冲就此失联 ——
 *   池子（上限 8 块）被抽干后，每一帧都要现场 malloc + 清零 3.7MB，
 *   真机实测单帧转换耗时从 ~12ms 涨到 ~93ms（其中分配 80ms），
 *   表现就是"拖几次进度条之后越来越卡"。
 *
 * 只在解码线程里调用（seek 处理段）：那里是队列唯一的消费者，
 * 不会有别的线程同时在 Pop。
 */
void FfmpegEngine::DrainFrameQueueRecycling() {
    if (frameQueue_ == nullptr || session_ == nullptr) {
        return;
    }
    VideoFrame stale;
    int32_t recycled = 0;
    // waitMs=0：只是把队列里现有的帧取干净，绝不等待
    while (frameQueue_->Pop(stale, 0)) {
        codecapi::RecycleFrameBuffer(session_, stale);
        recycled++;
    }
    if (recycled > 0) {
        LOGI("seek 清队列：已回收 %{public}d 帧缓冲（避免抽干缓冲池）", recycled);
    }
    frameQueue_->Clear();
}

/* ============================================================
   色调调整（画面）
   ============================================================ */

void FfmpegEngine::SetColorAdjust(int32_t brightness, int32_t contrast, int32_t saturation,
                                  int32_t hue, int32_t rGain, int32_t gGain, int32_t bGain) {
    auto clampPercent = [](int32_t v) { return v < -100 ? -100 : (v > 100 ? 100 : v); };
    colBrightness_.store(clampPercent(brightness));
    colContrast_.store(clampPercent(contrast));
    colSaturation_.store(clampPercent(saturation));
    colHue_.store(clampPercent(hue));
    colRGain_.store(clampPercent(rGain));
    colGGain_.store(clampPercent(gGain));
    colBGain_.store(clampPercent(bGain));
    // 只改版本号：真正的矩阵合并在渲染线程做（见 RebuildColorMatrix 的说明）
    colRev_.fetch_add(1);
}

/**
 * 把七个参数合成一个 3x3 矩阵 + 3 个常数偏移
 *
 * 运算顺序（与常见播放器一致，从"像素本身"到"观感"）：
 *   ① 对比度 + 亮度：v1 = (v - 128) * c + 128 + B
 *   ② 通道增益：      v2 = v1 * g_c
 *   ③ 饱和度：        v3 = L + s * (v2 - L)，L = 0.299R + 0.587G + 0.114B（灰度）
 *   ④ 色彩度（色相旋转）：v4 = H * v3
 * ①②③ 全是线性映射，④ 是线性矩阵，所以整体就是
 *   out = M * in + O      （M 由 c、g、s、H 依次相乘得到，O 是 B 经过①之后的偏移再被②③④搬运）
 * 这正是每像素只做 9 次乘加的前提。
 *
 * 定点：所有系数乘 65536 存 int32（16.16），像素运算在 int32 里做，
 * 最后右移 16 位并夹到 0~255 —— 精度足够（误差 < 1/256），比浮点快得多。
 */
void FfmpegEngine::RebuildColorMatrix() {
    const double bri = colBrightness_.load() / 100.0;
    const double con = 1.0 + colContrast_.load() / 100.0;
    const double sat = 1.0 + colSaturation_.load() / 100.0;
    const double hueDeg = colHue_.load() / 100.0 * 180.0;
    const double gr = 1.0 + colRGain_.load() / 100.0;
    const double gg = 1.0 + colGGain_.load() / 100.0;
    const double gb = 1.0 + colBGain_.load() / 100.0;

    const bool isIdentity = (colBrightness_.load() == 0 && colContrast_.load() == 0
                             && colSaturation_.load() == 0 && colHue_.load() == 0
                             && colRGain_.load() == 0 && colGGain_.load() == 0
                             && colBGain_.load() == 0);
    if (isIdentity) {
        // 恒等：显式写回单位矩阵，渲染时走原来的 memcpy 快路
        const int32_t identity[9] = {65536, 0, 0, 0, 65536, 0, 0, 0, 65536};
        for (int i = 0; i < 9; i++) {
            colM_[i] = identity[i];
        }
        colO_[0] = colO_[1] = colO_[2] = 0;
        colIdentity_ = true;
        return;
    }

    // ---- ① + ②：对比度/亮度 → 通道增益 ----
    // 亮度偏移量：±100% 对应 ±128（0~255 量程的一半），这是实测"全黑/全白"的边界，
    // 再大就只剩纯色块，没有可用性。
    const double brightOffset = bri * 128.0;
    const double gain[3] = {gr, gg, gb};
    double m[9] = {0};
    double off[3] = {0};
    for (int c = 0; c < 3; c++) {
        // v2 = ((v - 128) * con + 128 + brightOffset) * gain[c]
        m[c * 3 + c] = con * gain[c];
        off[c] = ((128.0 - 128.0 * con) + brightOffset) * gain[c];
    }

    // ---- ③ 饱和度：把每个通道朝灰度靠或推远 ----
    const double lw[3] = {0.299, 0.587, 0.114};
    double sm[9];
    for (int c = 0; c < 3; c++) {
        for (int k = 0; k < 3; k++) {
            sm[c * 3 + k] = (c == k ? sat : 0.0) + (1.0 - sat) * lw[k];
        }
    }

    // ---- ④ 色彩度：色相旋转矩阵（在亮度/色度空间里旋转色度分量）----
    const double rad = hueDeg * 3.14159265358979323846 / 180.0;
    const double hc = std::cos(rad);
    const double hs = std::sin(rad);
    const double hm[9] = {
        0.213 + 0.787 * hc - 0.213 * hs, 0.715 - 0.715 * hc - 0.715 * hs, 0.072 - 0.072 * hc + 0.928 * hs,
        0.213 - 0.213 * hc + 0.143 * hs, 0.715 + 0.285 * hc + 0.140 * hs, 0.072 - 0.072 * hc - 0.283 * hs,
        0.213 - 0.213 * hc - 0.787 * hs, 0.715 - 0.715 * hc + 0.715 * hs, 0.072 + 0.928 * hc + 0.072 * hs
    };

    // M = H * S * (① ② 的对角阵)
    double t1[9];   // S * diag
    for (int c = 0; c < 3; c++) {
        for (int k = 0; k < 3; k++) {
            t1[c * 3 + k] = sm[c * 3 + k] * m[k * 3 + k];
        }
    }
    for (int c = 0; c < 3; c++) {
        for (int k = 0; k < 3; k++) {
            double acc = 0.0;
            for (int j = 0; j < 3; j++) {
                acc += hm[c * 3 + j] * t1[j * 3 + k];
            }
            m[c * 3 + k] = acc;
        }
    }
    // 偏移：① ② 的偏移 → ③ → ④（逐级搬运，都是 3x3 乘 3 向量）
    double off12[3];
    for (int c = 0; c < 3; c++) {
        off12[c] = ((128.0 - 128.0 * con) + brightOffset) * gain[c];
    }
    double offS[3];
    for (int c = 0; c < 3; c++) {
        double acc = 0.0;
        for (int k = 0; k < 3; k++) {
            acc += sm[c * 3 + k] * off12[k];
        }
        offS[c] = acc;
    }
    double offH[3];
    for (int c = 0; c < 3; c++) {
        double acc = 0.0;
        for (int k = 0; k < 3; k++) {
            acc += hm[c * 3 + k] * offS[k];
        }
        offH[c] = acc;
    }

    for (int i = 0; i < 9; i++) {
        // +0.5 / -0.5 是为了四舍五入而不是截断（截断会让整体偏暗一点点）
        const double v = m[i] * 65536.0;
        colM_[i] = static_cast<int32_t>(v >= 0 ? v + 0.5 : v - 0.5);
    }
    for (int c = 0; c < 3; c++) {
        const double v = offH[c] * 65536.0;
        colO_[c] = static_cast<int32_t>(v >= 0 ? v + 0.5 : v - 0.5);
    }
    colIdentity_ = false;
}

void FfmpegEngine::RefreshColorMatrixIfNeeded() {
    const int32_t rev = colRev_.load();
    if (rev == colSeenRev_) {
        return;
    }
    colSeenRev_ = rev;
    RebuildColorMatrix();
}

/* ============================================================
   均衡器（声音）
   ============================================================ */

void FfmpegEngine::SetAudioEq(bool enabled, const int32_t *gainsDb, int32_t count) {
    if (gainsDb != nullptr) {
        for (int32_t i = 0; i < 10; i++) {
            const int32_t v = (i < count) ? gainsDb[i] : 0;
            eqGainDb_[i].store(v < -12 ? -12 : (v > 12 ? 12 : v));
        }
    }
    eqEnabled_.store(enabled);
    eqRev_.fetch_add(1);
}

/**
 * 按当前各段增益重建双二阶系数
 *
 * 用 RBJ cookbook 的 peaking EQ：
 *   A = 10^(gain/40)，w0 = 2πf/fs，alpha = sin(w0)/(2Q)
 *   b0 = 1 + alpha*A, b1 = -2cos(w0), b2 = 1 - alpha*A
 *   a0 = 1 + alpha/A, a1 = -2cos(w0), a2 = 1 - alpha/A
 * 全部除以 a0 归一化，之后每样本 5 次乘加。
 *
 * Q 取 1.0：这个 .rmvb 的音频是 44.1kHz 的 cook，10 段要覆盖 60Hz~16kHz，
 * Q 太大各段会互相"打洞"（听感是忽大忽小声），Q 太小又变成整体音量变化。
 * 1.0 是听感上最接近"图形均衡器"的取值。
 *
 * 只在音频线程里调用：滤波器状态（eqX1_ 等）也只有音频线程读写。
 */
void FfmpegEngine::RebuildEqCoeffs() {
    // 采样率以输出设备为准（AudioOutput 固定 48kHz 立体声 S16）
    const double fs = static_cast<double>(codecapi::AudioSampleRate());
    const double freqs[10] = {60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000};
    const double q = 1.0;
    int32_t active = 0;
    for (int b = 0; b < 10; b++) {
        const double gainDb = static_cast<double>(eqGainDb_[b].load());
        if (gainDb > -0.4 && gainDb < 0.4) {
            // 平坦段：写成直通（b0=1，其余 0），省下乘加也避免数值噪声
            eqB0_[b] = 1.0; eqB1_[b] = 0.0; eqB2_[b] = 0.0;
            eqA1_[b] = 0.0; eqA2_[b] = 0.0;
            continue;
        }
        active++;
        const double a = std::pow(10.0, gainDb / 40.0);
        const double w0 = 2.0 * 3.14159265358979323846 * freqs[b] / fs;
        const double cosW = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        const double a0 = 1.0 + alpha / a;
        eqB0_[b] = (1.0 + alpha * a) / a0;
        eqB1_[b] = (-2.0 * cosW) / a0;
        eqB2_[b] = (1.0 - alpha * a) / a0;
        eqA1_[b] = (-2.0 * cosW) / a0;
        eqA2_[b] = (1.0 - alpha / a) / a0;
    }
    eqActiveBands_ = active;
    for (int i = 0; i < 20; i++) {
        eqX1_[i] = 0.0; eqX2_[i] = 0.0; eqY1_[i] = 0.0; eqY2_[i] = 0.0;
    }
    // 把曲线本身也打出来：只报"几段非平坦"在排查时不够用 ——
    // 曾经出现过"日志说 0 段、但界面曲线明显不平"的疑点，
    // 有这 10 个数就能一眼看出是"上层没传下来"还是"系数算错了"。
    LOGI("均衡器系数已更新：%{public}d 段非平坦 | 曲线=%{public}d,%{public}d,%{public}d,%{public}d,"
         "%{public}d,%{public}d,%{public}d,%{public}d,%{public}d,%{public}d",
         active, eqGainDb_[0].load(), eqGainDb_[1].load(), eqGainDb_[2].load(),
         eqGainDb_[3].load(), eqGainDb_[4].load(), eqGainDb_[5].load(),
         eqGainDb_[6].load(), eqGainDb_[7].load(), eqGainDb_[8].load(),
         eqGainDb_[9].load());
}

/**
 * 对一块 S16 立体声数据做 10 段均衡（就地修改）
 *
 * 为什么在"写设备之前"做：这里是音频通路的最后一道，
 * 数据已经解码成 S16 交错立体声、音量和节奏都不再变化，
 * 在这里改样本不会影响解码时间戳与音画同步。
 */
void FfmpegEngine::ApplyAudioEq(std::vector<uint8_t> &data) {
    if (data.size() < 4) {
        return;
    }
    // ★ 总开关必须在这里判断 ★
    //   2026-10-04 自查发现：注释里写着"关闭时零开销"，代码却只判断了
    //   "全部增益是否为 0"，于是**开关关掉之后曲线依然在生效**
    //   （用户关了均衡器却还能听出音染，只会以为开关坏了）。
    //   直接返回、连系数都不重建：打开时版本号必然已变，
    //   下一次进来会重建，不会用到过期系数。
    if (!eqEnabled_.load()) {
        return;
    }
    // 参数变了就重建系数（同样只在音频线程里做，不需要锁）
    const int32_t rev = eqRev_.load();
    if (rev != eqSeenRev_) {
        eqSeenRev_ = rev;
        RebuildEqCoeffs();
    }
    if (eqActiveBands_ == 0) {
        return;   // 全平坦：一个样本都不碰
    }
    int16_t *s = reinterpret_cast<int16_t *>(data.data());
    const size_t frames = data.size() / 4;   // 2 声道 * 2 字节
    for (size_t i = 0; i < frames; i++) {
        for (int ch = 0; ch < 2; ch++) {
            double x = static_cast<double>(s[i * 2 + static_cast<size_t>(ch)]);
            for (int b = 0; b < 10; b++) {
                const int idx = ch * 10 + b;
                const double y = eqB0_[b] * x + eqB1_[b] * eqX1_[idx] + eqB2_[b] * eqX2_[idx]
                                 - eqA1_[b] * eqY1_[idx] - eqA2_[b] * eqY2_[idx];
                eqX2_[idx] = eqX1_[idx];
                eqX1_[idx] = x;
                eqY2_[idx] = eqY1_[idx];
                eqY1_[idx] = y;
                x = y;
            }
            int32_t v = static_cast<int32_t>(x + (x >= 0 ? 0.5 : -0.5));
            if (v < -32768) {
                v = -32768;
            } else if (v > 32767) {
                v = 32767;
            }
            s[i * 2 + static_cast<size_t>(ch)] = static_cast<int16_t>(v);
        }
    }
}

int32_t FfmpegEngine::SeekTo(int64_t positionMs) {
    if (state_.load() == PlayerState::RELEASED || session_ == nullptr) {
        return -1;
    }
    if (positionMs < 0) {
        positionMs = 0;
    }
    pendingSeekMs_.store(positionMs);
    // seek 要清掉排队的旧帧，否则会先闪几帧旧画面。
    //
    // ★ 2026-10-04：这里**不再直接 frameQueue_->Clear()** ——
    //   本函数是在 UI 线程上调用的，而 Clear() 只清长度、不回收缓冲，
    //   会把队列里那几块 3.7MB 缓冲丢掉（池子上限只有 8 块，抽干后每帧
    //   都要现场分配 3.7MB：实测 80ms/帧）。解码线程在处理 pendingSeekMs_
    //   时会走 DrainFrameQueueRecycling()，既清队列又把缓冲还回池子，
    //   时间差只有几十毫秒（解码循环每轮都会检查），闪旧帧的问题依旧成立。
    // ★ 2026-10-03：seek 世代号**刻意不在这里递增**，而是在解码线程真正把
    //   seek 交给解码器的那一刻（见 DecodeLoop 的 seek 处理段）。
    //
    //   为什么位置这么讲究（真机踩过两轮）：
    //     本轮的目标是"先出画面再出声"：上层发起续播 seek 之后等引擎报
    //     "这个位置的第一帧已上屏"。如果世代号在**请求** seek 时就加，
    //     预渲染会立刻放行，而此刻解码器还没收到 seek（包队列里还有旧包）
    //     → 渲染出来的是 **seek 之前**那一帧（实测就是文件开头那帧），
    //     位置对不上、上层只能用兜底超时开播。
    //     改成"解码器真正收到 seek 之后再算新一代"，
    //     预渲染出来的一定是新位置的第一帧。
    // 音频缓冲也要清：不清的话 seek 之后会先播出跳转前的残音
    if (audio_ != nullptr) {
        audio_->FlushBuffer();
    }
    // 音频时钟基准同步到 seek 目标，否则画面会等一个"已经过去很久"的时钟
    // 注意：这里刻意清零而不是设成 seek 目标。
    //   音频时钟的绝对基准（audioWrittenMs_）在 seek 后由音频线程重新累积，
    //   而 pts 是绝对时间戳 —— 两者相减会产生一个与 seek 目标等量的偏移，
    //   表现就是 seek 后画面要等一段才动。清零让基准从当前位置重新起算，
    //   视频按相对进度对齐，不会有跳变。
    audioWrittenMs_.store(0);
    audioEof_.store(false);
    // 时钟基准作废，下次出帧重新对齐，避免 seek 后要么狂追要么卡住
    lastFramePtsMs_ = -1;
    lastFrameSysMs_ = 0;
    sleeper_->Wake();
    return 0;
}

int32_t FfmpegEngine::SetSurface(const std::string &surfaceId) {
    std::lock_guard<std::mutex> lock(surfaceMutex_);
    if (surfaceId_ == surfaceId && nativeWindow_ != nullptr) {
        return 0;
    }
    // 旧的先关掉，再按新的重建（横竖屏切换时 surface 会换 id）
    CloseWindow();
    surfaceId_ = surfaceId;
    if (surfaceId_.empty()) {
        return 0;
    }
    return EnsureWindow() ? 0 : -1;
}

/**
 * 解绑 surface —— 页面销毁时必须在 Release 之前调用
 *
 * 为什么顺序这么重要：
 *   XComponent 被销毁时 ArkUI 会析构它的 Surface 渲染节点。
 *   如果那时原生侧还持有该 surface 的 native window（甚至正在写帧），
 *   就会和系统销毁流程撞车 —— 实测崩溃栈正是
 *     RSSurfaceNode::~RSSurfaceNode -> RSNode::ClearAllModifiers（系统渲染库，主线程）
 *   所以这里要尽快把窗口还回去：加锁销毁 native window，
 *   并置空 surfaceId_，让后续 RenderFrame 直接跳过（它每次都会重新取 nativeWindow_，
 *   拿到 nullptr 就不写了）。
 */
int32_t FfmpegEngine::DetachSurface() {
    std::lock_guard<std::mutex> lock(surfaceMutex_);
    CloseWindow();
    surfaceId_.clear();
    LOGI("surface 已解绑");
    return 0;
}

bool FfmpegEngine::EnsureWindow() {
    if (nativeWindow_ != nullptr) {
        return true;
    }
    if (surfaceId_.empty()) {
        return false;
    }
    // surfaceId 是十进制字符串，转成 uint64 再建 native window
    uint64_t id = 0;
    try {
        id = std::stoull(surfaceId_);
    } catch (...) {
        LOGE("surfaceId 非法: %{public}s", surfaceId_.c_str());
        return false;
    }
    OHNativeWindow *win = nullptr;
    const int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(id, &win);
    if (ret != 0 || win == nullptr) {
        LOGE("CreateNativeWindowFromSurfaceId 失败: %{public}d", ret);
        return false;
    }
    nativeWindow_ = reinterpret_cast<NativeWindow *>(win);

    // ★ 先探一次 buffer 尺寸，把目标缩放尺寸确定下来，再开始解码。
    //
    //   为什么必须在这里探、而不是等第一帧渲染时再探：
    //   surface 的 buffer 是【显示区域尺寸】（如 1084x650），而视频可能是 320x192。
    //   如果等渲染时才登记尺寸，解码线程早就按原始 320x192 解完一大批帧了 ——
    //   实测表现就是"画面一直是左上角一小块"，因为缓存里全是未缩放的帧。
    //   这里只请求一次 buffer 再立刻中止，不写入任何数据（AbortBuffer 就是为此存在的）。
    OHNativeWindowBuffer *probe = nullptr;
    int probeFence = -1;
    if (OH_NativeWindow_NativeWindowRequestBuffer(win, &probe, &probeFence) == 0
        && probe != nullptr) {
        BufferHandle *ph = OH_NativeWindow_GetBufferHandleFromNative(probe);
        if (ph != nullptr && ph->width > 0 && ph->height > 0) {
            targetW_.store(ph->width);
            targetH_.store(ph->height);
            LOGI("surface 显示尺寸探测: %{public}dx%{public}d（解码将缩放到此尺寸）",
                 ph->width, ph->height);
        }
        // 关键：探完必须中止，否则这块 buffer 永久占着不出队，
        // surface 的 buffer 池很快耗尽，之后 RequestBuffer 会一直失败
        OH_NativeWindow_NativeWindowAbortBuffer(win, probe);
    }

    LOGI("native window 就绪, surfaceId=%{public}s", surfaceId_.c_str());
    return true;
}

void *FfmpegEngine::MapSurfaceBuffer(void *rawHandle) {
    BufferHandle *handle = static_cast<BufferHandle *>(rawHandle);
    if (handle == nullptr || handle->fd < 0 || handle->size <= 0) {
        return nullptr;
    }
    // 命中缓存：同一块 surface buffer 重复使用时一次 mmap 就够了
    for (SurfaceMap &m : surfaceMaps_) {
        if (m.fd == handle->fd && m.size == handle->size) {
            return m.ptr;
        }
    }
    void *ptr = mmap(nullptr, handle->size, PROT_READ | PROT_WRITE, MAP_SHARED,
                     handle->fd, 0);
    if (ptr == MAP_FAILED) {
        LOGE("mmap 失败: size=%{public}d fd=%{public}d", handle->size, handle->fd);
        return nullptr;
    }
    // 上限保护：surface buffer 只会循环复用固定几块，
    // 万一驱动每次给新 fd 也不会无限增长（满了就退回"每次映射"的老路）
    constexpr size_t kMapCacheMax = 8;
    if (surfaceMaps_.size() < kMapCacheMax) {
        surfaceMaps_.push_back(SurfaceMap{handle->fd, handle->size, ptr});
    }
    return ptr;
}

void FfmpegEngine::ClearSurfaceMapCache() {
    // 只 munmap，不写回 —— 这是显示缓冲，驱动自己管内容
    for (SurfaceMap &m : surfaceMaps_) {
        if (m.ptr != nullptr) {
            munmap(m.ptr, static_cast<size_t>(m.size));
        }
    }
    surfaceMaps_.clear();
}

void FfmpegEngine::CloseWindow() {
    // ★ 顺序要紧：映射是挂在窗口的 buffer 上的，必须先丢掉映射缓存，
    //   再销毁窗口 —— 反过来的话，缓存里留下的是已经失效的 fd 映射，
    //   下次上屏会往一块野内存里写（表现为整进程被杀、没有堆栈）。
    ClearSurfaceMapCache();
    if (nativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(reinterpret_cast<OHNativeWindow *>(nativeWindow_));
        nativeWindow_ = nullptr;
    }
}

bool FfmpegEngine::RenderFrame(VideoFrame &frame) {
    if (frame.width <= 0 || frame.height <= 0) {
        return false;
    }
    std::lock_guard<std::mutex> lock(surfaceMutex_);
    if (!EnsureWindow()) {
        // 没有 surface 时不算致命：解码照跑，只是不上屏。
        // 这样"只测解码"的场景（比如格式探测）不需要真实窗口。
        return false;
    }

    OHNativeWindow *win = reinterpret_cast<OHNativeWindow *>(nativeWindow_);

    // 请求一块可写 buffer
    OHNativeWindowBuffer *buffer = nullptr;
    int fenceFd = -1;
    const int64_t tReq0 = NowUs();
    int32_t ret = OH_NativeWindow_NativeWindowRequestBuffer(win, &buffer, &fenceFd);
    perfReqUs_ += (NowUs() - tReq0);
    if (ret != 0 || buffer == nullptr) {
        LOGE("RequestBuffer 失败: %{public}d", ret);
        return false;
    }

    // 从 buffer 拿 BufferHandle，再按 fd 映射成可写地址
    BufferHandle *handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
    if (handle == nullptr) {
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }

    // ★ 上屏前的约束检查（崩溃就是在这个函数里，所以这里必须先自证参数合法）
    //   stride / size / fd 任何一个不合理都直接放弃这一帧，而不是带着坏参数
    //   往下写 —— 那会是越界写，表现为整个进程被杀（没有堆栈可看）。
    if (handle->fd < 0 || handle->size <= 0 || handle->stride <= 0) {
        LOGE("buffer 参数异常: fd=%{public}d size=%{public}d stride=%{public}d",
             handle->fd, handle->size, handle->stride);
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }

    const int32_t w = frame.width;
    const int32_t h = frame.height;
    // RGBA8888：每像素 4 字节
    const int32_t rowBytes = w * 4;

    static int s_renderLog = 0;
    if (s_renderLog < 2) {
        LOGI("render: buf %{public}dx%{public}d stride=%{public}d size=%{public}d | frame %{public}dx%{public}d stride=%{public}d",
             handle->width, handle->height, handle->stride, handle->size,
             w, h, frame.stride);
        s_renderLog++;
    }

    // 目标尺寸 = buffer 的宽高。surface 会自己做最终拉伸，
    // 所以这里只要把 buffer 填满即可（缩放已在解码阶段完成）。
    // 注意不要用 SET_BUFFER_GEOMETRY 去改几何：那会把 surface 缩成视频尺寸，
    // 之后所有帧都因 buffer 过小而写不进去（实测过）。
    if (targetW_.load() != handle->width || targetH_.load() != handle->height) {
        targetW_.store(handle->width);
        targetH_.store(handle->height);
        LOGI("解码目标尺寸更新为 %{public}dx%{public}d", handle->width, handle->height);
    }

    // 边界保护：绝不越界写。buffer 行宽不足以放下当前帧宽度时直接放弃这一帧，
    // 而不是硬写 —— 硬写的后果是 SIGSEGV(SEGV_MAPERR) 整个进程被杀。
    if (handle->stride < rowBytes) {
        if (s_renderLog < 6) {
            LOGW("buffer 行宽不足: stride=%{public}d < 帧行字节 %{public}d（帧 %{public}dx%{public}d）",
                 handle->stride, rowBytes, w, h);
            s_renderLog++;
        }
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }
    const int64_t need = static_cast<int64_t>(handle->stride) * h;
    if (need > handle->size) {
        if (s_renderLog < 6) {
            LOGW("buffer 装不下: 需要 %{public}lld, 实际 %{public}d (stride=%{public}d %{public}dx%{public}d)",
                 static_cast<long long>(need), handle->size, handle->stride, w, h);
            s_renderLog++;
        }
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }

    // ★★ 2026-10-03：改成走映射缓存 ★★
    //
    //   原来是每帧 mmap + munmap 一次（3.7MB，900 个页），
    //   实测 RenderFrame 平均 8~13ms，主因就是这里的映射开销 +
    //   首次写入时的逐页缺页，而不是那趟 memcpy。
    //   surface 只循环复用固定几块 buffer，按 (fd,size) 缓存后
    //   每块只映射一次，之后每帧直接白拿。
    const int64_t tMap0 = NowUs();
    void *mapped = MapSurfaceBuffer(handle);
    perfMapUs_ += (NowUs() - tMap0);
    if (mapped == nullptr) {
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }

    // 源数据也必须够读，否则读越界
    const size_t srcNeed = static_cast<size_t>(frame.stride) * h;
    if (frame.data.size() < srcNeed) {
        LOGE("源帧数据不足: %{public}zu < %{public}zu", frame.data.size(), srcNeed);
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }

    // RGBA8888 逐行拷贝。
    // 必须按 stride 逐行拷而不是整块 memcpy：buffer 的行宽通常大于
    // 画面行字节，整块拷会让画面按斜线错位。
    //
    // ★ 2026-10-04：色调调整就做在这一步 ★
    //   这里是"解码结果 → 屏幕缓冲"的唯一通路，每帧本来就要逐行遍历一遍，
    //   把颜色矩阵塞进同一趟循环最省（不额外多一次全画面遍历）。
    //   参数全 0 时走原来的 memcpy 快路，**没有任何额外开销**。
    const int64_t tCopy0 = NowUs();
    uint8_t *dst = static_cast<uint8_t *>(mapped);
    const int32_t srcStride = frame.stride;
    RefreshColorMatrixIfNeeded();
    if (colIdentity_) {
        for (int32_t row = 0; row < h; row++) {
            memcpy(dst + static_cast<size_t>(row) * handle->stride,
                   frame.data.data() + static_cast<size_t>(row) * srcStride,
                   static_cast<size_t>(rowBytes));
        }
    } else {
        // 16.16 定点的 3x3 矩阵 + 常数偏移：每像素 9 乘 3 加，整数运算
        const int32_t m0 = colM_[0], m1 = colM_[1], m2 = colM_[2];
        const int32_t m3 = colM_[3], m4 = colM_[4], m5 = colM_[5];
        const int32_t m6 = colM_[6], m7 = colM_[7], m8 = colM_[8];
        const int32_t o0 = colO_[0], o1 = colO_[1], o2 = colO_[2];
        for (int32_t row = 0; row < h; row++) {
            const uint8_t *srcRow = frame.data.data() + static_cast<size_t>(row) * srcStride;
            uint8_t *dstRow = dst + static_cast<size_t>(row) * handle->stride;
            for (int32_t x = 0; x + 3 < rowBytes; x += 4) {
                const int32_t r = srcRow[x];
                const int32_t g = srcRow[x + 1];
                const int32_t b = srcRow[x + 2];
                const int32_t nr = (m0 * r + m1 * g + m2 * b + o0) >> 16;
                const int32_t ng = (m3 * r + m4 * g + m5 * b + o1) >> 16;
                const int32_t nb = (m6 * r + m7 * g + m8 * b + o2) >> 16;
                dstRow[x] = static_cast<uint8_t>(nr < 0 ? 0 : (nr > 255 ? 255 : nr));
                dstRow[x + 1] = static_cast<uint8_t>(ng < 0 ? 0 : (ng > 255 ? 255 : ng));
                dstRow[x + 2] = static_cast<uint8_t>(nb < 0 ? 0 : (nb > 255 ? 255 : nb));
                dstRow[x + 3] = srcRow[x + 3];   // alpha 原样搬（surface 用不到，但别留脏值）
            }
        }
    }
    perfCopyUs_ += (NowUs() - tCopy0);

    // 成功写出一帧就计数，便于判断"画面黑"到底是没渲染还是渲染了但内容不对
    const int64_t n = framesRendered_.fetch_add(1) + 1;
    if (n <= 3 || n % 30 == 0) {
        LOGI("已上屏 %{public}lld 帧 (frame %{public}dx%{public}d -> buf %{public}dx%{public}d stride %{public}d)",
             static_cast<long long>(n), w, h, handle->width, handle->height, handle->stride);
    }

    // FlushBuffer 的第 4 个参数是「脏区」，不是标志位。
    // 传全画面矩形即可 —— 传错类型（比如把枚举当参数）会编译不过或行为未定义。
    Region dirty;
    dirty.rects = nullptr;
    dirty.rectNumber = 0;
    const int64_t tFlush0 = NowUs();
    ret = OH_NativeWindow_NativeWindowFlushBuffer(win, buffer, -1, dirty);
    perfFlushUs_ += (NowUs() - tFlush0);
    if (ret != 0) {
        LOGE("FlushBuffer 失败: %{public}d", ret);
        return false;
    }
    return true;
}

MediaInfo FfmpegEngine::GetMediaInfo() const {
    return info_;
}

int64_t FfmpegEngine::GetPositionMs() const {
    return positionMs_.load();
}

/**
 * 解码线程主体
 *
 * 一轮循环做三件事：
 *   ① 处理 seek / 退出这类"立刻要做"的请求
 *   ② 队列没满就继续解，把帧填进队列
 *   ③ 从队列取帧、按 pts 节奏上屏
 *
 * 关于节奏控制（为什么不是"解出来就立刻显示"）：
 *   软解 1080p 可能比实时快好几倍，一口气全显示出来就是"快进"；
 *   也可能比实时慢，那时只能丢帧。所以按 pts 与系统时钟的差值来等：
 *   差值 > 0 → 睡到该显示的时刻；差值明显落后 → 丢掉当前帧追上进度。
 *
 * 关于丢帧阈值：
 *   落后超过 100ms 就认为追不上，直接丢。这个阈值小了会让轻微抖动也丢帧
 *   （画面不流畅），大了会让声音和画面对不上（后续接音频后更明显）。
 */
void FfmpegEngine::DecodeLoop() {
    LOGI("解码线程启动");

    FrameQueue *queue = frameQueue_.get();
    InterruptibleSleep *sleeper = sleeper_.get();
    std::string errMsg;
    bool eofReached = false;
    int64_t lastPositionReportMs = 0;

    while (!quitting_.load()) {
        // ---------- ① 处理 seek ----------
        const int64_t seekTarget = pendingSeekMs_.exchange(-1);
        if (seekTarget >= 0) {
            errMsg.clear();
            const int32_t ret = codecapi::Seek(session_, seekTarget, errMsg);
            if (ret != codecapi::kOk) {
                LOGE("seek 失败(%{public}d): %{public}s", ret, errMsg.c_str());
            }
            // seek 后解码器内部要重新对齐，EOF 标志必须清掉，
            // 否则跳到文件后半段会立刻误判为"播完了"
            eofReached = false;
            // ★★ 2026-10-04：清队列必须把缓冲还回池子 ★★
            //
            //   原来这里调的是 queue->Clear()，它只把队列长度清 0 ——
            //   帧里那几块 3.7MB 的缓冲就此丢失，解码器的缓冲池（上限 8 块）
            //   被白白抽干。真机实测的连锁反应：
            //     seek 几次之后 池命中=62/新分配=52
            //     perf-split: 转换=2797ms（其中 分配=2383ms）→ 80ms/帧 → 只有 8fps
            //   而每多一次 seek 就多丢最多 8 块，于是"拖得越多越卡"。
            //   改成逐帧回收之后，缓冲在池内循环，分配耗时回到 0。
            DrainFrameQueueRecycling();
            // ★ 这里才是"新一代"的开始：解码器已经收到 seek（上面 codecapi::Seek
            //   会清解码器内部状态并等待关键帧），此后解出来的帧才属于新位置。
            //   递增之后 renderedGen_ 自然变得不相等 → 解码线程会预渲染一帧
            //   并把"位置首帧已上屏"报上去（见 ③ 取帧上屏那段）。
            seekGen_.fetch_add(1);
            // 记下目标位置：③ 取帧上屏那段据此滤掉残留的旧帧
            lastSeekTargetMs_ = seekTarget;
            staleFrameDropCount_ = 0;
            positionMs_.store(seekTarget);
            lastFramePtsMs_ = -1;
            lastFrameSysMs_ = 0;
            // ★ 看门狗重新喂一次：seek 之后本来就要等解码器重新对齐，
            //   给它 kStallDetectMs 的宽限，别把它自己的 seek 当成"停滞"（①.5）
            lastDecodeOkMs_ = NowMs();
            Emit(PlayerEvent::POSITION, seekTarget, 0, "");
        }

        // ---------- ①.5 解码停滞看门狗（2026-10-04 新增） ----------
        //
        //   为什么必须有：真机上出现过"解码器收下了包却一帧都不吐"的病态 ——
        //     seek 之后（帧级多线程解码器的参考链被判死）视频包队列满着
        //     （深度 512），解码侧却一直睡觉，日志里连一条 perf 都没有，
        //     画面永远停在旧位置。上层只能显示"正在缓冲…"，
        //     用户看到的就是「拖完进度条没反应」。线程状态 dump 显示
        //     33 个线程全部 sleeping、0% CPU —— 不是死锁，是解码器内部状态。
        //
        //   这类病态没有通用的"解法"（在解码器内部），但**可以检测**：
        //   正在播放、队列里有包、却连续 kStallDetectMs 一帧都没解出来。
        //   检测到就用最可靠的复位手段 —— 重新 seek 一次（codecapi::Seek 会
        //   flush 解码器并等关键帧，等于把解码器整个重开），从**最后上屏的
        //   位置**重来，位置不会跳。
        //
        //   限速与上限：恢复本身要读盘 + 重解码（很贵），所以每
        //   kStallRecoverMinGapMs 最多一次；20 秒窗口内最多 kStormMaxRecover 次
        //   —— 宁可停住，也不要把播放变成 seek 循环。
        //
        //   ★ 判据里"帧队列 ≥ 4"这一条很关键 ★
        //     它把两种"不出帧"分开：
        //       · 帧队列满着却不出帧 = 解码器手里有数据却不吐 → 真卡死，要恢复；
        //       · 帧队列空着不出帧   = 在等盘读（冷缓存实测首帧最长要 18 秒）
        //         → 这是正常的慢，重 seek 只会把读盘重新来过，必须放过。
        //     冷启动时上层还没 play()（在等首帧），本来就不会进这里；
        //     但用户拖到未缓存区域时同样可能慢上几秒，所以这条判据必须有。
        if (playing_.load() && lastDecodeOkMs_ > 0 && queue->Size() >= 4) {
            const int64_t kStallDetectMs = 2000;
            const int64_t kStallRecoverMinGapMs = 2000;
            const int64_t kStormWindowMs = 20000;
            const int32_t kStormMaxRecover = 4;
            // 这里单独取一次时间：下面的 nowMs 在节流段才声明（在它之后）
            const int64_t wdNowMs = NowMs();
            const int64_t sinceOkMs = wdNowMs - lastDecodeOkMs_;
            if (sinceOkMs >= kStallDetectMs && wdNowMs - lastStallRecoverMs_ >= kStallRecoverMinGapMs) {
                lastStallRecoverMs_ = wdNowMs;
                // ★ 用一个 20 秒窗口给恢复动作封顶 ★
                //
                //   为什么不能只看"恢复之后有没有再出帧"：真机上出现过
                //   每次恢复都只出一帧就再次停滞的情形（帧级解码器参考链被判死），
                //   出帧就重置计数的话，计数永远回到 0 → 恢复永不封顶 →
                //   播放变成"每 1.5 秒重新 seek 一次"的幻灯片。
                //   改成"窗口内最多恢复 4 次"，无论出不出帧都能停下来。
                if (wdNowMs - stallStormStartMs_ > kStormWindowMs) {
                    stallStormStartMs_ = wdNowMs;
                    stallRecoverCount_ = 0;
                }
                if (stallRecoverCount_ < kStormMaxRecover) {
                    stallRecoverCount_++;
                    // 回到"最后上屏的那一帧"，而不是 positionMs_ —— 后者在视频
                    // 卡住时会被音频线程推着往前走，用它会把画面跳到前面去
                    const int64_t backToMs = (lastFramePtsMs_ >= 0)
                        ? lastFramePtsMs_ : positionMs_.load();
                    LOGW("解码停滞 %{public}lldms 未出帧（帧队列=%{public}d），"
                         "本窗口第 %{public}d 次恢复：重新 seek 到 %{public}lldms",
                         static_cast<long long>(sinceOkMs), queue->Size(),
                         stallRecoverCount_, static_cast<long long>(backToMs));
                    pendingSeekMs_.store(backToMs);
                } else if (stallRecoverCount_ == kStormMaxRecover) {
                    stallRecoverCount_++;   // 只打一条，之后这个窗口内闭嘴
                    LOGE("解码停滞：本窗口已恢复 %{public}d 次仍不出帧，"
                         "暂停恢复动作（把播放变成 seek 循环更糟）",
                         kStormMaxRecover);
                }
                // 无论恢复与否都把计时基准推后，避免每 50ms 刷一条日志
                lastDecodeOkMs_ = wdNowMs;
            }
        }

        // ---------- ② 填队列 ----------
        // ★ 解码时就把画面缩放到 surface 的实际 buffer 尺寸。
        //   原因：surface 分配的 buffer 是【显示区域尺寸】（如 1084x650），
        //   不是视频尺寸。按 1:1 拷 320x192 进去，画面只会出现在左上角一小块。
        //   buffer 尺寸由 RenderFrame 首次调用时探到并缓存在 targetW_/targetH_。
        //   若还没探到（第一帧之前），先按原始尺寸解，下一轮就会补上缩放。
        const int32_t tw = targetW_.load();
        const int32_t th = targetH_.load();
        int burst = 0;
        while (!quitting_.load() && !eofReached && burst < kMaxDecodeBurst
               && queue->Size() < kFrameQueueSize) {
            VideoFrame frame;
            errMsg.clear();
            // 统计单帧解码耗时（含 FFmpeg 解码 + sws 缩放，两者都在这个调用里）
            const int64_t decodeT0 = NowUs();
            const int32_t ret = codecapi::DecodeVideoFrame(session_, frame, errMsg, tw, th);
            perfDecodeUs_ += (NowUs() - decodeT0);
            if (ret == codecapi::kOk) {
                queue->Push(frame);
                // ★ 看门狗喂狗：解出一帧就说明解码器活着（①.5）
                lastDecodeOkMs_ = NowMs();
                stallRecoverCount_ = 0;
                burst++;
                continue;
            }
            if (ret == codecapi::kAgain) {
                // 数据还不够，下一轮再试，别在这里空转
                break;
            }
            if (ret == codecapi::kEof) {
                eofReached = true;
                break;
            }
            LOGE("解码失败(%{public}d): %{public}s", ret, errMsg.c_str());
            Emit(PlayerEvent::ERROR, ret, 0, errMsg);
            SetState(PlayerState::ERROR_STATE);
            quitting_.store(true);
            break;
        }

        if (quitting_.load()) {
            break;
        }

        // ---------- ③ 取帧上屏 ----------
        // 暂停时不去取帧，让队列保持满的状态，恢复播放能立刻出画面。
        //
        // ★★ 2026-10-03：「首帧」是例外 —— 即使还没开始播放，也要先渲染一帧 ★★
        //
        //   起因（用户反馈）："点开东西还没渲染完就在放了" —— 原来 READY 就立刻
        //   play()，音频与主时钟先跑起来，而首帧还在解码/转换（还得等 surface 就绪），
        //   于是先响声音、画面还是黑的。
        //
        //   要修就得让上层"先等首帧上屏，再开始播"。但上层不能靠 play() 去催首帧
        //   ——那正是要避免的；所以这里由引擎**预渲染**一帧：未播放状态下也允许
        //   走一次解码+上屏，并把"首帧已上屏"通过 POSITION 事件（data2=1）报上去。
        //   上层收到后才调 play()，此时画面已经在屏幕上了。
        //
        //   只预渲染一帧（framesRendered_ == 0 才放行），之后照旧等待播放：
        //   否则会变成"未播放也一直解码上屏"，白烧 CPU 且打乱暂停语义。
        //
        //   ★ 2026-10-03 改按**seek 世代**算（原来按"整场第一帧"）：
        //     续播流程是「READY → 上层发起 seek → 引擎预渲染」，
        //     按整场第一帧算的话，预渲染很可能抢在 seek 生效之前，
        //     把"文件开头那一帧"渲染出去（实测：先上屏 1 帧、20ms 后 seek 到位），
        //     上层据此就会提前开播、或先闪一下开头。
        //     改成"这个位置的第一帧还没上屏"之后，语义才对得上。
        const int64_t curSeekGen = seekGen_.load();
        const bool firstFrameOfGenMissing = (renderedGen_ != curSeekGen);
        const bool preRollFirstFrame = !playing_.load() && firstFrameOfGenMissing;
        if (!playing_.load() && !preRollFirstFrame) {
            sleeper->Sleep(20);
            continue;
        }

        // ★★ 2026-10-03 重做节流：先看队头的时间戳，再决定「等 / 取 / 丢」★★
        //
        //   真机现场（第五指令BD1024高清中英双字.rmvb）：clock 日志显示
        //   30 帧只花 0.5 秒（约 60fps），而 pts 每 0.5 秒涨 1.25 秒 ——
        //   画面在**2.5 倍速狂奔**，声音还是 1 倍速，于是越拉越远，
        //   追不上数据时又卡住等包，用户看到的就是「卡一下快一下」。
        //
        //   根因是旧写法里那道"时钟兜底"：
        //       if (waitMs > 1000) waitMs = 0;   // ← 一旦领先 >1 秒就彻底放弃节流
        //   它的本意是"音频时钟刚起步/seek 后还没追上时别把画面卡死"，
        //   但副作用是：**只要画面领先超过 1 秒，节流就被永久关闭**，画面自由狂奔。
        //   而现实里 seek 之后很容易领先 1 秒以上（视频要从关键帧重开，
        //   音频却从 seek 点直接接上），所以这个洞几乎必然被触发。
        //
        //   正确做法：等待要**分片**做，而不是一刀切成 0：
        //     · 队头还没到显示时刻 → 睡一小段（最多 50ms）再看一眼，
        //       帧留在队列里不取（取出来就意味着必须马上上屏）；
        //     · 队列满了解码线程自然停下，画面最多领先一个队列的深度；
        //     · 确实落后（waitMs < -100）才丢帧追进度。
        //   这样"领先"永远被压在一个队列深度（约 0.3 秒）以内，不会无限拉大。
        int64_t headPts = 0;
        if (!queue->Peek(headPts)) {
            // 队列空：要么正在补数据，要么已经解完
            if (eofReached && queue->Size() == 0) {
                positionMs_.store(info_.durationMs);
                Emit(PlayerEvent::POSITION, info_.durationMs, 0, "");
                Emit(PlayerEvent::COMPLETED, 0, 0, "");
                SetState(PlayerState::COMPLETED);
                playing_.store(false);
            }
            continue;
        }

        // 主时钟：有音频用音频时钟，否则退回单调时钟。
        // 这段只用来**判断**，真正取帧在后面（判断不需要帧本身，只要 pts）。
        int64_t clockSyncMs = -1;      // 供日志
        int64_t waitMs = 0;
        {
            const int64_t nowMsProbe = NowMs();
            const AudioOutput *ao = audio_.get();
            if (audioReady_ && ao != nullptr && ao->IsRunning()) {
                const int64_t bytesPerMs = static_cast<int64_t>(codecapi::AudioSampleRate())
                                           * codecapi::AudioChannels() * 2 / 1000;
                const int64_t notYetPlayedMs = (bytesPerMs > 0)
                    ? (static_cast<int64_t>(ao->BufferedBytes()) / bytesPerMs) : 0;
                clockSyncMs = audioWrittenMs_.load() - notYetPlayedMs;
                waitMs = headPts - clockSyncMs;
            } else if (lastFramePtsMs_ >= 0) {
                const int64_t targetSysMs = lastFrameSysMs_ + (headPts - lastFramePtsMs_);
                waitMs = targetSysMs - nowMsProbe;
            }
        }

        // ★★ 预渲染首帧时**绝不等时钟**（2026-10-03 实测踩到的坑）★★
        //
        //   预渲染发生在"还没播放"的时候：此时**音频解码线程还没启动**
        //   （它在 Start/play 里才起来），所以 audioWrittenMs_ 是 0、环形缓冲是空的，
        //   主时钟就等于 0。而首帧的 pts 是续播位置（本例 3316819ms），
        //   于是 waitMs = 3316819 —— 按下面的逻辑就是"睡 50ms 再看一眼"，
        //   永远等不到，首帧永远出不来。
        //   真机日志正是这样：READY 之后 8 秒什么都没有，直到上层兜底超时开播
        //   （play() 一启动音频线程，第一帧 52ms 内就上屏了）。
        //   预渲染的目的就是"先把画面显示出来"，它没有时钟可依，也不该依。
        if (preRollFirstFrame) {
            waitMs = 0;
        }

        if (waitMs > 2) {
            // 还没到显示时刻：只睡一小段，不取帧。
            // 为什么分片：seek / 暂停 / 退出都要能立刻响应，
            // 睡一个几秒的长觉会让这些操作全部变迟钝。
            // ★ 预渲染首帧例外：见下面 preRollFirstFrame 的说明，它必须立刻上屏。
           
            const int64_t napMs = (waitMs > 50) ? 50 : waitMs;
            sleeper->Sleep(static_cast<int>(napMs));
            continue;
        }

        VideoFrame frame;
        // 时间已经到了（或已经晚了）：取出来上屏
        if (!queue->Pop(frame, 0)) {
            continue;
        }

        // 按 pts 与「主时钟」的差值决定等待还是丢帧
        const int64_t nowMs = NowMs();
        // ★ 这两个值提到 if 外面，是为了让下面每 30 帧的 clock 汇总日志能打到
        //   （原先它们只在 else 分支里，出了问题看不到中间过程，
        //    只能看到前 8 次"即将丢帧"的抽样 —— 排查"卡一下快一下"时完全不够）
        int64_t audioClockDbg = clockSyncMs;
        int64_t frameDeltaMs = 0;
        if (lastFramePtsMs_ < 0) {
            // 第一帧（或 seek 之后的第一帧）：对齐基准，立刻显示
            lastFramePtsMs_ = frame.ptsMs;
            lastFrameSysMs_ = nowMs;
        } else {
            // ── 主时钟选择：有音频时以音频时钟为准 ──
            //
            // 为什么音频时钟更准：
            //   系统单调时钟只能保证"帧间隔正确"，但软解耗时是波动的，
            //   累计误差会让画面逐渐偏离声音（播久了就是"口型对不上"）。
            //   而音频时钟反映的是扬声器真实播到的位置
            //   （已写入时长 − 缓冲里还没播的时长），画面跟着它走就不会散。
            //
            //   没有可用音频轨时才退回单调时钟。
            const AudioOutput *ao = audio_.get();
            if (audioReady_ && ao != nullptr && ao->IsRunning()) {
                const int64_t bytesPerMs = static_cast<int64_t>(codecapi::AudioSampleRate())
                                           * codecapi::AudioChannels() * 2 / 1000;
                // 缓冲里"还没播出去"的长度
                const int64_t notYetPlayedMs = (bytesPerMs > 0)
                    ? (static_cast<int64_t>(ao->BufferedBytes()) / bytesPerMs) : 0;
                const int64_t audioClockMs = audioWrittenMs_.load() - notYetPlayedMs;
                audioClockDbg = audioClockMs;
                waitMs = frame.ptsMs - audioClockMs;
            } else {
                const int64_t targetSysMs = lastFrameSysMs_ + (frame.ptsMs - lastFramePtsMs_);
                waitMs = targetSysMs - nowMs;
            }

            // ★★ 2026-10-03：原来这里有一道「waitMs > 1000 就当 0」的兜底，
            //   已经【删除】—— 它正是"卡一下快一下"的元凶 ★★
            //
            //   原注释写的理由（"音频时钟刚起步或 seek 后没追上时，一味等待会让
            //   画面卡住不动"）本身没错，但做法太粗暴：只要画面领先超过 1 秒，
            //   节流就被**永久关闭**，画面开始按解码速度自由狂奔。
            //   真机实测就是 2.5 倍速跑（30 帧只用 0.5 秒，pts 却涨了 1.25 秒），
            //   一路领先到 12 秒，追不上码流时又卡住等包。
            //
            //   现在等待改成在**取帧之前**分片进行（见上面那段"先看队头"），
            //   领先量永远被压在一个队列深度以内，这里不需要、也不能再一刀切成 0。
            //
            //   （若确实遇到"时钟还没准备好"的极端情况，分片等待也会每 50ms
            //     重新判断一次，时钟一走起来就自动继续，不会真的卡死。）

            // ★★ 丢帧保护：把 waitMs 夹到「两帧应间隔的上限」★★
            //
            //   为什么必须有这道夹子（2026-09-28 真机实测发现的 bug）：
            //   丢帧判据原本是 waitMs < -100，也就是"这帧比主时钟落后 100ms 以上"。
            //   但 waitMs 是拿【音频时钟】减【绝对 pts】，两者基准并不总是同一原点：
            //     · seek 之后 audioWrittenMs_ 被清零重新累积，而帧 pts 仍是绝对值，
            //       于是 waitMs 里混进了一个与 seek 目标等量的偏移；
            //     · 更严重的是当视频流本身短于容器时长（音频比视频长）时，
            //       音频时钟会一路超过所有剩余帧的 pts，
            //       表现为 waitMs 恒为一个大负数 →【剩余视频帧被全部丢掉】。
            //   实测现场：10 秒 .rm 样本解出 65 帧、只上屏 1 帧，
            //   position 因此永远停在 0（进度按已上屏帧的 pts 上报）。
            //
            //   两道夹子分别挡住这两种偏移，且都不影响正常的"追进度"：
            //     ① 下限 = -两帧间隔：差值再大也只当"落后一帧"，
            //        真正持续落后时仍会连续丢帧追上（丢的是零头，不是全部）。
            //     ② 上限 = 当前帧 pts 相对上一帧的增量：时钟超前不应让画面加速。
            //   只有当「上一帧已经渲染过、而当前帧 pts 比它还早」才夹下限 ——
            //   那种情况帧序本身就是乱序或重复，夹住比丢掉更合理。
            const int64_t frameDeltaMsCalc = (lastFramePtsMs_ >= 0)
                ? (frame.ptsMs - lastFramePtsMs_) : 0;
            frameDeltaMs = frameDeltaMsCalc;

            // ★ 时间基准自愈（2026-10-03 加，针对真机「卡一下快一下」）★★
            //
            //   起因：这个 .rmvb 会偶发吐出 833~845 秒的坏时间戳（正常是 2~6 秒），
            //   已经在解码层做了防护（见 ResolveFrameTimestamp），这里再加一道：
            //   万一坏值从别处混进来（音频时钟跳变、坏包等），
            //   绝不能让【一个】坏值把整段播放带偏 ——
            //   下面的夹子只会把它当成"落后一帧"或"超前一帧"，
            //   但基准被顶高之后，后续每一帧都会持续被判成落后/超前，
            //   表现为画面一会儿全速一会儿定住。
            //   做法：差距离谱时直接以当前帧为新基准，不等待、不丢帧。
            //   一个坏值只影响一帧，之后立刻恢复正常节奏。
            if (frameDeltaMs > 3000 || frameDeltaMs < -2000) {
                if (tsRealignLog_ < 8) {
                    tsRealignLog_++;
                    LOGW("时间基准重置: 本帧 pts=%{public}lld 上一帧=%{public}lld "
                         "（差 %{public}lldms，超出合理范围）audioClock=%{public}lld",
                         static_cast<long long>(frame.ptsMs),
                         static_cast<long long>(lastFramePtsMs_),
                         static_cast<long long>(frameDeltaMs),
                         static_cast<long long>(audioClockDbg));
                }
                lastFramePtsMs_ = frame.ptsMs;
                lastFrameSysMs_ = nowMs;
                waitMs = 0;
                frameDeltaMs = 0;
            }

            // 帧时长兜底：相邻帧时间戳相同或缺失时（实测 .rm 的 RealVideo 就是
            // 每帧 pts 都为 0），按解码层给出的帧时长推进，而不是当成 0 差值 ——
            // 否则整个视频会被瞬间播完，进度条也永远停在 0。
            const int64_t frameSpanMs = (frame.durationMs > 0) ? frame.durationMs : 40;
            const int64_t deltaClamp = (frameDeltaMs > 0) ? frameDeltaMs : frameSpanMs;
            // ★★ 2026-10-03：把"落后"分成两档，并允许**限速丢帧追上** ★★
            //
            //   现场（第五指令BD1024高清中英双字.rmvb，加供包诊断后实测）：
            //     · 文件每秒只给 21.6 个视频包，而视频是 24.6 帧/秒
            //       （视频线程是"1 包解 1 帧"：调用=30 出帧=30 等包=0）
            //       —— 也就是说这个片的视频流比它自己的时间戳**少约 12% 的帧**。
            //     · 原来 waitMs 被夹到 [-deltaClamp, +deltaClamp]（±41ms），
            //       于是 `waitMs < -100` 永不成立 → **永不丢帧** →
            //       画面只能以 0.88x 的速度推进 → 越播越落后音频（实测 4~5 秒），
            //       同时视频包队列被慢慢抽干（实测 490 → 33，约 4 分钟见底），
            //       见底后每帧都要等包，画面就变成"一卡一快"。
            //
            //   为什么当年要夹：注释里记着一次真实事故 —— 音频时钟超前时
            //   夹子失效会导致"整段画面被一次丢光"（10 秒样本 65 帧只上屏 1 帧）。
            //   所以这次不是简单地把夹子删掉，而是**分档 + 限速**：
            //     · 落后 ≤ 200ms：仍按抖动处理，夹到一帧间隔，照常显示；
            //     · 落后 > 200ms：这是真落后，保留真实差值交给下面的丢帧分支，
            //       但**丢帧速率限制在 1 帧/200ms（5 帧/秒）**：
            //         - 12% 的帧缺口只需要丢约 3 帧/秒 → 能稳稳追上并保持同步；
            //         - 而"时钟异常超前几秒"那种病态情况最多丢 5 帧/秒，
            //           不会一次丢光，几十秒内自然收敛。
            const int64_t kRealLagMs = 200;
            const int64_t kMinDropIntervalMs = 200;
            int64_t waitForDrop = waitMs;
            if (waitMs < -deltaClamp) {
                if (waitMs > -kRealLagMs) {
                    waitMs = -deltaClamp;                 // 抖动：吸收掉
                } else if (nowMs - lastCatchUpDropMs_ < kMinDropIntervalMs) {
                    waitMs = -deltaClamp;                 // 真落后，但丢得太密：这一帧先不丢
                } else {
                    waitMs = waitForDrop;                 // 允许这一帧被丢（下面判 waitMs < -100）
                }
            }
            if (frameDeltaMs > 0 && waitMs > frameDeltaMs) {
                waitMs = frameDeltaMs;
            }

            // 抽样诊断：前 8 次"即将丢帧"各打一次，便于核对时钟与 pts 的真实差值
            // （这两个数最容易出错：一个是绝对时间戳，一个是从 0 起算的相对量）
            if (waitMs < -20 && dropDbgCount_ < 8) {
                dropDbgCount_++;
                LOGI("sync: pts=%{public}lld audioClock=%{public}lld writtenMs=%{public}lld "
                     "wait=%{public}lld delta=%{public}lld",
                     static_cast<long long>(frame.ptsMs),
                     static_cast<long long>(audioClockDbg),
                     static_cast<long long>(audioWrittenMs_.load()),
                     static_cast<long long>(waitMs),
                     static_cast<long long>(frameDeltaMs));
            }

            // ★ 2026-10-03：这里原来还有一句 `if (waitMs > 2) sleeper->Sleep(waitMs);`
            //   —— 已删除。等待现在一律在**取帧之前**做（队头还没到点就继续睡），
            //   走到这里说明这一帧已经出队，只能"显示或丢弃"，不能再睡：
            //   睡在这里等于帧被拿在手上干等，队列白腾出一个位置，
            //   而且睡多久都改变不了"它已经过期"的事实。
            if (waitMs < -100) {
                // 落后太多：丢掉这一帧直接追进度。
                // 不丢的话会越积越多，表现为"越播越延迟"
                droppedFrames_.fetch_add(1);
                // 若这一帧是"分档逻辑"放行的追进度丢帧，单独计一个数：
                // 排查时"因抖动丢帧"和"因片源帧缺口追进度丢帧"是完全不同的两件事
                if (waitMs <= -200) {
                    catchUpDrops_.fetch_add(1);
                }
                // 先取 pts 再回收 —— 回收会把 ptsMs 归零，
                // 顺序反了基准就变成 0，之后所有帧都会算成"落后"而全被丢掉
                const int64_t droppedPts = frame.ptsMs;
                // ★ 用回收代替 Clear()：Clear() 只清长度，这块 3.7MB 的缓冲
                //   随后会被下一次 Pop 的移动赋值直接释放掉，池子就白做了。
                //   实测这条分支很热（首轮 450 帧里丢了 230 帧），必须回收。
                codecapi::RecycleFrameBuffer(session_, frame);
                lastFramePtsMs_ = droppedPts;
                lastFrameSysMs_ = nowMs;
                continue;
            }
        }

        if (quitting_.load()) {
            break;
        }

        const int64_t renderT0 = NowUs();
        // ★★ 刚 seek 完时，只认"位置对得上"的帧 ★★（2026-10-03 实测）
        //
        //   现象：引擎已经把 seek 交给解码器、队列也清了，但**流水线里已经算完的
        //   那一帧拦不住** —— 实测上屏的"位置首帧"pts=0，而 seek 目标是 3600853ms，
        //   也就是文件开头那一帧。上层看到这个位置对不上就会拒绝开播，
        //   结果又只能靠超时兜底（声音与画面一起、但要等 8 秒）。
        //   处理：在"这个位置的首帧还没上屏"期间，pts 与 seek 目标差得离谱的帧
        //   直接丢掉、不上屏也不报信号，继续等真正属于新位置的那一帧。
        //   加计数上限是防呆：万一某个文件的时间戳整体不可信（比如 pts 恒为 0），
        //   不能无限丢下去，丢掉若干帧后就照常放行。
        //
        //   ★★ 2026-10-04 修正：窗口原来写的是"目标前 3 秒"，太窄，把**正常帧**
        //      当成残留帧丢掉了。真机现场（用户拖动滑块到 80:07）：
        //        seek 后丢弃位置不符的残留帧: pts=4806816 目标=4810238ms（第 31 次）
        //        …（第 32~40 次）…
        //        位置首帧已上屏（seek 世代 2, pts=4807278ms）
        //      拖动本身是好的，但 seek 落在目标**前 3.4 秒**的那个关键帧上
        //      （RMF 的关键帧间隔约 4.5 秒，落在目标前是常态），于是从关键帧到
        //      目标之间的 40 帧全被判成"残留帧"丢掉；而当时解码只有 1~2 fps，
        //      40 帧 ≈ 40 秒 → 用户看到的就是「拖完没反应、又弹回去继续播」。
        //
        //      这个过滤真正要拦的是"seek 之前那一帧"（实测 pts=0 而目标是
        //      3600853ms，差了一小时），所以窗口放宽到 ±30 秒/2 分钟完全够用，
        //      丢帧上限也从 60 收到 8：能拦住跨小时的残留帧，又不会拖慢正常 seek。
        if (firstFrameOfGenMissing && lastSeekTargetMs_ >= 0) {
            const int64_t kBeforeToleranceMs = 30000;    // 关键帧落在目标前是常态
            const int64_t kAfterToleranceMs = 120000;    // 稀疏关键帧允许跳得更远
            const int32_t kStaleDropMax = 8;             // 兜底：最多丢 8 帧就放行
            const bool ptsPlausible = (frame.ptsMs >= lastSeekTargetMs_ - kBeforeToleranceMs)
                && (frame.ptsMs <= lastSeekTargetMs_ + kAfterToleranceMs);
            if (!ptsPlausible && staleFrameDropCount_ < kStaleDropMax) {
                staleFrameDropCount_++;
                LOGW("seek 后丢弃位置不符的残留帧: pts=%{public}lld 目标=%{public}lldms（第 %{public}d 次）",
                     static_cast<long long>(frame.ptsMs),
                     static_cast<long long>(lastSeekTargetMs_),
                     staleFrameDropCount_);
                codecapi::RecycleFrameBuffer(session_, frame);
                continue;
            }
        }
        const bool renderOk = RenderFrame(frame);
        perfRenderUs_ += (NowUs() - renderT0);
        perfFrames_++;
        // ★ 只有**这一次渲染成功**，才算"这个位置的第一帧已经上屏"
        //   （失败时不能置位，否则上层会收到一个画面其实没出来的"首帧信号"）
        const bool firstFrameOfThisGen = firstFrameOfGenMissing;
        if (renderOk && firstFrameOfThisGen) {
            renderedGen_ = curSeekGen;
            LOGI("位置首帧已上屏（seek 世代 %{public}lld, pts=%{public}lldms），上报给上层以便开始播放",
                 static_cast<long long>(curSeekGen),
                 static_cast<long long>(frame.ptsMs));
        }

        // ★★ 2026-10-03：补上一直漏掉的"渲染后更新时钟基准" ★★
        //
        //   这两个值（上一帧的 pts / 对应的系统时刻）原本只在
        //   ①首帧对齐 ②丢帧 两条分支里被写过，**正常渲染路径上没有更新**。
        //   后果是它们一直停在"起播那第一帧"，于是：
        //     · frameDeltaMs = 本帧 pts − 首帧 pts，会随时间无限增长
        //       （实测每约 3 秒就超过 3000ms 一次，日志里那条"时间基准重置"
        //         就是它触发的，差值精确等于 72 帧 × 41.7ms ≈ 3003ms）；
        //     · 无音轨时退回的单调时钟（targetSys = lastFrameSysMs_ +
        //       (pts − lastFramePtsMs_)）算出来的目标时刻是错的，
        //       画面要么狂奔要么定住；
        //     · 两道防丢帧夹子（都以 frameDeltaMs 为准）全部失效。
        //   这一处漏更新，是"画面节奏忽快忽慢"的根因之一，不只是日志难看。
        lastFramePtsMs_ = frame.ptsMs;
        lastFrameSysMs_ = nowMs;
        // 每 30 帧打一次性能汇总，用来定位"卡"到底卡在解码还是上屏
        if ((perfFrames_ % 30) == 0) {
            const int64_t df = perfFrames_ > 0 ? (perfDecodeUs_ / perfFrames_) : 0;
            const int64_t rf = perfFrames_ > 0 ? (perfRenderUs_ / perfFrames_) : 0;
            LOGI("perf: 帧数=%{public}lld 解码均=%{public}lld us 上屏均=%{public}lld us "
                 "合计=%{public}lld us（%{public}lld fps 上限）丢帧=%{public}lld",
                 static_cast<long long>(perfFrames_),
                 static_cast<long long>(df),
                 static_cast<long long>(rf),
                 static_cast<long long>(df + rf),
                 static_cast<long long>(df + rf > 0 ? 1000000 / (df + rf) : 0),
                 static_cast<long long>(droppedFrames_.load()));

            // ★ 2026-10-03：把这 30 帧窗口内的解码耗时拆开打一次。
            //   起因：真机实测 1280x720 RV40 的 .rmvb 出现
            //   「解码均=212ms 但进程 CPU 只用 28%」的矛盾 —— 老的"解码均"
            //   分子把每次空转(kAgain)也累加了、分母只算成功帧，口径是坏的，
            //   完全指不出方向。这四个数是【同一窗口内的绝对耗时】，
            //   不是平均值：拿它们和 df*30 一比就知道有多少是纯等待。
            // ★ 2026-10-03：上屏耗时也拆开打一次。理由见 FfmpegEngine.h 里
            //   perfReqUs_ 的说明 —— 只有"拷贝"和"映射"能优化，
            //   "等合成器"（Request/Flush 阻塞）优化代码是没用的。
            //   这里打的是**每帧平均值**（累计 ÷ 已上屏帧数），与"上屏均"口径一致。
            LOGI("perf-render(每帧均): 取缓冲=%{public}lldus 映射=%{public}lldus "
                 "拷贝=%{public}lldus 送显=%{public}lldus",
                 static_cast<long long>(perfFrames_ > 0 ? perfReqUs_ / perfFrames_ : 0),
                 static_cast<long long>(perfFrames_ > 0 ? perfMapUs_ / perfFrames_ : 0),
                 static_cast<long long>(perfFrames_ > 0 ? perfCopyUs_ / perfFrames_ : 0),
                 static_cast<long long>(perfFrames_ > 0 ? perfFlushUs_ / perfFrames_ : 0));

            // ★ 时钟汇总（2026-10-03 加）：每 30 帧打一次当前节奏。
            //   排查「卡一下快一下」时靠的就是它 —— 只看前 8 次"即将丢帧"的
            //   抽样日志看不出"忽快忽慢"，而这一行能连续看到：
            //   这一帧的 pts、与上一帧的间隔、主时钟走到哪、净等待多少毫秒。
            //   正常播放时 wait 应在 0~帧间隔之间小幅波动、pts 稳步增长；
            //   一旦出现 wait 长时间贴 -deltaClamp（全速跑）或贴 +deltaClamp（定住），
            //   就是时钟基准被带偏了。
            LOGI("clock: pts=%{public}lld delta=%{public}lld audioClock=%{public}lld "
                 "writtenMs=%{public}lld wait=%{public}lld 丢帧=%{public}lld(追进度 %{public}lld) "
                 "队列=%{public}zu",
                 static_cast<long long>(frame.ptsMs),
                 static_cast<long long>(frameDeltaMs),
                 static_cast<long long>(audioClockDbg),
                 static_cast<long long>(audioWrittenMs_.load()),
                 static_cast<long long>(waitMs),
                 static_cast<long long>(droppedFrames_.load()),
                 static_cast<long long>(catchUpDrops_.load()),
                 queue->Size());

            if (session_ != nullptr) {
                codecapi::VideoDecodeSplit sp;
                codecapi::TakeVideoDecodeSplit(session_, sp);
                const int64_t calls = sp.calls;
                const int64_t idlePct = calls > 0 ? (sp.again * 100 / calls) : 0;
                LOGI("perf-split(近30帧): receive=%{public}lldms send=%{public}lldms "
                     "等包=%{public}lldms 转换=%{public}lldms"
                     "（其中 分配=%{public}lldms 缩放=%{public}lldms）| "
                     "池命中=%{public}lld 新分配=%{public}lld 只resize=%{public}lld | "
                     "调用=%{public}lld 空转=%{public}lld(%{public}lld%%) 出帧=%{public}lld "
                     "被拒重发=%{public}lld 等关键帧=%{public}lld",
                     static_cast<long long>(sp.recvUs / 1000),
                     static_cast<long long>(sp.sendUs / 1000),
                     static_cast<long long>(sp.popUs / 1000),
                     static_cast<long long>(sp.convUs / 1000),
                     static_cast<long long>(sp.allocUs / 1000),
                     static_cast<long long>(sp.scaleUs / 1000),
                     static_cast<long long>(sp.poolHit),
                     static_cast<long long>(sp.allocNew),
                     static_cast<long long>(sp.resizeOnly),
                     static_cast<long long>(calls),
                     static_cast<long long>(sp.again),
                     static_cast<long long>(idlePct),
                     static_cast<long long>(sp.frames),
                     static_cast<long long>(sp.flushRetry),
                     static_cast<long long>(sp.waitKeyframe));
            }
        }

        // 位置按 pts 上报，而不是按解到第几帧 ——
        // 这样 seek 之后进度条能立刻跳到正确位置
        positionMs_.store(frame.ptsMs);
        // ★ 2026-10-03：首帧（本位置的第一帧）必须无条件上报一次，
        //   并在 data2 带上"位置首帧已上屏"标记 —— 上层靠它决定"可以开始播了"。
        //   为什么不能只靠 200ms 节流条件：pts 小于 200ms 的文件（很多测试片段
        //   就是从 0 开始的）永远不满足 `pts - 上次上报 >= 200`，上层就永远等不到信号。
        if (firstFrameOfThisGen && renderOk) {
            Emit(PlayerEvent::POSITION, frame.ptsMs, 1, "");
            lastPositionReportMs = frame.ptsMs;
        } else if (frame.ptsMs - lastPositionReportMs >= 200
                   || frame.ptsMs < lastPositionReportMs) {
            Emit(PlayerEvent::POSITION, frame.ptsMs, 0, "");
            lastPositionReportMs = frame.ptsMs;
        }
        // ★ 2026-10-03：这一帧用完，把像素缓冲还给会话的缓冲池（复用，
        //   不再每帧重新分配）。必须放在位置上报【之后】——回收会清零 ptsMs。
        //   这一步是本次性能修复的落点：此前每帧 3.7MB 的分配+清零+拷贝
        //   实测要 79ms/帧（perf-split 的"转换"项）。
        codecapi::RecycleFrameBuffer(session_, frame);
    }

    LOGI("解码线程退出（累计丢帧 %{public}lld）",
         static_cast<long long>(droppedFrames_.load()));
}

/**
 * 音频解码线程主体
 *
 * 循环很简单：解一段 PCM → 写进环形缓冲 → 缓冲快满就歇一会儿。
 *
 * 为什么要"缓冲快满就歇"而不是一直猛写：
 *   音频解码比视频简单得多（cook/ac3 一帧只要几百微秒），如果不加节流，
 *   几秒钟就能把整个文件的音频解完并塞满缓冲 —— 内存浪费不说，
 *   seek 时还要把这一大堆已经解好的音频全丢掉。
 *   所以维持在"缓冲里有两三百毫秒"的水位最经济。
 */
void FfmpegEngine::AudioLoop() {
    LOGI("音频线程启动");

    AudioChunk chunk;
    std::string errMsg;
    // 目标水位：缓冲里保留约 300ms 的数据。
    // 低于这个水位就继续解，高于就等 —— 300ms 足以吸收常规的解码抖动。
    const size_t targetBytes = static_cast<size_t>(codecapi::AudioSampleRate())
                               * codecapi::AudioChannels() * 2 * 300 / 1000;
    int64_t lastPosMs = 0;

    while (!quitting_.load()) {
        // ---------- ① 处理 seek ----------
        //
        // ★ 纯音频文件（没有视频轨）时，seek 必须由音频线程处理。
        //   原因：seek 的处理逻辑原本只在视频 DecodeLoop 里（见那边的①），
        //   而纯音频文件的视频线程根本不会启动（Play 里按 hasVideo 判断），
        //   于是 pendingSeekMs_ 永远不会被取走 —— 表现就是
        //   音频文件拖进度条无效、续播起点也失效。
        //   这里补上：只有当视频线程没在跑时才由本线程处理，
        //   避免两边同时抢同一个 seek 请求。
        if (!threadStarted_) {
            const int64_t seekTarget = pendingSeekMs_.exchange(-1);
            if (seekTarget >= 0) {
                std::string seekErr;
                const int32_t sret = codecapi::Seek(session_, seekTarget, seekErr);
                if (sret != codecapi::kOk) {
                    LOGE("音频线程 seek 失败(%{public}d): %{public}s",
                         sret, seekErr.c_str());
                }
                audioEof_.store(false);
                positionMs_.store(seekTarget);
                // ★ 与 SeekTo 的约定保持一致：audioWrittenMs_ 是【相对】基准。
                //   SeekTo 里已把它清零（注释说明：用绝对目标会让画面等一个
                //   "已经过去很久"的时钟）。所以这里把累加器也归零，
                //   绝对位置靠 seekTargetMs_ 这个偏移量还原。
                lastPosMs = 0;
                audioWrittenMs_.store(0);
                seekTargetMs_ = seekTarget;
                audioLastReportMs_ = seekTarget;
                Emit(PlayerEvent::POSITION, seekTarget, 0, "");
            }
        }

        AudioOutput *out = audio_.get();
        if (out == nullptr) {
            break;
        }

        // 暂停时不喂数据：让缓冲自然消耗完，避免暂停久了自己攒一大堆
        if (!playing_.load()) {
            sleeper_->Sleep(30);
            continue;
        }

        // 水位够了就歇
        if (out->BufferedBytes() >= targetBytes) {
            sleeper_->Sleep(20);
            continue;
        }

        chunk.Clear();
        errMsg.clear();
        const int32_t ret = codecapi::DecodeAudioChunk(session_, chunk, errMsg);

        if (ret == codecapi::kEof) {
            audioEof_.store(true);
            LOGI("音频已解到结尾");
            break;
        }
        if (ret == codecapi::kAgain) {
            sleeper_->Sleep(10);
            continue;
        }
        if (ret != codecapi::kOk) {
            // 音频解码出错不终止播放：视屏还能看，只是没声音。
            // 这比"因为音频小问题导致整片打不开"要好得多。
            LOGE("音频解码失败(%{public}d): %{public}s", ret, errMsg.c_str());
            audioEof_.store(true);
            break;
        }

        if (chunk.data.empty()) {
            continue;
        }

        // ★ 均衡器：写设备之前就地处理（见 ApplyAudioEq 的说明）。
        //   总开关关闭或全部增益为 0dB 时它立刻返回，等于没有这段代码。
        ApplyAudioEq(chunk.data);

        // 写入环形缓冲；一次写不完（缓冲满）就分次写，避免丢数据造成断音
        size_t offset = 0;
        const size_t total = chunk.data.size();
        while (offset < total && !quitting_.load()) {
            const size_t n = out->Write(chunk.data.data() + offset, total - offset);
            offset += n;
            if (n == 0 || offset < total) {
                // 缓冲满：稍等再写。这一步保证了音频永不丢帧
                sleeper_->Sleep(10);
            }
        }

        // ★★ 2026-10-04：向后 seek 之后，音频侧的"位置基准"必须跟着重置 ★★
        //
        //   现场（用户反馈「拖动进度条后弹回去继续播放」，真机 diag.log 实锤）：
        //     12:39:16.4  persist pos=1562534   ← 拖到 26:03，界面正确
        //     12:39:17.5  persist pos=1562534   ← 仍然正确
        //     12:39:18.7  persist pos=5024622   ← 弹回 83:45，之后每 1.1 秒涨 1104ms
        //   而同一时刻引擎已经把新位置的帧上屏了：
        //     位置首帧已上屏（seek 世代 2, pts=1558685ms）
        //   ——画面是对的，位置却是错的，问题就在下面那行累加：
        //     lastPosMs = (chunk.ptsMs > lastPosMs) ? chunk.ptsMs : (lastPosMs + duration)
        //   向后 seek 后新位置的音频包 pts（1558xxx）**小于** lastPosMs（5024xxx），
        //   于是走 else 分支从旧基准一直加下去：位置永远回不到新位置，
        //   而它每 500ms 就上报一次，界面每 100ms 被覆盖一次 → 滑块"弹回去"。
        //
        //   只需要判断"倒退"：向前 seek 时 chunk.ptsMs 自然大于旧值、走 if 分支自愈，
        //   只有向后 seek 才需要在这里把基准归零。
        //   阈值取 1 秒：正常播放相邻音频块不可能倒退 1 秒（时间戳防护已保证单调），
        //   而 seek 的跨度是分钟级，两者不会混淆。
        if (chunk.ptsMs > 0 && lastPosMs > 0 && chunk.ptsMs + 1000 < lastPosMs) {
            LOGI("音频位置倒退到 %{public}lldms（seek 已生效），重置音频侧基准（原基准 %{public}lldms）",
                 static_cast<long long>(chunk.ptsMs), static_cast<long long>(lastPosMs));
            lastPosMs = 0;
            // 与 SeekTo 的约定保持一致：音频时钟是【相对】基准，seek 后从 0 重新累积
            audioWrittenMs_.store(0);
            // 归零后下面那段上报会立刻发一条新位置的 POSITION 给上层
            audioLastReportMs_ = 0;
        }

        // 累计"已提交给输出的音频时长"——音频时钟的基准
        const int64_t before = audioWrittenMs_.load();
        lastPosMs = (chunk.ptsMs > lastPosMs) ? chunk.ptsMs : (lastPosMs + chunk.durationMs);
        const int64_t advanced = lastPosMs - before;
        if (advanced > 0) {
            audioWrittenMs_.store(lastPosMs);
        }

        // ★ 位置上报（音频侧）。
        //
        // 为什么音频线程也要上报：视频线程是位置上报的主力，但**纯音频文件
        // 没有视频轨**，视频线程不会启动（见 Play 里 hasVideo 的判断），
        // 那时 positionMs_ 将永远停在 0 —— 进度条不动、续播也记不住位置。
        //
        // 上限保护：音频线程可能一次解出很多数据，positionMs_ 直接写会让
        // 进度条跑到"比实际听到的更靠前"。这里用「已写入 − 缓冲里还没播的」
        // 得到音频时钟（与解码线程判断等待用的是同一个基准），
        // 它反映的是扬声器真实播到的位置。
        if (audio_ != nullptr) {
            const int64_t bytesPerMs = static_cast<int64_t>(codecapi::AudioSampleRate())
                                       * codecapi::AudioChannels() * 2 / 1000;
            const int64_t notYetPlayedMs = (bytesPerMs > 0)
                ? (static_cast<int64_t>(audio_->BufferedBytes()) / bytesPerMs) : 0;
            // lastPosMs 是相对量（seek 后会归零），加上 seekTargetMs_ 才是绝对位置
            const int64_t clockMs = lastPosMs - notYetPlayedMs + seekTargetMs_;
            if (clockMs > 0) {
                positionMs_.store(clockMs);
                if (clockMs - audioLastReportMs_ >= 500
                    || clockMs < audioLastReportMs_) {
                    audioLastReportMs_ = clockMs;
                    Emit(PlayerEvent::POSITION, clockMs, 0, "");
                }
            }
        }
    }

    LOGI("音频线程退出（欠载 %{public}lld 次）",
         static_cast<long long>(audioUnderruns_.load()));
}

void FfmpegEngine::Release() {
    if (state_.load() == PlayerState::RELEASED) {
        return;
    }
    quitting_.store(true);
    playing_.store(false);
    // 三重唤醒：睡在帧等待里的、睡在队列上的、睡在时钟上的，都要醒
    if (sleeper_ != nullptr) {
        sleeper_->Wake();
    }
    if (frameQueue_ != nullptr) {
        frameQueue_->Abort();
    }
    // ★ 先停音频输出，再 join 音频线程。
    //   反过来的话，音频线程可能正卡在 Write（缓冲满在等），
    //   而音频回调已经停了、缓冲永远不消耗 —— 就死锁了。
    if (audio_ != nullptr) {
        audio_->Stop();
    }
    if (audioThreadStarted_ && audioThread_.joinable()) {
        audioThread_.join();
    }
    audioThreadStarted_ = false;
    // 字幕线程：同样在音频之后、会话关闭之前 join。
    // 它读的是 session_，所以必须早于 codecapi::Close(session_)。
    if (subtitleThreadStarted_ && subtitleThread_.joinable()) {
        subtitleThread_.join();
    }
    subtitleThreadStarted_ = false;
    if (threadStarted_ && decodeThread_.joinable()) {
        decodeThread_.join();
    }
    threadStarted_ = false;

    if (session_ != nullptr) {
        codecapi::Close(session_);
        session_ = nullptr;
    }

    audio_.reset();

    {
        std::lock_guard<std::mutex> lock(surfaceMutex_);
        CloseWindow();
        surfaceId_.clear();
    }

    SetState(PlayerState::RELEASED);
    // 释放后不能再有回调进来，清掉避免悬空
    callback_ = nullptr;
}

// ==================== 字幕线程（2026-09-29 新增） ====================

/**
 * 字幕解码线程主体
 *
 * 循环从会话的字幕队列取事件，追加进 subtitleCues_ 缓存。
 * 缓存按 startMs 升序，界面用 GetActiveSubtitle 按当前播放位置查询。
 *
 * 为什么用"缓存 + 查询"而不是"推送一条显示一条"：
 *   见 IPlayerEngine.h 里 SubtitleCue 的说明 —— 字幕是时间对齐的，
 *   让界面按位置来问，天然同步，也不用在 ArkTS 侧再做去重。
 */
void FfmpegEngine::SubtitleLoop() {
    LOGI("字幕线程启动");
    // 注意类型归属：SubtitleEvent 定义在 softplayer 命名空间（FfmpegTypes.h），
    // 不在 codecapi 里 —— 它是"解码器产出的原始事件"，与引擎的 SubtitleCue
    // 是两回事（后者是引擎对外暴露的、给界面查询用的形式）。
    softplayer::SubtitleEvent ev;
    std::string errMsg;
    int64_t idleRounds = 0;

    while (!quitting_.load()) {
        if (!subtitleEnabled_.load() || session_ == nullptr) {
            sleeper_->Sleep(100);
            continue;
        }

        const int32_t ret = codecapi::ReadSubtitleEvent(session_, ev, errMsg);
        if (ret == codecapi::kOk) {
            idleRounds = 0;
            // 写入缓存（加锁：查询线程同时在读）
            {
                std::lock_guard<std::mutex> lk(subtitleMutex_);
                SubtitleCue cue;
                cue.startMs = ev.startMs;
                cue.endMs = ev.endMs;
                cue.text = ev.text;
                subtitleCues_.push_back(cue);
                // 超过上限就从头丢：往回拖很远是少数情况，
                // 而无限增长会让长片（几万条字幕）白吃几 MB 内存
                while (subtitleCues_.size() > kSubtitleCacheMax) {
                    subtitleCues_.pop_front();
                }
                subtitleCachedCount_.store(static_cast<int64_t>(subtitleCues_.size()));
                // 记录"已解到哪"：用最后一条的结束时间
                subtitleDecodedUntilMs_.store(cue.endMs);
            }
            continue;   // 立刻取下一批，尽快把缓存填起来
        }
        if (ret == codecapi::kEof) {
            // 字幕流读完是正常结束，不是错误。停在这里等 quitting，
            // 不再空转打日志。
            LOGI("字幕流已解到结尾（已缓存 %{public}lld 条）",
                 static_cast<long long>(subtitleCachedCount_.load()));
            while (!quitting_.load()) {
                sleeper_->Sleep(200);
            }
            break;
        }
        if (ret == codecapi::kAgain) {
            // 队列暂时没有包（解复用还没读到，或者这个区间本来就没字幕）
            idleRounds++;
            // 空闲时退让：一开始紧凑等（字幕通常连续），
            // 长时间没有就放慢，避免空转烧 CPU
            sleeper_->Sleep(idleRounds < 20 ? 5 : 50);
            continue;
        }
        // 真错误：记一次就停，避免刷屏
        LOGW("字幕读取失败(%{public}d): %{public}s", ret, errMsg.c_str());
        while (!quitting_.load()) {
            sleeper_->Sleep(200);
        }
        break;
    }
    LOGI("字幕线程退出");
}

// ==================== 音轨 / 字幕切换 ====================

bool FfmpegEngine::CanSwitchAudioTrack() const {
    return info_.audioTracks.size() > 1;
}

int32_t FfmpegEngine::SwitchAudioTrack(int32_t streamIndex) {
    // 重入保护：重开会话的过程会停线程、关会话、重建三样东西，
    // 期间绝不能让第二个重开请求插进来（会作用在半个状态上）。
    // 用 CAS 而不是先 load 再 store，避免两次快速点击同时通过检查。
    bool expected = false;
    if (!reopening_.compare_exchange_strong(expected, true)) {
        LOGW("已有一次轨道重开在进行中，忽略本次请求");
        return -1;
    }
    // 用 RAII 保证任何 return 路径都会复位标志，
    // 否则一次失败会把引擎永久锁死（后续再也切不了轨）
    struct Guard {
        std::atomic<bool> *f;
        ~Guard() { f->store(false); }
    } guard{&reopening_};

    // 目标必须真的存在，否则重开一次也只是白费功夫（还会把播放打断）
    bool found = false;
    for (const AudioTrackInfo &t : info_.audioTracks) {
        if (t.index == streamIndex) {
            found = true;
            break;
        }
    }
    if (!found) {
        LOGW("切换音轨失败：下标 %{public}d 不在可切换列表里", streamIndex);
        return -1;
    }
    if (streamIndex == info_.currentAudioIndex) {
        LOGI("已经在用音轨 %{public}d，无需切换", streamIndex);
        return 0;
    }

    const int64_t pos = positionMs_.load();
    const bool wasPlaying = playing_.load();
    LOGI("切换音轨 %{public}d -> %{public}d（当前位置 %{public}lld ms, 播放中=%{public}d）",
         info_.currentAudioIndex, streamIndex,
         static_cast<long long>(pos), wasPlaying ? 1 : 0);

    // 关键：换成新音轨重开，并把旧位置带过去。
    // 字幕轨保持当前选择不变 —— 用户换配音不该把字幕也关掉。
    std::string switchErr;
    const int32_t ret = PrepareWithTracks(path_, streamIndex,
                                          info_.currentSubtitleIndex,
                                          /*manageAudio=*/false, switchErr);
    if (ret != 0) {
        LOGE("切换音轨重开失败(%{public}d): %{public}s", ret, switchErr.c_str());
        return ret;
    }

    // 恢复到原位置。用 SeekTo 而不是直接写 pendingSeekMs：
    // SeekTo 里还负责清解码帧队列与重置时钟基准，漏掉会看到"换轨后
    // 先闪几帧旧画面"的经典现象。
    if (pos > 0) {
        SeekTo(pos);
    }
    if (wasPlaying) {
        Start();
    }
    LOGI("切换音轨完成，现用音轨 %{public}d", info_.currentAudioIndex);
    return 0;
}

int32_t FfmpegEngine::SetSubtitleTrack(int32_t streamIndex) {
    if (streamIndex < 0) {
        // 关闭字幕：不必重开会话，只停掉消费端
        //
        // 为什么关闭可以这么轻：字幕包本来就在解复用线程里被"没启用就丢弃"，
        // 真正的成本只是不再往缓存里追加。而重开一次会打断播放，
        // 关闭字幕却是个纯 UI 操作，不该有副作用。
        subtitleEnabled_.store(false);
        {
            std::lock_guard<std::mutex> lk(subtitleMutex_);
            subtitleCues_.clear();
            subtitleCachedCount_.store(0);
        }
        info_.currentSubtitleIndex = -1;
        LOGI("已关闭字幕");
        return 0;
    }

    // 打开某条字幕轨需要重开（解复用线程只在 Open 时才知道要投递哪条流）
    //
    // 重入保护：理由同 SwitchAudioTrack —— 重开过程绝不能并发。
    // 字幕这条尤其要防：界面每 100ms 刷新一次字幕，用户连点两下
    // "内嵌字幕"就可能把两次重开叠在一起。
    bool expectedSub = false;
    if (!reopening_.compare_exchange_strong(expectedSub, true)) {
        LOGW("已有一次轨道重开在进行中，忽略本次字幕切换请求");
        return -1;
    }
    struct Guard {
        std::atomic<bool> *f;
        ~Guard() { f->store(false); }
    } guard{&reopening_};

    bool usable = false;
    for (const SubtitleTrackInfo &t : info_.subtitleTracks) {
        if (t.index == streamIndex) {
            usable = t.supported;
            break;
        }
    }
    if (!usable) {
        LOGW("启用字幕失败：下标 %{public}d 不存在或是不支持的图形字幕", streamIndex);
        return -1;
    }

    const int64_t pos = positionMs_.load();
    const bool wasPlaying = playing_.load();
    LOGI("启用字幕轨 %{public}d（当前位置 %{public}lld ms）",
         streamIndex, static_cast<long long>(pos));
    // 预检失败原因（用于日志；界面靠返回值判断即可）
    std::string switchErr;

    const int32_t ret = PrepareWithTracks(path_, info_.currentAudioIndex, streamIndex,
                                          /*manageAudio=*/false, switchErr);
    if (ret != 0) {
        // 换轨失败：预检已经保证过"正常情况下不会失败"，走到这里说明是
        // 预检之后、重开之前那一瞬间文件出了问题（被删/被占用）。
        // 此时旧会话已拆，播放确实中断了 —— 把原因报上去让界面能说清楚。
        LOGE("启用字幕重开失败(%{public}d): %{public}s", ret, switchErr.c_str());
        return ret;
    }
    if (pos > 0) {
        SeekTo(pos);
    }
    if (wasPlaying) {
        Start();
    }
    LOGI("字幕轨已启用 %{public}d", info_.currentSubtitleIndex);
    return 0;
}

bool FfmpegEngine::GetActiveSubtitle(SubtitleCue &out) const {
    if (!subtitleEnabled_.load()) {
        return false;
    }
    const int64_t now = positionMs_.load();
    std::lock_guard<std::mutex> lk(subtitleMutex_);
    if (subtitleCues_.empty()) {
        return false;
    }

    // 从后往前找：绝大多数查询命中的都是最近的一条（缓存是升序的），
    // 从尾部开始找通常一两次就命中。字幕条数可能有几万，
    // 每次都从头扫会让 UI 线程做无谓的工作。
    for (auto it = subtitleCues_.rbegin(); it != subtitleCues_.rend(); ++it) {
        const SubtitleCue &c = *it;
        if (c.startMs > now) {
            continue;            // 还没到，继续往前找
        }
        // 这是"已经开始"的最晚一条。若当前时间在它的展示区间内就显示它。
        if (now <= c.endMs) {
            out = c;
            return true;
        }
        // 已经开始但已经过期 —— 说明当前时刻确实没有字幕（两条之间的空隙）
        return false;
    }
    // 所有字幕都还没开始（now 比最早一条还早）
    return false;
}

}  // namespace softplayer
