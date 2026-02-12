#include "native_buffer_pool.h"
#include <hilog/log.h>
#include <cstring>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "NativeBufferPool"
#define LOG_DOMAIN 0x3200

// 单例实例
static NativeBufferPool* g_instance = nullptr;

NativeBufferPool& NativeBufferPool::GetInstance() {
    if (g_instance == nullptr) {
        g_instance = new NativeBufferPool();
    }
    return *g_instance;
}

NativeBufferPool::NativeBufferPool(int poolSize, size_t bufferSize)
    : destroyed_(false) {
    pool_.reserve(poolSize);
    for (int i = 0; i < poolSize; i++) {
        PoolEntry entry;
        entry.data = static_cast<uint8_t*>(malloc(bufferSize));
        entry.capacity = bufferSize;
        entry.inUse = false;
        if (entry.data != nullptr) {
            pool_.push_back(entry);
        } else {
            OH_LOG_ERROR(LOG_APP, "[NativeBufferPool] Failed to allocate pool entry %{public}d", i);
        }
    }
    OH_LOG_INFO(LOG_APP, "[NativeBufferPool] Initialized: %{public}zu entries x %{public}zu bytes = %{public}zu KB",
                pool_.size(), bufferSize, pool_.size() * bufferSize / 1024);
}

NativeBufferPool::~NativeBufferPool() {
    ReleaseAll();
}

int32_t NativeBufferPool::Alloc(size_t requestedSize, uint8_t** outPtr, size_t* outCapacity) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (destroyed_) {
        // Pool destroyed, fallback
        uint8_t* ptr = static_cast<uint8_t*>(malloc(requestedSize));
        if (ptr == nullptr) return -1;
        *outPtr = ptr;
        *outCapacity = requestedSize;
        return -1; // fallback ID
    }

    // 从池中查找空闲且容量足够的 buffer
    for (int32_t i = 0; i < static_cast<int32_t>(pool_.size()); i++) {
        if (!pool_[i].inUse && pool_[i].capacity >= requestedSize) {
            pool_[i].inUse = true;
            *outPtr = pool_[i].data;
            *outCapacity = pool_[i].capacity;
            return i;
        }
    }

    // 池中无合适 buffer，查找空闲但容量不足的，尝试 realloc
    for (int32_t i = 0; i < static_cast<int32_t>(pool_.size()); i++) {
        if (!pool_[i].inUse) {
            uint8_t* newData = static_cast<uint8_t*>(realloc(pool_[i].data, requestedSize));
            if (newData != nullptr) {
                pool_[i].data = newData;
                pool_[i].capacity = requestedSize;
                pool_[i].inUse = true;
                *outPtr = newData;
                *outCapacity = requestedSize;
                OH_LOG_INFO(LOG_APP, "[NativeBufferPool] Resized entry %{public}d to %{public}zu bytes",
                            i, requestedSize);
                return i;
            }
        }
    }

    // 池全部耗尽，fallback 到 malloc
    OH_LOG_WARN(LOG_APP, "[NativeBufferPool] Pool exhausted, fallback malloc %{public}zu bytes", requestedSize);
    uint8_t* ptr = static_cast<uint8_t*>(malloc(requestedSize));
    if (ptr == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[NativeBufferPool] Fallback malloc failed!");
        return -1;
    }
    *outPtr = ptr;
    *outCapacity = requestedSize;
    return -1; // fallback ID
}

void NativeBufferPool::Release(int32_t bufferId, uint8_t* ptr) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (bufferId >= 0 && bufferId < static_cast<int32_t>(pool_.size())) {
        // 池内 buffer，标记为空闲
        // 只有当指针匹配时才释放（避免 ID 错误或者已经 realloc）
        if (pool_[bufferId].data == ptr) {
            if (pool_[bufferId].inUse) {
                pool_[bufferId].inUse = false;
                // OH_LOG_DEBUG(LOG_APP, "[NativeBufferPool] Released buffer ID %{public}d", bufferId);
            }
        } else {
            // 指针不匹配，可能是 realloc 发生了变化或者 ID 错乱
            // 尝试全池扫描释放
            bool found = false;
            for (auto& entry : pool_) {
                if (entry.data == ptr) {
                    entry.inUse = false;
                    found = true;
                    break;
                }
            }
            if (!found && ptr != nullptr) {
                // 不在池中，可能是 fallback 分配的，free 掉
                free(ptr);
            }
        }
    } else {
        // Fallback or invalid ID
        // 如果 ptr 不为空，尝试在池中查找（防止 ID 错误）
        bool found = false;
        if (ptr != nullptr) {
             for (auto& entry : pool_) {
                if (entry.data == ptr) {
                    entry.inUse = false;
                    found = true;
                    break;
                }
            }
        }
        
        // 确实不在池中，free
        if (!found && ptr != nullptr) {
            free(ptr);
        }
    }
}

bool NativeBufferPool::Release(uint8_t* ptr) {
    if (ptr == nullptr) return false;
    std::lock_guard<std::mutex> lock(mutex_);

    for (int32_t i = 0; i < static_cast<int32_t>(pool_.size()); i++) {
        if (pool_[i].data == ptr) {
            if (pool_[i].inUse) {
                pool_[i].inUse = false;
                // OH_LOG_DEBUG(LOG_APP, "[NativeBufferPool] Manually released buffer ID %{public}d", i);
                return true;
            }
            return false; // Already free
        }
    }
    // Not in pool (fallback allocation), we don't handle manual free for fallback here
    // because we don't track them. Let GC finalize handle it.
    return false;
}

void NativeBufferPool::ReleaseAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    destroyed_ = true;
    for (auto& entry : pool_) {
        if (entry.data != nullptr) {
            free(entry.data);
            entry.data = nullptr;
        }
        entry.inUse = false;
    }
    pool_.clear();
    OH_LOG_INFO(LOG_APP, "[NativeBufferPool] All buffers released");
}
