#ifndef NATIVE_BUFFER_POOL_H
#define NATIVE_BUFFER_POOL_H

#include <cstdint>
#include <cstdlib>
#include <vector>
#include <mutex>

/**
 * NativeBufferPool - 预分配 Native 内存池
 *
 * 用于视频帧缓冲区的零拷贝优化。
 * 预分配固定数量的大缓冲区，通过 napi_create_external_arraybuffer
 * 暴露给 ArkTS 层，避免每帧都在 JS 堆上分配内存。
 *
 * 生命周期：
 * - alloc: 从池中获取空闲 buffer，标记 inUse
 * - release: buffer 归还到池（由 GC finalize 回调或主动释放触发）
 * - 如果池耗尽，fallback 到动态 malloc
 */
class NativeBufferPool {
public:
    // poolSize: 池中 buffer 数量，bufferSize: 每个 buffer 的初始容量
    NativeBufferPool(int poolSize = 8, size_t bufferSize = 2 * 1024 * 1024);
    ~NativeBufferPool();

    /**
     * 从池中分配 buffer
     * @param requestedSize 请求的最小大小
     * @param outPtr 输出: buffer 指针
     * @param outCapacity 输出: buffer 实际容量
     * @return buffer ID (>=0 为池内 buffer, -1 为 fallback malloc)
     */
    int32_t Alloc(size_t requestedSize, uint8_t** outPtr, size_t* outCapacity);

    /**
     * 归还 buffer 到池（或 free fallback 分配的内存）
     * @param bufferId buffer ID
     * @param ptr buffer 指针（用于 fallback 场景的 free）
     */
    void Release(int32_t bufferId, uint8_t* ptr);

    /**
     * 通过指针归还 buffer（仅用于手动释放池内 buffer）
     * @param ptr buffer 指针
     * @return true 如果是指针属于池并成功释放，false 否则
     */
    bool Release(uint8_t* ptr);

    /**
     * 释放所有池内存
     */
    void ReleaseAll();

    /**
     * 获取单例
     */
    static NativeBufferPool& GetInstance();

private:
    struct PoolEntry {
        uint8_t* data;
        size_t capacity;
        bool inUse;
    };

    std::vector<PoolEntry> pool_;
    std::mutex mutex_;
    bool destroyed_;
};

// Finalize callback 的用户数据
struct NativeBufferInfo {
    int32_t bufferId;
    uint8_t* ptr;
};

#endif // NATIVE_BUFFER_POOL_H
