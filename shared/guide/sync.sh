#!/bin/bash
#
# 把内置引导音频分发到三端资源目录。
#
# 为什么要复制而不是引用:三套构建体系(gradle assets / SPM+package.sh / hvigor rawfile)
# 都要求资源在各自的目录树里,软链在打包环节不可靠(会被解引用或直接漏掉)。
# 所以规范副本在 shared/guide/,三端各留一份**由本脚本生成**的拷贝,一起入库。
#
# 用法:
#   ./sync.sh            分发
#   ./sync.sh --check    只校验三端副本与规范副本是否一致(提交前用),不写文件
#
# 换音频的正确顺序:./make-guide.sh(或自己录一份替换)→ ./sync.sh → 提交(4 个文件一起)
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

SRC="guide_intro.m4a"
[ -f "$SRC" ] || { echo "✗ 缺 $SRC,先跑 ./make-guide.sh"; exit 1; }

# 目标路径:各端的「随包资源」约定位置
TARGETS=(
  "$ROOT/android/app/src/main/assets/guide_intro.m4a"
  "$ROOT/macos/Resources/guide_intro.m4a"
  "$ROOT/harmony/entry/src/main/resources/rawfile/guide_intro.m4a"
)

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

SRC_MD5=$(md5 -q "$SRC")
FAIL=0

for t in "${TARGETS[@]}"; do
  rel="${t#"$ROOT"/}"
  if [ "$CHECK" = "1" ]; then
    if [ ! -f "$t" ]; then
      echo "✗ 缺失  $rel"; FAIL=1
    elif [ "$(md5 -q "$t")" != "$SRC_MD5" ]; then
      echo "✗ 不一致 $rel"; FAIL=1
    else
      echo "✓ 一致  $rel"
    fi
  else
    mkdir -p "$(dirname "$t")"
    cp "$SRC" "$t"
    echo "→ $rel"
  fi
done

if [ "$CHECK" = "1" ]; then
  [ "$FAIL" = "0" ] && echo "✓ 三端副本与 shared/guide/$SRC 一致" || {
    echo "✗ 有副本不一致,请跑 ./sync.sh 重新分发"; exit 1; }
else
  echo "✓ 已分发($(( $(stat -f%z "$SRC") / 1024 )) KB × 3)"
fi
