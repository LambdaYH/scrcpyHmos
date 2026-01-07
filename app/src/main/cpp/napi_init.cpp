#include "napi/native_api.h"
#include "video_decoder_native.h"
#include <hilog/log.h>
#include <map>

static std::map<int64_t, VideoDecoderNative*> g_decoders;
static int64_t g_nextId = 1;

// 创建解码器
static napi_value CreateDecoder(napi_env env, napi_callback_info info) {
    VideoDecoderNative* decoder = new VideoDecoderNative();
    int64_t decoderId = g_nextId++;
    g_decoders[decoderId] = decoder;
    
    napi_value result;
    napi_create_int64(env, decoderId, &result);
    return result;
}

// 初始化解码器
static napi_value InitDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    // 获取参数
    int64_t decoderId;
    bool useH265;
    char surfaceId[128];
    size_t surfaceIdLen;
    int32_t width, height;
    
    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_value_bool(env, args[1], &useH265);
    napi_get_value_string_utf8(env, args[2], surfaceId, sizeof(surfaceId), &surfaceIdLen);
    napi_get_value_int32(env, args[3], &width);
    napi_get_value_int32(env, args[4], &height);
    
    // 调用Native方法
    auto it = g_decoders.find(decoderId);
    if (it != g_decoders.end()) {
        int32_t ret = it->second->Init(useH265, surfaceId, width, height);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }
    
    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 启动解码器
static napi_value StartDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);
    
    auto it = g_decoders.find(decoderId);
    if (it != g_decoders.end()) {
        int32_t ret = it->second->Start();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }
    
    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 推送数据
static napi_value PushData(napi_env env, napi_callback_info info) {
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
    
    auto it = g_decoders.find(decoderId);
    if (it != g_decoders.end()) {
        int32_t ret = it->second->PushData(static_cast<uint8_t*>(data), static_cast<int32_t>(dataSize), pts);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }
    
    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 释放解码器
static napi_value ReleaseDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);
    
    auto it = g_decoders.find(decoderId);
    if (it != g_decoders.end()) {
        it->second->Release();
        delete it->second;
        g_decoders.erase(it);
    }
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"createDecoder", nullptr, CreateDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initDecoder", nullptr, InitDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startDecoder", nullptr, StartDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushData", nullptr, PushData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseDecoder", nullptr, ReleaseDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
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
