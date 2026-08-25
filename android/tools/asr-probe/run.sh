#!/bin/bash
#
# 主机端(mac)跑一遍**与 Android 侧同参数**的 whisper,把每个 token 的时刻打出来。
# **开发工具,不进任何 APK。**
#
# 为什么要有它:词级时间轴对不对,在真机上完全看不见中间值 —— 界面上只能看到"高亮不动"。
# 这条链上因此栽过两次(见 TROUBLESHOOTING H59、H60)。有了它,时间轴是对是错在终端里一眼看出,
# 改完立刻能验,不必先打包再装机。
#
# 用法:
#   ./run.sh <音频文件>            默认档:token_timestamps —— **与线上一致**
#   PROBE_DTW=1 ./run.sh <音频>    对照档:退回历史上的 DTW(flash attn 关)
#   PROBE_N=200 ./run.sh <音频>    多打几个 token
#
# 怎么判断时刻**是不是真的对**(切片法 —— 唯一可信的真相来源):
#   把音频截到某个时刻为止,看识别出来的字数停在哪里;或从某个时刻起截一小段,
#   看开头几个字是不是探针说的那几个。例:
#     ffmpeg -v error -y -ss 13.69 -t 2.2 -i 音频 -ar 16000 -ac 1 -c:a pcm_s16le /tmp/s.wav
#   探针说 13690ms 那个词是「找」,那么这一段的开头就该是「找到喜欢的…」。
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

AUDIO="${1:-$ROOT/../shared/guide/guide_intro.m4a}"
MODEL="$ROOT/app/src/default/assets/whisper-model.bin"
WH="$ROOT/asr-native/whisper.cpp"
BUILD=/tmp/wh-host

[ -f "$MODEL" ] || { echo "✗ 没有模型:$MODEL(先跑 tools/build-asr.sh)"; exit 1; }
[ -d "$WH" ] || { echo "✗ 没有 whisper.cpp 源码(先跑 tools/build-asr.sh)"; exit 1; }

# **不要用 PATH 上的 cmake**:那常常是 3.10,不支持 -S/-B(与 build-asr.sh 同一个坑)
CMAKE=$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/cmake/*/bin/cmake 2>/dev/null | sort -V | tail -1 || true)
[ -x "${CMAKE:-}" ] || { echo "✗ 找不到 Android SDK 自带的 cmake"; exit 1; }

if [ ! -f "$BUILD/src/libwhisper.a" ]; then
  echo "▸ 编译主机版 whisper(只做一次,约 1 分钟)"
  "$CMAKE" -S "$WH" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF \
    -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=OFF >/dev/null
  "$CMAKE" --build "$BUILD" -j8 --target whisper >/dev/null
fi

echo "▸ 编译探针"
clang++ -std=c++17 -O2 -I"$WH/include" -I"$WH/ggml/include" probe.cpp -o /tmp/asr-probe \
  "$BUILD/src/libwhisper.a" \
  "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/libggml-cpu.a" "$BUILD/ggml/src/libggml-base.a" \
  "$BUILD/ggml/src/ggml-blas/libggml-blas.a" \
  -framework Accelerate -framework Foundation

# 探针只认 16k 单声道 wav(解码不是它要测的东西,交给 ffmpeg)
WAV=/tmp/asr-probe-in.wav
echo "▸ 转 16k 单声道:$(basename "$AUDIO")"
ffmpeg -v error -y -i "$AUDIO" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV"

# 语言与提示词要**与线上一致**,否则量出来的偏差不是线上的偏差
# (提示词会让每块头几秒的时刻偏早,见 docs/TRANSCRIPT.md)
exec /tmp/asr-probe "$MODEL" "$WAV" zh "以下是普通话的句子。"
