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
    //   代价是一次轻量的打开+关闭（实测换轨总耗时本来就有几百毫秒，
    //   这点开销可以忽略）；收益是**失败路径彻底消失**。
    {
        std::string probeErr;
        const int32_t probe = codecapi::ProbeTracks(path_, audioStreamIndex,
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

int32_t FfmpegEngine::SeekTo(int64_t positionMs) {
    if (state_.load() == PlayerState::RELEASED || session_ == nullptr) {
        return -1;
    }
    if (positionMs < 0) {
        positionMs = 0;
    }
    pendingSeekMs_.store(positionMs);
    // seek 要清掉排队的旧帧，否则会先闪几帧旧画面
    frameQueue_->Clear();
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

void FfmpegEngine::CloseWindow() {
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
    int32_t ret = OH_NativeWindow_NativeWindowRequestBuffer(win, &buffer, &fenceFd);
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

    void *mapped = mmap(nullptr, handle->size, PROT_READ | PROT_WRITE, MAP_SHARED,
                        handle->fd, 0);
    if (mapped == MAP_FAILED) {
        LOGE("mmap 失败: size=%{public}d fd=%{public}d", handle->size, handle->fd);
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }

    // 源数据也必须够读，否则读越界
    const size_t srcNeed = static_cast<size_t>(frame.stride) * h;
    if (frame.data.size() < srcNeed) {
        LOGE("源帧数据不足: %{public}zu < %{public}zu", frame.data.size(), srcNeed);
        munmap(mapped, handle->size);
        OH_NativeWindow_NativeWindowAbortBuffer(win, buffer);
        return false;
    }

    // RGBA8888 逐行拷贝。
    // 必须按 stride 逐行拷而不是整块 memcpy：buffer 的行宽通常大于
    // 画面行字节，整块拷会让画面按斜线错位。
    uint8_t *dst = static_cast<uint8_t *>(mapped);
    const int32_t srcStride = frame.stride;
    for (int32_t row = 0; row < h; row++) {
        memcpy(dst + static_cast<size_t>(row) * handle->stride,
               frame.data.data() + static_cast<size_t>(row) * srcStride,
               static_cast<size_t>(rowBytes));
    }

    if (munmap(mapped, handle->size) != 0) {
        LOGE("munmap 失败");
    }

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
    ret = OH_NativeWindow_NativeWindowFlushBuffer(win, buffer, -1, dirty);
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
            queue->Clear();
            positionMs_.store(seekTarget);
            lastFramePtsMs_ = -1;
            lastFrameSysMs_ = 0;
            Emit(PlayerEvent::POSITION, seekTarget, 0, "");
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
        // 暂停时不去取帧，让队列保持满的状态，恢复播放能立刻出画面
        if (!playing_.load()) {
            sleeper->Sleep(20);
            continue;
        }

        VideoFrame frame;
        if (!queue->Pop(frame, 50)) {
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

        // 按 pts 与「主时钟」的差值决定等待还是丢帧
        const int64_t nowMs = NowMs();
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
            int64_t waitMs = 0;
            int64_t audioClockDbg = -1;
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

            // 时钟上限保护：音频刚启动时钟还停在起点（或 seek 后尚未追上）时，
            // 差值可能很大。这时如果一味等待，画面会卡住不动。
            // 超过 1 秒就认为"时钟还没准备好"，改为立即显示。
            if (waitMs > 1000) {
                waitMs = 0;
            }

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
            const int64_t frameDeltaMs = (lastFramePtsMs_ >= 0)
                ? (frame.ptsMs - lastFramePtsMs_) : 0;
            // 帧时长兜底：相邻帧时间戳相同或缺失时（实测 .rm 的 RealVideo 就是
            // 每帧 pts 都为 0），按解码层给出的帧时长推进，而不是当成 0 差值 ——
            // 否则整个视频会被瞬间播完，进度条也永远停在 0。
            const int64_t frameSpanMs = (frame.durationMs > 0) ? frame.durationMs : 40;
            const int64_t deltaClamp = (frameDeltaMs > 0) ? frameDeltaMs : frameSpanMs;
            if (waitMs < -deltaClamp) {
                waitMs = -deltaClamp;
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

            if (waitMs > 2) {
                sleeper->Sleep(static_cast<int>(waitMs));
            } else if (waitMs < -100) {
                // 落后太多：丢掉这一帧直接追进度。
                // 不丢的话会越积越多，表现为"越播越延迟"
                droppedFrames_.fetch_add(1);
                // 先取 pts 再 Clear —— Clear 会把 ptsMs 归零，
                // 顺序反了基准就变成 0，之后所有帧都会算成"落后"而全被丢掉
                const int64_t droppedPts = frame.ptsMs;
                frame.Clear();
                lastFramePtsMs_ = droppedPts;
                lastFrameSysMs_ = nowMs;
                continue;
            }
        }

        if (quitting_.load()) {
            break;
        }

        const int64_t renderT0 = NowUs();
        RenderFrame(frame);
        perfRenderUs_ += (NowUs() - renderT0);
        perfFrames_++;
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
        }

        // 位置按 pts 上报，而不是按解到第几帧 ——
        // 这样 seek 之后进度条能立刻跳到正确位置
        positionMs_.store(frame.ptsMs);
        if (frame.ptsMs - lastPositionReportMs >= 200 || frame.ptsMs < lastPositionReportMs) {
            Emit(PlayerEvent::POSITION, frame.ptsMs, 0, "");
            lastPositionReportMs = frame.ptsMs;
        }
        frame.Clear();
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
