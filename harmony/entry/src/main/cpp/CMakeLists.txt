# 余音 · 鸿蒙端 native 模块。目前只有一个:给系统语音识别喂 PCM 的音频解码器。
# 之所以要 native,见 reverb_pcm.cpp 顶部注释(ArkTS 层没有解封装/解码 API)。
cmake_minimum_required(VERSION 3.5.0)
project(reverb)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(reverb_pcm SHARED reverb_pcm.cpp)

target_link_libraries(reverb_pcm PUBLIC
    libace_napi.z.so          # NAPI
    libhilog_ndk.z.so         # 日志(OH_LOG_Print)
    libnative_media_codecbase.so
    libnative_media_avsource.so
    libnative_media_avdemuxer.so
    libnative_media_acodec.so  # 音频编解码(OH_AudioCodec_*)
    libnative_media_core.so    # OH_AVFormat / OH_AVBuffer
)
