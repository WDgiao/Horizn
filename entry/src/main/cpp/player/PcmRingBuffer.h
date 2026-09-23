#ifndef SOFT_PLAYER_PCM_RING_BUFFER_H
#define SOFT_PLAYER_PCM_RING_BUFFER_H

#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

namespace softplayer {

/**
 * 单生产者单消费者无锁环形缓冲（SPSC）
 *
 * 为什么必须无锁：
 *   消费者是 OHAudio 的音频回调线程。音频回调对时间极其敏感 ——
 *   一旦在回调里因为等锁而阻塞，就会出现爆音/断音。
 *   所以消费者侧只做原子读写 + memcpy，绝不加锁、绝不分配内存。
 *
 * 为什么用「读写下标不做取模」的写法：
 *   如果每次都对 capacity 取模，就必须区分「空」和「满」两种下标相等的情况，
 *   要么浪费一个槽位，要么额外维护一个计数（那就需要原子读改写，产生竞争）。
 *   这里让两个下标单调递增（uint64 基本不可能回绕），
 *   用 written_ - read_ 直接得到可读字节数，判断空满都是一次减法，最简单也最快。
 *
 * 内存序说明：
 *   生产者：先写数据，再以 release 语义发布 written_
 *   消费者：先以 acquire 语义读 written_，再读数据
 *   这个配对保证了「数据可见」一定发生在「下标可见」之前。
 */
class PcmRingBuffer {
public:
    /** @param capacityBytes 容量（字节），建议取音频一帧大小的整数倍 */
    explicit PcmRingBuffer(size_t capacityBytes)
        : capacity_(capacityBytes < 4096 ? 4096 : capacityBytes),
          buffer_(capacity_, 0) {}

    /** 禁止拷贝：内部有裸缓冲与原子量 */
    PcmRingBuffer(const PcmRingBuffer &) = delete;
    PcmRingBuffer &operator=(const PcmRingBuffer &) = delete;

    /**
     * 写入数据（仅生产者线程调用）
     * @param data 源数据
     * @param bytes 字节数
     * @return 实际写入的字节数（空间不足时会少于 bytes）
     */
    size_t Write(const uint8_t *data, size_t bytes) {
        const uint64_t written = written_.load(std::memory_order_relaxed);
        const uint64_t read = read_.load(std::memory_order_acquire);
        const size_t used = static_cast<size_t>(written - read);
        const size_t free = (capacity_ > used) ? (capacity_ - used) : 0;
        size_t n = (bytes < free) ? bytes : free;
        if (n == 0) {
            return 0;
        }

        // 分两段写（写到尾部再绕回开头）
        const size_t pos = static_cast<size_t>(written % capacity_);
        const size_t first = (capacity_ - pos < n) ? (capacity_ - pos) : n;
        memcpy(buffer_.data() + pos, data, first);
        if (n > first) {
            memcpy(buffer_.data(), data + first, n - first);
        }

        // release：保证上面的数据写入对消费者可见
        written_.store(written + n, std::memory_order_release);
        return n;
    }

    /**
     * 读取数据（仅消费者线程调用，即音频回调）
     * @param out 目标缓冲
     * @param bytes 期望字节数
     * @return 实际读到的字节数（不足即 underrun，调用方补静音）
     */
    size_t Read(uint8_t *out, size_t bytes) {
        const uint64_t read = read_.load(std::memory_order_relaxed);
        const uint64_t written = written_.load(std::memory_order_acquire);
        const size_t available = static_cast<size_t>(written - read);
        size_t n = (bytes < available) ? bytes : available;
        if (n == 0) {
            return 0;
        }

        const size_t pos = static_cast<size_t>(read % capacity_);
        const size_t first = (capacity_ - pos < n) ? (capacity_ - pos) : n;
        memcpy(out, buffer_.data() + pos, first);
        if (n > first) {
            memcpy(out + first, buffer_.data(), n - first);
        }

        read_.store(read + n, std::memory_order_release);
        return n;
    }

    /** 可读字节数（供 UI/日志观察缓冲深度） */
    size_t Available() const {
        const uint64_t written = written_.load(std::memory_order_acquire);
        const uint64_t read = read_.load(std::memory_order_acquire);
        return static_cast<size_t>(written - read);
    }

    /** 剩余空间 */
    size_t Free() const {
        const size_t used = Available();
        return (capacity_ > used) ? (capacity_ - used) : 0;
    }

    size_t Capacity() const { return capacity_; }

    /**
     * 清空
     * ★ 只能在生产者停止写入时调用（例如 seek 或释放），
     *   否则会和并发的 Write/Read 抢下标。实际用法是先丢弃剩余音频、
     *   再让解码线程重新填充。
     */
    void Clear() {
        const uint64_t written = written_.load(std::memory_order_acquire);
        read_.store(written, std::memory_order_release);
    }

private:
    const size_t capacity_;
    std::vector<uint8_t> buffer_;
    /** 单调递增的写下标（累计字节数，不回绕） */
    std::atomic<uint64_t> written_{0};
    /** 单调递增的读下标（累计字节数，不回绕） */
    std::atomic<uint64_t> read_{0};
};

}  // namespace softplayer

#endif  // SOFT_PLAYER_PCM_RING_BUFFER_H
