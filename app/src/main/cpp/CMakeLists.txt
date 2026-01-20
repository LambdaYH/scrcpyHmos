cmake_minimum_required(VERSION 3.4.1)
project(scrcpy_native)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(scrcpy_native SHARED
    video_decoder_native.cpp
    audio_decoder_native.cpp
    napi_init.cpp
)

target_link_libraries(scrcpy_native PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_vdec.so
    libnative_media_acodec.so
    libnative_window.so
    libohaudio.so
)
