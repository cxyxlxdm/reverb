#
# 余音 · 离线语音识别 native 层。**不由 AGP 构建**,由 tools/build-asr.sh 单独调用。
#
# 为什么不挂进 AGP 的 externalNativeBuild:那个配置是**全局**的,没法"只给默认渠道构建"。
# 而大陆商店渠道必须做到包里连 .so 都没有(见 playback/asr/AsrEngine 的注释与
# TROUBLESHOOTING H54)。产物直接落到 app/src/default/jniLibs/,靠 source set 隔离。
#
# 副作用是好的:商店渠道的构建完全不碰 NDK,和现在一样快。
#
cmake_minimum_required(VERSION 3.22)
project(reverb_asr CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# whisper.cpp 由构建脚本按固定 commit 取到这里(该目录不入版本管理)
set(WHISPER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp" CACHE PATH "whisper.cpp source")

set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
# NDK 里没有可用的 OpenMP,开着会链接失败
set(GGML_OPENMP            OFF CACHE BOOL "" FORCE)

add_subdirectory(${WHISPER_DIR} whisper_build EXCLUDE_FROM_ALL)

add_library(reverb_asr SHARED reverb_asr.cpp)
target_link_libraries(reverb_asr PRIVATE whisper log)

# 体积:把静态链进来的 whisper/ggml 的符号都藏掉,只留 JNI 入口
target_link_options(reverb_asr PRIVATE
    -Wl,--exclude-libs,ALL
    -Wl,--gc-sections
    -Wl,-s)
target_compile_options(reverb_asr PRIVATE -ffunction-sections -fdata-sections -O3)
