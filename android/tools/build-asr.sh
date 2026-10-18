#!/bin/bash
#
# 备齐**离线语音识别**所需的两样东西(都不入版本管理):
#
#   app/src/main/jniLibs/arm64-v8a/libreverb_asr.so   whisper.cpp + JNI 胶水
#   app/src/main/assets/whisper-model.bin             ggml-base-q5_1(约 57 MB)
#
# 用法:
#   ./tools/build-asr.sh          备齐(已存在且校验通过则跳过)
#   ./tools/build-asr.sh --force  强制重来
#
# 为什么不把产物提交进仓库:一个 57 MB 的模型 + 一个二进制 .so,放进 git 会让仓库和
# 每次打包的体量都难看,而它们完全可以由这个脚本一条命令重建。
# 2026-10-18 之前这两样放在 src/default/(只有自分发渠道带引擎);两个 flavor 合并成
# 一份包后挪进 src/main/,于是**任何一次发布构建都要先跑本脚本**,build-release.sh
# 会检查它们在不在,缺了直接报错退出(见 H205)。
#
# 为什么固定 commit:whisper.cpp 的 API 与 ggml 后端改得很勤,浮动跟主线会某天突然编不过
# 或行为变了。要升级就改下面这行,然后**重新在真机上量一遍速度**(见 TROUBLESHOOTING)。
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

WHISPER_REPO=https://github.com/ggml-org/whisper.cpp
WHISPER_COMMIT=233fe1fc9b48a09e361d3594520838ca266537fe   # 2026-08-22

# 模型:base-q5_1。选它的依据是真机实测,别凭感觉换 —— tiny 快一倍但中文错得明显
# (「你迷迷糊糊地起床」→「明明忽悔的汽床」),base 的错基本只剩同音词。
MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin
MODEL_SHA=422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898

NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/ndk}"
SDK_ROOT="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

SO_OUT="$ROOT/app/src/main/jniLibs/arm64-v8a/libreverb_asr.so"
MODEL_OUT="$ROOT/app/src/main/assets/whisper-model.bin"

# ── 1. 模型 ──
mkdir -p "$(dirname "$MODEL_OUT")"
if [ $FORCE -eq 1 ] || [ ! -f "$MODEL_OUT" ]; then
  echo "▸ 下载模型(约 57 MB)"
  curl -fL --progress-bar -o "$MODEL_OUT.part" "$MODEL_URL"
  mv "$MODEL_OUT.part" "$MODEL_OUT"
else
  echo "▸ 模型已在,跳过($(du -h "$MODEL_OUT" | cut -f1))"
fi
# 校验只作提示:上游偶尔会重新生成同名文件,硬失败会把人挡在门外
ACTUAL=$(shasum -a 256 "$MODEL_OUT" | cut -d' ' -f1)
if [ "$ACTUAL" != "$MODEL_SHA" ]; then
  echo "⚠ 模型 sha256 与脚本记录的不一致(记录 ${MODEL_SHA:0:12}…,实际 ${ACTUAL:0:12}…)"
  echo "  若确认无误,请把脚本里的 MODEL_SHA 更新为实际值。"
fi

# ── 2. .so ──
if [ $FORCE -eq 0 ] && [ -f "$SO_OUT" ]; then
  echo "▸ libreverb_asr.so 已在,跳过($(du -h "$SO_OUT" | cut -f1))"
  exit 0
fi

# NDK:取版本号最大的一个
NDK=$(ls -d "$NDK_ROOT"/* 2>/dev/null | sort -V | tail -1 || true)
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "✗ 找不到 NDK(可用 ANDROID_NDK_HOME 指定)"; exit 1; }

# **不要用 PATH 上的 cmake**:很多机器上那是 3.10,不支持 -S/-B(踩过)。
# 用 Android SDK 自带的,顺带保证与 AGP 用的是同一套。
CMAKE=$(ls -d "$SDK_ROOT"/cmake/*/bin/cmake 2>/dev/null | sort -V | tail -1 || true)
NINJA=$(dirname "${CMAKE:-/nonexistent}")/ninja
[ -x "${CMAKE:-}" ] || { echo "✗ 找不到 Android SDK 自带的 cmake($SDK_ROOT/cmake/*/bin/cmake)"; exit 1; }

SRC="$ROOT/asr-native"
if [ ! -d "$SRC/whisper.cpp/.git" ]; then
  echo "▸ 取 whisper.cpp @ ${WHISPER_COMMIT:0:12}"
  rm -rf "$SRC/whisper.cpp"
  git clone --quiet "$WHISPER_REPO" "$SRC/whisper.cpp"
fi
git -C "$SRC/whisper.cpp" fetch --quiet origin "$WHISPER_COMMIT" 2>/dev/null || true
git -C "$SRC/whisper.cpp" checkout --quiet "$WHISPER_COMMIT"

echo "▸ 交叉编译 arm64-v8a(NDK $(basename "$NDK"))"
"$CMAKE" -S "$SRC" -B "$SRC/build-arm64" -GNinja \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
"$CMAKE" --build "$SRC/build-arm64" -j8 --target reverb_asr >/dev/null

mkdir -p "$(dirname "$SO_OUT")"
cp "$SRC/build-arm64/libreverb_asr.so" "$SO_OUT"
echo "✓ $SO_OUT  ($(du -h "$SO_OUT" | cut -f1))"
echo "✓ $MODEL_OUT ($(du -h "$MODEL_OUT" | cut -f1))"
echo
echo "  只有 arm64-v8a:armeabi-v7a 的机器跑不动这个模型,给了也是让人干等。"
echo "  带上这两样之后那份包会从约 4 MB 涨到约 65 MB(合并后只有一份包,不再有两体积的对比)。"
