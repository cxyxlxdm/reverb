#!/bin/bash
#
# 备齐**离线语音识别**所需的模型(都不入版本管理):
#
#   entry/src/main/resources/rawfile/sensevoice/model.int8.onnx   SenseVoiceSmall int8(约 228 MB)
#   entry/src/main/resources/rawfile/sensevoice/tokens.txt        词表(约 0.3 MB)
#
# 用法:
#   ./tools/build-asr.sh          备齐(已存在且校验通过则跳过)
#   ./tools/build-asr.sh --force  强制重来
#
# 为什么不把产物提交进仓库:239 MB 的模型放进 git 会让仓库和每次打包的体量都难看,
# 而它完全可以由这个脚本一条命令重建(与 Android 端 tools/build-asr.sh 同一取舍,
# 硬规矩 16)。**任何一次发布构建都要先跑本脚本**,build-release.sh 会检查它们在不在,
# 缺了直接报错退出;并且出包后会解包 grep 确认模型真的进了 .app(硬规矩 1)。
#
# 引擎侧的 .so 与 ArkTS 封装不在这个脚本里:sherpa-onnx 以 har 形态由 ohpm 安装
# (entry/oh-package.json5 的 `sherpa_onnx`),首次 `ohpm install` 时取回。
# 版本固定 1.13.3 —— 上游 API 与模型格式都在演进,浮动跟主线会某天突然行为变了。
#
# 模型来源优先**本机已有的那份**:Android 端的 assets 与这里要的是同一个文件
# (同一版本、同一 sha256),同机开发时直接拷比再下一次 228 MB 快得多。
# 拷贝前按 sha256 校验 —— Android 那边换了模型却没同步这脚本时,这里会拒绝而不是
# 把两份不同的模型悄悄装进两端。
#
# 下载走 hf-mirror(GitHub / HuggingFace 在大陆经常只有几十 KB/s),可用
# ASR_MODEL_HOST 覆盖(例如 https://huggingface.co)。
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

MODEL_HOST="${ASR_MODEL_HOST:-https://hf-mirror.com}"
MODEL_REPO="csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
MODEL_URL="$MODEL_HOST/$MODEL_REPO/resolve/main/model.int8.onnx"
TOKENS_URL="$MODEL_HOST/$MODEL_REPO/resolve/main/tokens.txt"
MODEL_SHA=c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51
TOKENS_SHA=f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc

# 同机 Android 端的同一份产物。有它就走拷贝,没有就走下载。
ANDROID_ASSETS="$ROOT/../android/app/src/main/assets/sensevoice"
DEST_DIR="$ROOT/entry/src/main/resources/rawfile/sensevoice"
MODEL_OUT="$DEST_DIR/model.int8.onnx"
TOKENS_OUT="$DEST_DIR/tokens.txt"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

sha_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

check_sha() {   # check_sha <文件> <期望值> <说明>
  local actual
  actual=$(sha_of "$1")
  if [ "$actual" != "$2" ]; then
    echo "✗ $(basename "$1") 的 sha256 与脚本记录不一致($3)"
    echo "  记录 ${2:0:12}…,实际 ${actual:0:12}…"
    echo "  若确认无误,请把脚本里对应的 SHA 更新为实际值;否则删掉它重跑。"
    exit 1
  fi
}

ok_file() {   # ok_file <文件> <期望值>
  [ -s "$1" ] && [ "$(sha_of "$1")" = "$2" ]
}

mkdir -p "$DEST_DIR"

fetch() {   # fetch <远端 url> <本机同名备用源> <输出> <sha> <说明>
  local url="$1" local_src="$2" out="$3" sha="$4" label="$5"
  if [ $FORCE -eq 0 ] && ok_file "$out" "$sha"; then
    echo "▸ $label 已在,校验通过,跳过($(du -h "$out" | cut -f1))"
    return
  fi
  if [ -s "$local_src" ] && ok_file "$local_src" "$sha"; then
    echo "▸ $label 从 Android 端拷贝($(du -h "$local_src" | cut -f1))"
    cp "$local_src" "$out.part"
  else
    if [ -s "$local_src" ]; then
      echo "! $local_src 存在但 sha256 不是这一份,改走下载"
    fi
    echo "▸ 下载 $label"
    curl -fL --progress-bar -o "$out.part" "$url"
  fi
  check_sha "$out.part" "$sha" "$label"
  mv "$out.part" "$out"
}

fetch "$MODEL_URL" "$ANDROID_ASSETS/model.int8.onnx" "$MODEL_OUT" "$MODEL_SHA" "SenseVoiceSmall int8 模型(约 228 MB)"
fetch "$TOKENS_URL" "$ANDROID_ASSETS/tokens.txt" "$TOKENS_OUT" "$TOKENS_SHA" "词表"

echo "✓ $MODEL_OUT ($(du -h "$MODEL_OUT" | cut -f1))"
echo "✓ $TOKENS_OUT ($(du -h "$TOKENS_OUT" | cut -f1))"
echo
echo "  这两份会被打进 hap(rawfile),于是 release 包会比不带识别时大约多 229 MB。"
echo "  鸿蒙只有应用市场渠道,单包的体积上限与商店侧的说明以市场规则为准;"
echo "  取舍与实测数据见 docs/research/2026-11-11-offline-asr-engine.md。"
