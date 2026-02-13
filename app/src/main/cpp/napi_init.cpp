#include "napi/native_api.h"
#include "video_decoder_native.h"
#include "audio_decoder_native.h"


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





// ============== ADB Module ==============

#include "adb/Adb.h"
#include "adb/AdbKeyPair.h"

static std::unordered_map<int64_t, Adb*> g_adbInstances;
static int64_t g_nextAdbId = 1;

// 创建ADB实例 - adbCreate(ip, port) => adbId
// 异步任务上下文
struct AdbCreateContext {
    napi_async_work work;
    napi_deferred deferred;
    napi_ref callbackRef = nullptr;
    
    std::string ip;
    int32_t port;
    int64_t resultAdbId = -1;
    bool success = false;
    std::string errorMsg;
};

// 异步执行函数 (后台线程)
static void ExecuteAdbCreate(napi_env env, void* data) {
    AdbCreateContext* context = static_cast<AdbCreateContext*>(data);
    try {
        Adb* adb = Adb::create(context->ip, context->port);
        if (adb) {
            // 注意: 这里不能直接操作 g_adbInstances，因为它是全局的且非线程安全的
            // 我们只在 Execute 中创建对象，Id 分配和 Map 插入放到 Complete (主线程) 中
            // 但我们需要把 adb 指针传回去。
            // 实际上 g_nextAdbId 也应该在主线程访问。
            // 所以这里只负责 new Adb
            // 为了传递指针，我们将 Adb* 类型转换存入 resultAdbId (虽然 hacky，但这里我们用一个临时成员变量吧)
            // wait, context struct is ours to define. Let's add Adb* adbInstance to it.
            // But I cannot change the struct definition easily in this replace block without seeing it.
            // So I will just cast the pointer to int64_t for storage if needed, OR better:
            // I defined the struct above. I can add members!
            context->success = true;
            // Hack: Store pointer in resultAdbId temporarily? No, resultAdbId is int64.
            // Let's redefine struct properly.
        } else {
            context->success = false;
            context->errorMsg = "Adb::create returned nullptr";
        }
        // Wait, I need to store the `adb` pointer.
        // I will re-declare the struct with `Adb* adbInstance` below.
    } catch (const std::exception& e) {
        context->success = false;
        context->errorMsg = e.what();
    }
}

// 重新定义 Context 包含 Adb指针
struct AdbCreateContextFull {
    napi_async_work work;
    napi_deferred deferred;
    napi_ref callbackRef = nullptr;
    
    std::string ip;
    int32_t port;
    
    Adb* adbInstance = nullptr; // Created in BG
    int64_t resultAdbId = -1;
    bool success = false;
    std::string errorMsg;
};

static void ExecuteAdbCreateFull(napi_env env, void* data) {
    AdbCreateContextFull* context = static_cast<AdbCreateContextFull*>(data);
    try {
        context->adbInstance = Adb::create(context->ip, context->port);
        if (context->adbInstance) {
            context->success = true;
        } else {
            context->success = false;
            context->errorMsg = "Adb::create returned nullptr";
        }
    } catch (const std::exception& e) {
        context->success = false;
        context->errorMsg = e.what();
    }
}

// 异步完成函数 (主线程)
static void CompleteAdbCreateFull(napi_env env, napi_status status, void* data) {
    AdbCreateContextFull* context = static_cast<AdbCreateContextFull*>(data);
    napi_value result;

    if (context->success && context->adbInstance) {
        int64_t adbId = g_nextAdbId++;
        g_adbInstances[adbId] = context->adbInstance;
        napi_create_int64(env, adbId, &result);
        
        OH_LOG_INFO(LOG_APP, "[NAPI] AdbCreate success: id=%{public}lld, ip=%{public}s, port=%{public}d",
                    (long long)adbId, context->ip.c_str(), context->port);
        
        napi_resolve_deferred(env, context->deferred, result);
    } else {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbCreate failed: %{public}s", context->errorMsg.c_str());
        napi_create_int64(env, -1, &result);
        // Resolve with -1 instead of reject to maintain simpler logic on TS side (or reject?)
        // The original sync code returned -1. Let's resolve with -1.
        napi_resolve_deferred(env, context->deferred, result);
    }

    napi_delete_async_work(env, context->work);
    delete context;
}

// 创建ADB实例 - adbCreate(ip, port) => Promise<number>
static napi_value AdbCreate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char ip[64];
    size_t ipLen;
    int32_t port;

    napi_get_value_string_utf8(env, args[0], ip, sizeof(ip), &ipLen);
    napi_get_value_int32(env, args[1], &port);

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbCreate", NAPI_AUTO_LENGTH, &resourceName);

    AdbCreateContextFull* context = new AdbCreateContextFull();
    context->ip = ip;
    context->port = port;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        ExecuteAdbCreateFull,
        CompleteAdbCreateFull,
        (void*)context,
        &context->work
    );

    napi_queue_async_work(env, context->work);

    return promise;
}

// 异步连接上下文
// 异步连接上下文
struct AdbConnectContext {
    napi_async_work work;
    napi_deferred deferred;
    
    int64_t adbId;
    std::string pubKeyPath;
    std::string priKeyPath;
    
    Adb* adbInstance = nullptr;

    int32_t result = -1;
    bool success = false;
    std::string errorMsg;
    
    napi_threadsafe_function tsfn = nullptr;
};

static void ExecuteAdbConnect(napi_env env, void* data) {
    AdbConnectContext* context = static_cast<AdbConnectContext*>(data);
    if (!context->adbInstance) {
        context->success = false;
        context->errorMsg = "Adb instance not found or invalid";
        return;
    }

    try {
        AdbKeyPair keyPair = AdbKeyPair::read(context->pubKeyPath, context->priKeyPath);
        
        auto onWaitAuth = [context]() {
            if (context->tsfn) {
                // 回调到主线程
                napi_call_threadsafe_function(context->tsfn, nullptr, napi_tsfn_blocking);
            }
        };

        context->result = context->adbInstance->connect(keyPair, onWaitAuth);
        context->success = true;
    } catch (const std::exception& e) {
        context->success = false;
        context->errorMsg = e.what();
    }
}

static void CompleteAdbConnect(napi_env env, napi_status status, void* data) {
    AdbConnectContext* context = static_cast<AdbConnectContext*>(data);
    napi_value result;

    if (context->success) {
        napi_create_int32(env, context->result, &result);
        napi_resolve_deferred(env, context->deferred, result);
    } else {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbConnect failed: %{public}s", context->errorMsg.c_str());
        napi_create_int32(env, -1, &result);
        napi_resolve_deferred(env, context->deferred, result);
    }

    if (context->tsfn) {
        napi_release_threadsafe_function(context->tsfn, napi_tsfn_release);
        context->tsfn = nullptr;
    }

    napi_delete_async_work(env, context->work);
    delete context;
}

// ADB连接认证 - adbConnect(adbId, pubKeyPath, priKeyPath, onWaitAuthCallback?) => Promise<number>
static napi_value AdbConnect(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char pubKeyPath[512];
    char priKeyPath[512];
    size_t pubLen;
    size_t priLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], pubKeyPath, sizeof(pubKeyPath), &pubLen);
    napi_get_value_string_utf8(env, args[2], priKeyPath, sizeof(priKeyPath), &priLen);

    // 查找 ADB 实例 (在主线程进行)
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbConnect", NAPI_AUTO_LENGTH, &resourceName);

    AdbConnectContext* context = new AdbConnectContext();
    context->adbId = adbId;
    context->pubKeyPath = pubKeyPath;
    context->priKeyPath = priKeyPath;
    context->adbInstance = it->second;

    // Check for optional callback
    if (argc >= 4) {
        napi_valuetype type;
        napi_typeof(env, args[3], &type);
        if (type == napi_function) {
            napi_create_threadsafe_function(env, args[3], nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr, nullptr, &context->tsfn);
        }
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        ExecuteAdbConnect,
        CompleteAdbConnect,
        (void*)context,
        &context->work
    );

    napi_queue_async_work(env, context->work);

    return promise;
}

// 执行ADB命令 - adbRunCmd(adbId, cmd) => string
static napi_value AdbRunCmd(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char cmd[4096];
    size_t cmdLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], cmd, sizeof(cmd), &cmdLen);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_string_utf8(env, "", 0, &result);
        return result;
    }

    try {
        std::string output = it->second->runAdbCmd(cmd);
        napi_create_string_utf8(env, output.c_str(), output.size(), &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbRunCmd failed: %{public}s", e.what());
        napi_create_string_utf8(env, "", 0, &result);
    }
    return result;
}

// 推送文件 - adbPushFile(adbId, data, remotePath) => void
static napi_value AdbPushFile(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    void* data;
    size_t dataSize;
    char remotePath[1024];
    size_t pathLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);
    napi_get_value_string_utf8(env, args[2], remotePath, sizeof(remotePath), &pathLen);

    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        try {
            it->second->pushFile(static_cast<uint8_t*>(data), dataSize, remotePath);
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "[NAPI] AdbPushFile failed: %{public}s", e.what());
        }
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// TCP端口转发 - adbTcpForward(adbId, port) => streamId
static napi_value AdbTcpForward(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t port;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &port);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_int32(env, -1, &result);
        return result;
    }

    try {
        int32_t streamId = it->second->tcpForward(port);
        napi_create_int32(env, streamId, &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbTcpForward failed: %{public}s", e.what());
        napi_create_int32(env, -1, &result);
    }
    return result;
}

// 本地Socket转发 - adbLocalSocketForward(adbId, socketName) => streamId
static napi_value AdbLocalSocketForward(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char socketName[256];
    size_t nameLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], socketName, sizeof(socketName), &nameLen);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_int32(env, -1, &result);
        return result;
    }

    try {
        int32_t streamId = it->second->localSocketForward(socketName);
        napi_create_int32(env, streamId, &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbLocalSocketForward failed: %{public}s", e.what());
        napi_create_int32(env, -1, &result);
    }
    return result;
}

// 从流读取 - adbStreamRead(adbId, streamId, size) => ArrayBuffer
static napi_value AdbStreamRead(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId, size;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);
    napi_get_value_int32(env, args[2], &size);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        void* buf;
        napi_create_arraybuffer(env, 0, &buf, &result);
        return result;
    }

    try {
        // Use non-blocking read (timeout=0, exact=false) to avoid freezing UI
        auto data = it->second->streamRead(streamId, static_cast<size_t>(size), 0, false);

        void* buf;
        napi_create_arraybuffer(env, data.size(), &buf, &result);
        if (!data.empty()) {
            std::memcpy(buf, data.data(), data.size());
        }
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbStreamRead failed: %{public}s", e.what());
        void* buf;
        napi_create_arraybuffer(env, 0, &buf, &result);
    }
    return result;
}

// 向流写入 - adbStreamWrite(adbId, streamId, data)
static napi_value AdbStreamWrite(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId;
    void* data;
    size_t dataSize;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);
    napi_get_arraybuffer_info(env, args[2], &data, &dataSize);

    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        try {
            it->second->streamWrite(streamId, static_cast<uint8_t*>(data), dataSize);
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "[NAPI] AdbStreamWrite failed: %{public}s", e.what());
        }
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 关闭流 - adbStreamClose(adbId, streamId)
static napi_value AdbStreamClose(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);

    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        it->second->streamClose(streamId);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 关闭ADB - adbClose(adbId)
static napi_value AdbClose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    napi_get_value_int64(env, args[0], &adbId);

    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        it->second->close();
        delete it->second;
        g_adbInstances.erase(it);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 生成密钥对 - adbGenerateKeyPair(pubKeyPath, priKeyPath)
static napi_value AdbGenerateKeyPair(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char pubKeyPath[512], priKeyPath[512];
    size_t pubLen, priLen;

    napi_get_value_string_utf8(env, args[0], pubKeyPath, sizeof(pubKeyPath), &pubLen);
    napi_get_value_string_utf8(env, args[1], priKeyPath, sizeof(priKeyPath), &priLen);

    napi_value result;
    try {
        AdbKeyPair::generate(pubKeyPath, priKeyPath);
        napi_create_int32(env, 0, &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbGenerateKeyPair failed: %{public}s", e.what());
        napi_create_int32(env, -1, &result);
    }
    return result;
}

// 检查ADB是否已连接 - adbIsConnected(adbId) => bool
static napi_value AdbIsConnected(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    napi_get_value_int64(env, args[0], &adbId);

    bool connected = false;
    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        connected = !it->second->isAdbClosed();
    }

    napi_value result;
    napi_get_boolean(env, connected, &result);
    return result;
}

// 获取Shell - adbGetShell(adbId) => streamId
static napi_value AdbGetShell(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    napi_get_value_int64(env, args[0], &adbId);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_int32(env, -1, &result);
        return result;
    }

    try {
        int32_t streamId = it->second->getShell();
        napi_create_int32(env, streamId, &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbGetShell failed: %{public}s", e.what());
        napi_create_int32(env, -1, &result);
    }
    return result;
}

// 切换TCP模式 - adbRestartOnTcpip(adbId, port) => string
static napi_value AdbRestartOnTcpip(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t port;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &port);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_string_utf8(env, "", 0, &result);
        return result;
    }

    try {
        std::string output = it->second->restartOnTcpip(port);
        napi_create_string_utf8(env, output.c_str(), output.size(), &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbRestartOnTcpip failed: %{public}s", e.what());
        napi_create_string_utf8(env, "", 0, &result);
    }
    return result;
}

// 流是否已关闭 - adbIsStreamClosed(adbId, streamId) => bool
static napi_value AdbIsStreamClosed(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);

    bool closed = true;
    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        closed = it->second->isStreamClosed(streamId);
    }

    napi_value result;
    napi_get_boolean(env, closed, &result);
    return result;
}

// ============== ScrcpyStreamManager Module ==============

#include "ScrcpyStreamManager.h"

static ScrcpyStreamManager* g_streamManager = nullptr;
static napi_threadsafe_function g_streamCallback = nullptr;

// 事件数据结构（传给 threadsafe function）
struct StreamEventData {
    std::string type;
    std::string data;
};

// JS 侧执行的回调函数
static void StreamEventCallToJS(napi_env env, napi_value jsCb, void* context, void* data) {
    StreamEventData* eventData = static_cast<StreamEventData*>(data);
    if (!eventData || !env || !jsCb) {
        delete eventData;
        return;
    }

    napi_value argv[2];
    napi_create_string_utf8(env, eventData->type.c_str(), eventData->type.size(), &argv[0]);
    napi_create_string_utf8(env, eventData->data.c_str(), eventData->data.size(), &argv[1]);

    napi_value global;
    napi_get_global(env, &global);
    napi_call_function(env, global, jsCb, 2, argv, nullptr);

    delete eventData;
}

// nativeStartStreams(adbId, videoStreamId, audioStreamId, controlStreamId,
//                   surfaceId, videoWidth, videoHeight,
//                   audioSampleRate, audioChannelCount, callback)
static napi_value NativeStartStreams(napi_env env, napi_callback_info info) {
    size_t argc = 10;
    napi_value args[10];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t videoStreamId, audioStreamId, controlStreamId;
    char surfaceId[128];
    size_t surfaceIdLen;
    int32_t videoWidth, videoHeight;
    int32_t audioSampleRate, audioChannelCount;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &videoStreamId);
    napi_get_value_int32(env, args[2], &audioStreamId);
    napi_get_value_int32(env, args[3], &controlStreamId);
    napi_get_value_string_utf8(env, args[4], surfaceId, sizeof(surfaceId), &surfaceIdLen);
    napi_get_value_int32(env, args[5], &videoWidth);
    napi_get_value_int32(env, args[6], &videoHeight);
    napi_get_value_int32(env, args[7], &audioSampleRate);
    napi_get_value_int32(env, args[8], &audioChannelCount);

    // 创建 threadsafe function
    napi_value callbackName;
    napi_create_string_utf8(env, "streamCallback", NAPI_AUTO_LENGTH, &callbackName);

    if (g_streamCallback) {
        napi_release_threadsafe_function(g_streamCallback, napi_tsfn_abort);
        g_streamCallback = nullptr;
    }

    napi_status status = napi_create_threadsafe_function(
        env, args[9], nullptr, callbackName,
        64, // max queue size
        1,  // initial thread count
        nullptr, nullptr, nullptr,
        StreamEventCallToJS,
        &g_streamCallback
    );

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] Failed to create threadsafe function");
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    // 查找 ADB 实例
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] ADB instance not found: %{public}lld", (long long)adbId);
        napi_value result;
        napi_create_int32(env, -2, &result);
        return result;
    }

    // 清理旧的 stream manager
    if (g_streamManager) {
        g_streamManager->stop();
        delete g_streamManager;
        g_streamManager = nullptr;
    }

    // 配置
    ScrcpyStreamManager::Config config;
    config.videoStreamId = videoStreamId;
    config.audioStreamId = audioStreamId;
    config.controlStreamId = controlStreamId;
    config.surfaceId = surfaceId;
    config.videoWidth = videoWidth;
    config.videoHeight = videoHeight;
    config.audioSampleRate = audioSampleRate;
    config.audioChannelCount = audioChannelCount;

    // 创建并启动
    g_streamManager = new ScrcpyStreamManager();

    napi_threadsafe_function tsfn = g_streamCallback;
    auto eventCallback = [tsfn](const std::string& type, const std::string& data) {
        StreamEventData* eventData = new StreamEventData{type, data};
        napi_call_threadsafe_function(tsfn, eventData, napi_tsfn_nonblocking);
    };

    int32_t ret = g_streamManager->start(it->second, config, eventCallback);

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

// nativeStopStreams()
static napi_value NativeStopStreams(napi_env env, napi_callback_info info) {
    if (g_streamManager) {
        g_streamManager->stop();
        delete g_streamManager;
        g_streamManager = nullptr;
    }

    if (g_streamCallback) {
        napi_release_threadsafe_function(g_streamCallback, napi_tsfn_release);
        g_streamCallback = nullptr;
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// nativeSendControl(data: ArrayBuffer)
static napi_value NativeSendControl(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    void* data;
    size_t dataSize;
    napi_get_arraybuffer_info(env, args[0], &data, &dataSize);

    if (g_streamManager && dataSize > 0) {
        g_streamManager->sendControl(static_cast<uint8_t*>(data), dataSize);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
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

        // Native Buffer

        // ADB API
        {"adbCreate", nullptr, AdbCreate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbConnect", nullptr, AdbConnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbRunCmd", nullptr, AdbRunCmd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbPushFile", nullptr, AdbPushFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbTcpForward", nullptr, AdbTcpForward, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbLocalSocketForward", nullptr, AdbLocalSocketForward, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbGetShell", nullptr, AdbGetShell, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbRestartOnTcpip", nullptr, AdbRestartOnTcpip, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbStreamRead", nullptr, AdbStreamRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbStreamWrite", nullptr, AdbStreamWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbStreamClose", nullptr, AdbStreamClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbIsStreamClosed", nullptr, AdbIsStreamClosed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbClose", nullptr, AdbClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbGenerateKeyPair", nullptr, AdbGenerateKeyPair, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbIsConnected", nullptr, AdbIsConnected, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Stream Manager API
        {"nativeStartStreams", nullptr, NativeStartStreams, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeStopStreams", nullptr, NativeStopStreams, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeSendControl", nullptr, NativeSendControl, nullptr, nullptr, nullptr, napi_default, nullptr},
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

