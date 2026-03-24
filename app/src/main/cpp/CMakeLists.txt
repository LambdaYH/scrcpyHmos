cmake_minimum_required(VERSION 3.5.0)
project(scrcpy_native)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH} ${NATIVERENDER_ROOT_PATH}/thirdparty)

add_library(scrcpy_native SHARED
    decoder/VideoDecoderNative.cpp
    decoder/AudioDecoderNative.cpp

    manager/ScrcpyStreamManager.cpp
    manager/ScrcpyStreamManagerLifecycle.cpp
    manager/ScrcpyStreamManagerVideo.cpp
    manager/ScrcpyStreamManagerAudio.cpp
    manager/ScrcpyStreamManagerControl.cpp
    manager/ScrcpyStreamManagerReverse.cpp
    stream/adapters/ForwardStreamAdapter.cpp
    stream/adapters/ReverseStreamAdapter.cpp
    stream/StreamIO.cpp
    stream/StreamStats.cpp
    adb/AdbProtocol.cpp
    adb/AdbBase64.cpp
    adb/LocalSocketChannel.cpp
    adb/TcpChannel.cpp
    adb/AdbKeyPair.cpp
    adb/Adb.cpp
    napi_init.cpp
)

target_link_libraries(scrcpy_native PUBLIC
    libace_ndk.z.so
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_vdec.so
    libnative_media_acodec.so
    libnative_window.so
    libohaudio.so
    libohcrypto.so
)

