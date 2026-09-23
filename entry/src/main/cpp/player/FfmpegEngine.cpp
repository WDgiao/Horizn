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

/** 帧队列深度：8 帧 ≈ 0.13 秒 @60fps，够平滑又不会让 seek 迟滞 */
constexpr size_t kFrameQueueSize = 8;

/** 解码循环里每轮最多连续解多少帧，避免一次占满队列 */
constexpr int kMaxDecodeBurst = 4;

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
    if (state_.load() == PlayerState::RELEASED) {
        return -1;
    }
    // 已经准备过就先清理，允许复用同一个引擎换文件
    if (session_ != nullptr) {
        codecapi::Close(session_);
        session_ = nullptr;
    }
    // 换文件前先停掉音频输出与音频线程，否则新文件的音频会和旧的混在一起
    if (audioThreadStarted_) {
        quitting_.store(true);
        sleeper_->Wake();
        if (audioThread_.joinable()) {
            audioThread_.join();
        }
        audioThreadStarted_ = false;
    }
    if (audio_ != nullptr) {
        audio_->Stop();
    }
    audioReady_ = false;
    audioEof_.store(false);
    audioWrittenMs_.store(0);
    if (threadStarted_) {
        quitting_.store(true);
        sleeper_->Wake();
        frameQueue_->Abort();
        if (decodeThread_.joinable()) {
            decodeThread_.join();
        }
        threadStarted_ = false;
        // 队列被 Abort 过，换一个新的，否则后续 Pop 永远返回 false
        frameQueue_ = std::make_unique<FrameQueue>(kFrameQueueSize);
    }

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
    const int32_t ret = codecapi::Open(path_, newSession, summary, errMsg);
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
        if (audio_->Start(codecapi::AudioSampleRate(), codecapi::AudioChannels())) {
            LOGI("音频输出就绪");
        } else {
            LOGW("音频输出启动失败，本次播放将静音");
            audioReady_ = false;
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

    positionMs_.store(0);
    pendingSeekMs_.store(-1);
    lastFramePtsMs_ = -1;
    lastFrameSysMs_ = 0;

    Emit(PlayerEvent::DURATION, info_.durationMs, 0, "");
    Emit(PlayerEvent::VIDEO_SIZE, info_.width, info_.height, "");
    Emit(PlayerEvent::PREPARED, 0, 0, "");
    SetState(PlayerState::READY);
    LOGI("Prepare 成功: %{public}s %{public}s/%{public}s %{public}dx%{public}d",
         path_.c_str(), info_.videoCodec.c_str(), info_.audioCodec.c_str(),
         info_.width, info_.height);
    return 0;
}

int32_t FfmpegEngine::Start() {
    if (state_.load() == PlayerState::RELEASED || session_ == nullptr) {
        return -1;
    }

    if (!threadStarted_) {
        quitting_.store(false);
        // 从 READY 起步时，时钟基准必须重置，
        // 否则首帧会按一个陈旧的 lastFrameSysMs_ 去算等待，导致开头卡住
        lastFramePtsMs_ = -1;
        lastFrameSysMs_ = 0;
        decodeThread_ = std::thread(&FfmpegEngine::DecodeLoop, this);
        threadStarted_ = true;
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
        audioThread_ = std::thread(&FfmpegEngine::AudioLoop, this);
        audioThreadStarted_ = true;
        LOGI("音频线程已启动");
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
            const int32_t ret = codecapi::DecodeVideoFrame(session_, frame, errMsg, tw, th);
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
            const AudioOutput *ao = audio_.get();
            if (audioReady_ && ao != nullptr && ao->IsRunning()) {
                const int64_t bytesPerMs = static_cast<int64_t>(codecapi::AudioSampleRate())
                                           * codecapi::AudioChannels() * 2 / 1000;
                // 缓冲里"还没播出去"的长度
                const int64_t notYetPlayedMs = (bytesPerMs > 0)
                    ? (static_cast<int64_t>(ao->BufferedBytes()) / bytesPerMs) : 0;
                const int64_t audioClockMs = audioWrittenMs_.load() - notYetPlayedMs;
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

        RenderFrame(frame);

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

}  // namespace softplayer
