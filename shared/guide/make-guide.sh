#!/bin/bash
#
# 生成随包内置的「新手引导」音频 guide_intro.m4a。
#
# 用途:App 在没有任何内容时(首次安装、无网)也能走通一次完整播放链路 ——
# 播放条、进度、倍速、后台继续放、锁屏控制,全都能当场演示。
#
# 当前用 macOS 内置 TTS(say)配音,**这是占位性质的**:机器音听着就是机器音。
# 想换成你自己的录音,只要把同名文件替换掉即可 —— 代码只认文件名,不关心怎么来的:
#   1) 录一段 mp3/wav/m4a
#   2) afconvert 你的录音 -o guide_intro.m4a -f m4af -d aac -b 32000
#   3) ./sync.sh 分发到三端
# 也可以直接改 script.txt 后重跑本脚本换文案。
#
# 参数取值理由:单声道 + 22.05kHz + 32kbps —— 纯语音这个档位听感够用,
# 而它要**打进三个安装包**,每省 100KB 就是省 300KB。
#
set -euo pipefail
cd "$(dirname "$0")"

VOICE="${VOICE:-Tingting}"     # zh_CN 女声;VOICE=Sinji 可换粤语
RATE="${RATE:-180}"            # 字/分钟。默认 180 比系统默认略慢,听着不赶
OUT="guide_intro.m4a"

command -v say >/dev/null || { echo "✗ 找不到 say(仅 macOS 可生成)"; exit 1; }
command -v afconvert >/dev/null || { echo "✗ 找不到 afconvert"; exit 1; }
[ -f script.txt ] || { echo "✗ 缺 script.txt(引导文案)"; exit 1; }

say -v '?' | grep -q "^${VOICE} " || { echo "✗ 系统里没有 ${VOICE} 这个语音,用 say -v '?' 查可用列表"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "▸ 合成语音(voice=$VOICE rate=$RATE)"
say -v "$VOICE" -r "$RATE" -f script.txt -o "$TMP/raw.aiff"

echo "▸ 转 AAC(单声道 32kbps)"
afconvert "$TMP/raw.aiff" -o "$OUT" -f m4af -d aac -b 32000

DUR=$(afinfo "$OUT" | sed -n 's/estimated duration: \([0-9]*\)\..*/\1/p')
SIZE=$(( $(stat -f%z "$OUT") / 1024 ))
echo
echo "✓ $OUT  ${DUR}s  ${SIZE} KB"
echo "  时长要同步到代码里的 GUIDE_DURATION_SEC(三端各一处),否则进度条刻度不对"
echo "  接着跑 ./sync.sh 分发到三端"
