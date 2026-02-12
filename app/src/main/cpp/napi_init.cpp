#include "napi/native_api.h"
#include "video_decoder_native.h"
#include "audio_decoder_native.h"
#include "video_stream_processor.h"
#include "native_buffer_pool.h"
#include <hilog/log.h>
#include <map>
#include <unordered_map>

// ============== Video Decoder ==============

static std::unordered_map<int64_t, VideoDecoderNative*> g_videoDecoders;
static int64_t g_nextVideoId = 1;

// 创建视频解码器
static napi_value CreateVideoDecoder(napi_env env, napi_callback_info info) {
    VideoDecoderNative* decoder = new VideoDecoderNative();
    int64_t decoderId = g_nextVideoId++;
    g_videoDecoders[decoderId] = decoder;

    napi_value result;
    napi_create_int64(env, decoderId, &result);
    return result;
}

// 初始化视频解码器 - 现在接受codecType字符串而不是useH265布尔值
static napi_value InitVideoDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 获取参数
    int64_t decoderId;
    char codecType[32];
    size_t codecTypeLen;
    char surfaceId[128];
    size_t surfaceIdLen;
    int32_t width, height;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_value_string_utf8(env, args[1], codecType, sizeof(codecType), &codecTypeLen);
    napi_get_value_string_utf8(env, args[2], surfaceId, sizeof(surfaceId), &surfaceIdLen);
    napi_get_value_int32(env, args[3], &width);
    napi_get_value_int32(env, args[4], &height);

    // 调用Native方法
    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        int32_t ret = it->second->Init(codecType, surfaceId, width, height);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 启动视频解码器
static napi_value StartVideoDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        int32_t ret = it->second->Start();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 推送视频数据
static napi_value PushVideoData(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    void* data;
    size_t dataSize;
    int64_t pts;
    uint32_t flags = 0;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);

    // Fast path: assume Number type (common case)
    napi_valuetype valueType;
    napi_typeof(env, args[2], &valueType);

    if (valueType == napi_bigint) {
        bool lossless;
        napi_get_value_bigint_int64(env, args[2], &pts, &lossless);
    } else {
        napi_get_value_int64(env, args[2], &pts);
    }

    // Get flags if provided
    if (argc > 3) {
        napi_typeof(env, args[3], &valueType);
        if (valueType == napi_number) {
            napi_get_value_uint32(env, args[3], &flags);
        }
    }

    // OH_LOG_DEBUG(LOG_APP, "[NAPI] PushVideoData: size=%{public}zu, pts=%{public}ld, flags=%{public}u", dataSize, (long)pts, flags);

    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        int32_t ret = it->second->PushData(static_cast<uint8_t*>(data), static_cast<int32_t>(dataSize), pts, flags);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 释放视频解码器
static napi_value ReleaseVideoDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        it->second->Release();
        delete it->second;
        g_videoDecoders.erase(it);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// ============== Audio Decoder ==============

static std::unordered_map<int64_t, AudioDecoderNative*> g_audioDecoders;
static int64_t g_nextAudioId = 1;

// 创建音频解码器
static napi_value CreateAudioDecoder(napi_env env, napi_callback_info info) {
    AudioDecoderNative* decoder = new AudioDecoderNative();
    int64_t decoderId = g_nextAudioId++;
    g_audioDecoders[decoderId] = decoder;

    napi_value result;
    napi_create_int64(env, decoderId, &result);
    return result;
}

// 初始化音频解码器
static napi_value InitAudioDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    char codecType[32];
    size_t codecTypeLen;
    int32_t sampleRate, channelCount;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_value_string_utf8(env, args[1], codecType, sizeof(codecType), &codecTypeLen);
    napi_get_value_int32(env, args[2], &sampleRate);
    napi_get_value_int32(env, args[3], &channelCount);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        int32_t ret = it->second->Init(codecType, sampleRate, channelCount);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 启动音频解码器
static napi_value StartAudioDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        int32_t ret = it->second->Start();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 推送音频数据
static napi_value PushAudioData(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    void* data;
    size_t dataSize;
    int64_t pts;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);
    napi_get_value_int64(env, args[2], &pts);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        int32_t ret = it->second->PushData(static_cast<uint8_t*>(data), static_cast<int32_t>(dataSize), pts);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 释放音频解码器
static napi_value ReleaseAudioDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        it->second->Release();
        delete it->second;
        g_audioDecoders.erase(it);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// ============== Video Stream Processor ==============

static std::unordered_map<int64_t, VideoStreamProcessor*> g_videoStreamProcessors;
static std::unordered_map<int64_t, VideoDecoderNative*> g_videoDecoderMap;  // Link decoder ID to native
static int64_t g_nextVideoProcessorId = 1;

// 创建视频流处理器
static napi_value CreateVideoStreamProcessor(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    char codecType[32];
    size_t codecTypeLen;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_value_string_utf8(env, args[1], codecType, sizeof(codecType), &codecTypeLen);

    // Get video decoder from map
    auto it = g_videoDecoders.find(decoderId);
    if (it == g_videoDecoders.end()) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] CreateVideoStreamProcessor: decoder %{public}lld not found", (long long)decoderId);
        napi_value result;
        napi_create_int64(env, -1, &result);
        return result;
    }

    // Create stream processor
    VideoStreamProcessor* processor = new VideoStreamProcessor();
    int64_t processorId = g_nextVideoProcessorId++;

    int32_t ret = processor->Init(VideoStreamProcessor::MediaType::VIDEO,
                                   it->second, codecType);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] CreateVideoStreamProcessor: init failed %{public}d", ret);
        delete processor;
        napi_value result;
        napi_create_int64(env, -1, &result);
        return result;
    }

    g_videoStreamProcessors[processorId] = processor;
    g_videoDecoderMap[processorId] = it->second;  // Keep reference to decoder

    napi_value result;
    napi_create_int64(env, processorId, &result);
    OH_LOG_INFO(LOG_APP, "[NAPI] VideoStreamProcessor created: %{public}lld", (long long)processorId);
    return result;
}

// 启动视频流处理器
static napi_value StartVideoStreamProcessor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t processorId;
    napi_get_value_int64(env, args[0], &processorId);

    auto it = g_videoStreamProcessors.find(processorId);
    if (it != g_videoStreamProcessors.end()) {
        int32_t ret = it->second->Start();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 推送数据到视频流处理器
static napi_value PushVideoStreamData(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t processorId;
    void* data;
    size_t dataSize;
    int64_t pts;
    uint32_t flags = 0;

    napi_get_value_int64(env, args[0], &processorId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);

    // Check PTS type (Number or BigInt)
    napi_valuetype valueType;
    napi_typeof(env, args[2], &valueType);

    if (valueType == napi_bigint) {
        bool lossless;
        napi_get_value_bigint_int64(env, args[2], &pts, &lossless);
    } else {
        napi_get_value_int64(env, args[2], &pts);
    }

    // Get flags if provided
    if (argc > 3) {
        napi_typeof(env, args[3], &valueType);
        if (valueType == napi_number) {
            napi_get_value_uint32(env, args[3], &flags);
        }
    }

    auto it = g_videoStreamProcessors.find(processorId);
    if (it != g_videoStreamProcessors.end()) {
        int32_t ret = it->second->PushData(static_cast<uint8_t*>(data),
                                            static_cast<int32_t>(dataSize),
                                            pts, flags);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 释放视频流处理器
static napi_value ReleaseVideoStreamProcessor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t processorId;
    napi_get_value_int64(env, args[0], &processorId);

    auto it = g_videoStreamProcessors.find(processorId);
    if (it != g_videoStreamProcessors.end()) {
        it->second->Release();
        delete it->second;
        g_videoStreamProcessors.erase(it);
        g_videoDecoderMap.erase(processorId);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// ============== Audio Stream Processor ==============

static std::unordered_map<int64_t, VideoStreamProcessor*> g_audioStreamProcessors;
static std::unordered_map<int64_t, AudioDecoderNative*> g_audioDecoderMap;
static int64_t g_nextAudioProcessorId = 1;

// 创建音频流处理器
static napi_value CreateAudioStreamProcessor(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    char codecType[32];
    size_t codecTypeLen;
    int32_t sampleRate, channelCount;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_value_string_utf8(env, args[1], codecType, sizeof(codecType), &codecTypeLen);
    napi_get_value_int32(env, args[2], &sampleRate);
    napi_get_value_int32(env, args[3], &channelCount);

    // Get audio decoder from map
    auto it = g_audioDecoders.find(decoderId);
    if (it == g_audioDecoders.end()) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] CreateAudioStreamProcessor: decoder %{public}lld not found", (long long)decoderId);
        napi_value result;
        napi_create_int64(env, -1, &result);
        return result;
    }

    // Create stream processor
    VideoStreamProcessor* processor = new VideoStreamProcessor();
    int64_t processorId = g_nextAudioProcessorId++;

    int32_t ret = processor->Init(VideoStreamProcessor::MediaType::AUDIO,
                                   it->second, codecType);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] CreateAudioStreamProcessor: init failed %{public}d", ret);
        delete processor;
        napi_value result;
        napi_create_int64(env, -1, &result);
        return result;
    }

    g_audioStreamProcessors[processorId] = processor;
    g_audioDecoderMap[processorId] = it->second;

    napi_value result;
    napi_create_int64(env, processorId, &result);
    OH_LOG_INFO(LOG_APP, "[NAPI] AudioStreamProcessor created: %{public}lld", (long long)processorId);
    return result;
}

// 启动音频流处理器
static napi_value StartAudioStreamProcessor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t processorId;
    napi_get_value_int64(env, args[0], &processorId);

    auto it = g_audioStreamProcessors.find(processorId);
    if (it != g_audioStreamProcessors.end()) {
        int32_t ret = it->second->Start();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 推送音频数据到流处理器
static napi_value PushAudioStreamData(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t processorId;
    void* data;
    size_t dataSize;
    int64_t pts;

    napi_get_value_int64(env, args[0], &processorId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);

    // Check PTS type (Number or BigInt)
    napi_valuetype valueType;
    napi_typeof(env, args[2], &valueType);

    if (valueType == napi_bigint) {
        bool lossless;
        napi_get_value_bigint_int64(env, args[2], &pts, &lossless);
    } else {
        napi_get_value_int64(env, args[2], &pts);
    }

    auto it = g_audioStreamProcessors.find(processorId);
    if (it != g_audioStreamProcessors.end()) {
        int32_t ret = it->second->PushData(static_cast<uint8_t*>(data),
                                            static_cast<int32_t>(dataSize),
                                            pts, 0);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 释放音频流处理器
static napi_value ReleaseAudioStreamProcessor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t processorId;
    napi_get_value_int64(env, args[0], &processorId);

    auto it = g_audioStreamProcessors.find(processorId);
    if (it != g_audioStreamProcessors.end()) {
        it->second->Release();
        delete it->second;
        g_audioStreamProcessors.erase(it);
        g_audioDecoderMap.erase(processorId);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// ============== Native Buffer Pool ==============

// GC finalize callback: 当 external ArrayBuffer 被回收时，归还 buffer 到池
static void NativeBufferFinalizeCallback(napi_env env, void* finalize_data, void* finalize_hint) {
    NativeBufferInfo* info = static_cast<NativeBufferInfo*>(finalize_hint);
    if (info != nullptr) {
        NativeBufferPool::GetInstance().Release(info->bufferId, info->ptr);
        delete info;
    }
}

// 分配 native buffer，返回 external ArrayBuffer
static napi_value AllocNativeBuffer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t requestedSize;
    napi_get_value_int64(env, args[0], &requestedSize);

    if (requestedSize <= 0) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    uint8_t* ptr = nullptr;
    size_t capacity = 0;
    int32_t bufferId = NativeBufferPool::GetInstance().Alloc(
        static_cast<size_t>(requestedSize), &ptr, &capacity);

    if (ptr == nullptr) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    // 创建 finalize info
    NativeBufferInfo* bufInfo = new NativeBufferInfo();
    bufInfo->bufferId = bufferId;
    bufInfo->ptr = ptr;

    // 用 napi_create_external_arraybuffer 包装 native 内存
    // 注意: 这里用 requestedSize 而非 capacity，让 ArkTS 看到精确大小
    napi_value arrayBuffer;
    napi_status status = napi_create_external_arraybuffer(
        env, ptr, static_cast<size_t>(requestedSize),
        NativeBufferFinalizeCallback, bufInfo, &arrayBuffer);

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] napi_create_external_arraybuffer failed");
        NativeBufferPool::GetInstance().Release(bufferId, ptr);
        delete bufInfo;
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    return arrayBuffer;
}

// 主动释放 native buffer（不等 GC）
// 注意：调用后 ArkTS 侧的 ArrayBuffer 仍然存在但底层内存已归还池，
//       后续不应再使用该 ArrayBuffer。
static napi_value ReleaseNativeBuffer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    void* data;
    size_t length;
    napi_status status = napi_get_arraybuffer_info(env, args[0], &data, &length);
    
    if (status == napi_ok && data != nullptr) {
        // 尝试归还到池
        bool released = NativeBufferPool::GetInstance().Release(static_cast<uint8_t*>(data));
        if (!released) {
            // OH_LOG_DEBUG(LOG_APP, "[NAPI] ReleaseNativeBuffer: buffer not in pool or already released");
        }
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// 销毁整个缓冲池
static napi_value DestroyBufferPool(napi_env env, napi_callback_info info) {
    NativeBufferPool::GetInstance().ReleaseAll();
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ============== Module Registration ==============

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        // 视频API
        {"createVideoDecoder", nullptr, CreateVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initVideoDecoder", nullptr, InitVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startVideoDecoder", nullptr, StartVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushVideoData", nullptr, PushVideoData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseVideoDecoder", nullptr, ReleaseVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 音频API
        {"createAudioDecoder", nullptr, CreateAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initAudioDecoder", nullptr, InitAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startAudioDecoder", nullptr, StartAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushAudioData", nullptr, PushAudioData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseAudioDecoder", nullptr, ReleaseAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 流处理器API（视频）
        {"createVideoStreamProcessor", nullptr, CreateVideoStreamProcessor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startVideoStreamProcessor", nullptr, StartVideoStreamProcessor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushVideoStreamData", nullptr, PushVideoStreamData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseVideoStreamProcessor", nullptr, ReleaseVideoStreamProcessor, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 流处理器API（音频）
        {"createAudioStreamProcessor", nullptr, CreateAudioStreamProcessor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startAudioStreamProcessor", nullptr, StartAudioStreamProcessor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushAudioStreamData", nullptr, PushAudioStreamData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseAudioStreamProcessor", nullptr, ReleaseAudioStreamProcessor, nullptr, nullptr, nullptr, napi_default, nullptr},
        // Native Buffer Pool API
        {"allocNativeBuffer", nullptr, AllocNativeBuffer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseNativeBuffer", nullptr, ReleaseNativeBuffer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroyBufferPool", nullptr, DestroyBufferPool, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "scrcpy_native",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterModule(void) {
    napi_module_register(&demoModule);
}
