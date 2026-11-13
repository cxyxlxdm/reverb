#!/bin/bash
#
# 备齐**离线语音识别**所需的东西(都不入版本管理):
#
#   app/libs/sherpa-onnx.jar                                sherpa-onnx 2.0.1 的 Java API(约 240 KB)
#   app/src/main/jniLibs/arm64-v8a/libonnxruntime.so        ONNX Runtime(约 21 MB)
#   app/src/main/jniLibs/arm64-v8a/libsherpa-onnx-jni.so    sherpa-onnx 的 JNI 入口(约 4.4 MB)
#   app/src/main/assets/sensevoice/model.int8.onnx          SenseVoiceSmall int8(约 228 MB)
#   app/src/main/assets/sensevoice/tokens.txt               词表(约 0.3 MB)
#
# 用法:
#   ./tools/build-asr.sh          备齐(已存在且校验通过则跳过)
#   ./tools/build-asr.sh --force  强制重来
#
# 为什么不把产物提交进仓库:两百多 MB 的模型 + 二十多 MB 的 .so + 一个第三方 jar,
# 放进 git 会让仓库和每次打包的体量都难看,而它们完全可以由这个脚本一条命令重建。
# **任何一次发布构建都要先跑本脚本**,build-release.sh 会检查它们在不在,缺了直接报错退出。
#
# 引擎换成 sherpa-onnx + SenseVoice 的理由与实测数据在
# docs/research/2026-11-11-offline-asr-engine.md;旧的 whisper.cpp 版本(以及 `asr-native/`
# 那套 JNI 胶水)在 1.0.8 被整体替换,不再需要 NDK / cmake / 克隆源码 ——
# 上游把 arm64 的 .so 与 Java API 都预编译在 AAR 里了。
#
# 为什么固定 2.0.1:sherpa-onnx 的 API 与模型格式都在演进,浮动跟主线会某天突然行为变了。
# 要升级就改下面的版本号与 sha256,然后**重新在真机上量一遍**速度与识别质量(见 TROUBLESHOOTING)。
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

SHERPA_VERSION=2.0.1
AAR_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/sherpa-onnx-${SHERPA_VERSION}.aar"
AAR_SHA=a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7

# 模型:SenseVoiceSmall int8。选它的依据是主机端 + 3 分钟真实中文播客的实测:
# 中文明显比 whisper base-q5_1 准(同音字/断句/标点),还快得多;代价是只认
# zh/en/ja/ko/yue 五种语言,模型体积大一个量级。别凭感觉换。
# 优先走 hf-mirror(GitHub Releases 在大陆经常只有几十 KB/s),可用 ASR_MODEL_HOST 覆盖。
MODEL_HOST="${ASR_MODEL_HOST:-https://hf-mirror.com}"
MODEL_REPO="csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
MODEL_URL="$MODEL_HOST/$MODEL_REPO/resolve/main/model.int8.onnx"
TOKENS_URL="$MODEL_HOST/$MODEL_REPO/resolve/main/tokens.txt"
MODEL_SHA=c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51
TOKENS_SHA=f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

CACHE="$ROOT/.asr-cache"
AAR="$CACHE/sherpa-onnx-${SHERPA_VERSION}.aar"
JAR_OUT="$ROOT/app/libs/sherpa-onnx.jar"
JNI_DIR="$ROOT/app/src/main/jniLibs/arm64-v8a"
ASSET_DIR="$ROOT/app/src/main/assets/sensevoice"
MODEL_OUT="$ASSET_DIR/model.int8.onnx"
TOKENS_OUT="$ASSET_DIR/tokens.txt"

# 旧版(whisper)的产物:**必须删掉**,否则 57 MB 的模型与 1.6 MB 的 .so 会继续被打进包,
# 而代码早就改用新引擎了 —— 包体积和「包里有什么」两边都失真(硬规矩 1)。
rm -f "$ROOT/app/src/main/assets/whisper-model.bin" "$JNI_DIR/libreverb_asr.so"

check_sha() {   # check_sha <文件> <期望值>
  local actual
  actual=$(shasum -a 256 "$1" | cut -d' ' -f1)
  if [ "$actual" != "$2" ]; then
    echo "⚠ $(basename "$1") 的 sha256 与脚本记录不一致"
    echo "  记录 ${2:0:12}…,实际 ${actual:0:12}…"
    echo "  若确认无误,请把脚本里对应的 SHA 更新为实际值。"
  fi
}

# ── 1. AAR(Java API + arm64 原生库)──
mkdir -p "$CACHE" "$(dirname "$JAR_OUT")" "$JNI_DIR"
if [ $FORCE -eq 1 ] || [ ! -f "$AAR" ]; then
  echo "▸ 下载 sherpa-onnx ${SHERPA_VERSION} AAR(约 49 MB)"
  curl -fL --progress-bar -o "$AAR.part" "$AAR_URL"
  mv "$AAR.part" "$AAR"
else
  echo "▸ AAR 已在,跳过($(du -h "$AAR" | cut -f1))"
fi
check_sha "$AAR" "$AAR_SHA"

# classes.jar 就是那份 Java/Kotlin API。**只抽这两份 .so**:
# - libsherpa-onnx-jni.so 是 System.loadLibrary("sherpa-onnx-jni") 的入口,
#   它已经静态链了 sherpa 本体(实测 NEEDED 里没有 c-api / cxx-api);
# - libonnxruntime.so 是它唯一的外部依赖。
# AAR 里那两份 c-api / cxx-api 用不到,不抽 —— 少 4.5 MB。
echo "▸ 解出 Java API 与 arm64 原生库"
unzip -p "$AAR" classes.jar > "$JAR_OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unzip -q -o "$AAR" 'jni/arm64-v8a/*' -d "$TMP"
cp "$TMP/jni/arm64-v8a/libonnxruntime.so" "$JNI_DIR/"
cp "$TMP/jni/arm64-v8a/libsherpa-onnx-jni.so" "$JNI_DIR/"

# ── 2. 模型与词表 ──
mkdir -p "$ASSET_DIR"
fetch() {   # fetch <url> <out> <sha> <说明>
  if [ $FORCE -eq 1 ] || [ ! -f "$2" ]; then
    echo "▸ 下载$4"
    curl -fL --progress-bar -o "$2.part" "$1"
    mv "$2.part" "$2"
    check_sha "$2" "$3"
  else
    echo "▸ $4已在,跳过($(du -h "$2" | cut -f1))"
  fi
}
fetch "$MODEL_URL" "$MODEL_OUT" "$MODEL_SHA" " SenseVoiceSmall int8 模型(约 228 MB)"
fetch "$TOKENS_URL" "$TOKENS_OUT" "$TOKENS_SHA" "词表"

echo "✓ $JAR_OUT ($(du -h "$JAR_OUT" | cut -f1))"
echo "✓ $JNI_DIR/libonnxruntime.so ($(du -h "$JNI_DIR/libonnxruntime.so" | cut -f1))"
echo "✓ $JNI_DIR/libsherpa-onnx-jni.so ($(du -h "$JNI_DIR/libsherpa-onnx-jni.so" | cut -f1))"
echo "✓ $MODEL_OUT ($(du -h "$MODEL_OUT" | cut -f1))"
echo "✓ $TOKENS_OUT ($(du -h "$TOKENS_OUT" | cut -f1))"
echo
echo "  只有 arm64-v8a:armeabi-v7a 的机器跑不动这个模型,给了也是让人干等。"
echo "  带上这些东西之后那份包会从约 4 MB 涨到约 270 MB —— 体积换本地识别质量,"
echo "  取舍与实测数据见 docs/research/2026-11-11-offline-asr-engine.md。"
