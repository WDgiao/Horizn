#ifndef SOFT_PLAYER_STUB_ENGINE_H
#define SOFT_PLAYER_STUB_ENGINE_H

#include "IPlayerEngine.h"
#include <atomic>
#include <thread>
#include <mutex>

namespace softplayer {

/**
 * 占位引擎
 *
 * 故意不做任何解码，只是"假装"播放：
 *   Prepare 后延时一小段上报 PREPARED，
 *   Start 后按固定间隔递增位置并上报 POSITION，
 *   跑到 durationMs 后上报 COMPLETED。
 *
 * 它存在的意义是：在 FFmpeg 到位之前，先把
 *   NAPI 绑定、状态机、线程安全回调、进度上报、错误传递
 * 这些与解码无关的部分在真机上验证通过。
 * 这样等 FFmpeg 接入时，只剩 "填解码" 这一件事。
 */
class StubEngine : public IPlayerEngine {
public:
    StubEngine() = default;
    ~StubEngine() override;

    void SetCallback(EventCallback cb) override;
    int32_t Prepare(const std::string &path) override;
    int32_t Start() override;
    int32_t Pause() override;
    int32_t SeekTo(int64_t positionMs) override;
    int32_t SetSurface(const std::string &surfaceId) override;
    MediaInfo GetMediaInfo() const override;
    int64_t GetPositionMs() const override;
    void Release() override;

private:
    /** 播放循环：模拟按帧推进并上报进度 */
    void PlayLoop();

    void Emit(PlayerEvent type, int64_t d1, int64_t d2, const std::string &text);

    EventCallback cb_;
    mutable std::mutex cbMutex_;

    std::atomic<PlayerState> state_{PlayerState::IDLE};
    std::atomic<bool> stopFlag_{false};
    std::atomic<bool> paused_{false};
    std::atomic<int64_t> positionMs_{0};
    std::atomic<bool> released_{false};

    MediaInfo info_;
    std::thread worker_;
    std::string surfaceId_;
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_STUB_ENGINE_H
