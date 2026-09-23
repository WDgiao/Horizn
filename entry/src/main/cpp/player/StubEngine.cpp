#include "StubEngine.h"
#include <chrono>
#include "hilog/log.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "SoftPlayer"

namespace softplayer {

namespace {
/** 假媒体时长：12 秒，方便观察进度条跑动 */
constexpr int64_t kFakeDurationMs = 12000;
/** 进度上报间隔 */
constexpr int kTickMs = 200;
/** Prepare 模拟耗时 */
constexpr int kPrepareDelayMs = 120;

void SetState(std::atomic<PlayerState> &slot, PlayerState s)
{
    slot.store(s);
}
}  // namespace

StubEngine::~StubEngine()
{
    Release();
}

void StubEngine::Emit(PlayerEvent type, int64_t d1, int64_t d2, const std::string &text)
{
    std::lock_guard<std::mutex> lock(cbMutex_);
    if (cb_) {
        cb_(type, d1, d2, text);
    }
}

void StubEngine::SetCallback(EventCallback cb)
{
    std::lock_guard<std::mutex> lock(cbMutex_);
    cb_ = std::move(cb);
}

int32_t StubEngine::Prepare(const std::string &path)
{
    if (released_.load()) {
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "StubEngine::Prepare path=%{public}s", path.c_str());
    SetState(state_, PlayerState::PREPARING);
    Emit(PlayerEvent::STATE_CHANGED, static_cast<int64_t>(PlayerState::PREPARING), 0, "");

    // 模拟探测耗时
    std::this_thread::sleep_for(std::chrono::milliseconds(kPrepareDelayMs));

    if (released_.load()) {
        return -1;
    }
    info_.durationMs = kFakeDurationMs;
    info_.width = 1280;
    info_.height = 720;
    info_.frameRate = 25.0;
    info_.videoCodec = "stub-video";
    info_.audioCodec = "stub-audio";
    info_.hasVideo = true;
    info_.hasAudio = true;

    SetState(state_, PlayerState::READY);
    Emit(PlayerEvent::DURATION, kFakeDurationMs, 0, "");
    Emit(PlayerEvent::VIDEO_SIZE, info_.width, info_.height, "");
    Emit(PlayerEvent::PREPARED, 0, 0, "");
    Emit(PlayerEvent::STATE_CHANGED, static_cast<int64_t>(PlayerState::READY), 0, "");
    return 0;
}

int32_t StubEngine::Start()
{
    if (released_.load()) {
        return -1;
    }
    if (state_.load() != PlayerState::READY && state_.load() != PlayerState::PAUSED) {
        OH_LOG_WARN(LOG_APP, "StubEngine::Start ignored, state=%{public}d",
                    static_cast<int>(state_.load()));
        return -2;
    }
    paused_.store(false);

    // 首次 Start 才起线程；暂停后恢复复用同一线程
    if (!worker_.joinable()) {
        stopFlag_.store(false);
        worker_ = std::thread(&StubEngine::PlayLoop, this);
    }
    SetState(state_, PlayerState::PLAYING);
    Emit(PlayerEvent::STATE_CHANGED, static_cast<int64_t>(PlayerState::PLAYING), 0, "");
    return 0;
}

int32_t StubEngine::Pause()
{
    if (state_.load() != PlayerState::PLAYING) {
        return -2;
    }
    paused_.store(true);
    SetState(state_, PlayerState::PAUSED);
    Emit(PlayerEvent::STATE_CHANGED, static_cast<int64_t>(PlayerState::PAUSED), 0, "");
    return 0;
}

int32_t StubEngine::SeekTo(int64_t positionMs)
{
    if (released_.load()) {
        return -1;
    }
    int64_t clamped = positionMs;
    if (clamped < 0) {
        clamped = 0;
    }
    if (clamped > info_.durationMs) {
        clamped = info_.durationMs;
    }
    positionMs_.store(clamped);
    Emit(PlayerEvent::POSITION, clamped, 0, "");
    return 0;
}

int32_t StubEngine::SetSurface(const std::string &surfaceId)
{
    surfaceId_ = surfaceId;
    OH_LOG_INFO(LOG_APP, "StubEngine::SetSurface id len=%{public}zu", surfaceId.size());
    return 0;
}

MediaInfo StubEngine::GetMediaInfo() const
{
    return info_;
}

int64_t StubEngine::GetPositionMs() const
{
    return positionMs_.load();
}

void StubEngine::PlayLoop()
{
    while (!stopFlag_.load() && !released_.load()) {
        if (paused_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }
        int64_t pos = positionMs_.load() + kTickMs;
        if (pos >= info_.durationMs) {
            positionMs_.store(info_.durationMs);
            Emit(PlayerEvent::POSITION, info_.durationMs, 0, "");
            SetState(state_, PlayerState::COMPLETED);
            Emit(PlayerEvent::COMPLETED, 0, 0, "");
            Emit(PlayerEvent::STATE_CHANGED, static_cast<int64_t>(PlayerState::COMPLETED), 0, "");
            return;
        }
        positionMs_.store(pos);
        Emit(PlayerEvent::POSITION, pos, 0, "");
        std::this_thread::sleep_for(std::chrono::milliseconds(kTickMs));
    }
}

void StubEngine::Release()
{
    if (released_.exchange(true)) {
        return;  // 幂等
    }
    stopFlag_.store(true);
    if (worker_.joinable()) {
        worker_.join();
    }
    {
        std::lock_guard<std::mutex> lock(cbMutex_);
        cb_ = nullptr;
    }
    SetState(state_, PlayerState::RELEASED);
    OH_LOG_INFO(LOG_APP, "StubEngine released");
}

}  // namespace softplayer
