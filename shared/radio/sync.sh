#!/bin/bash
#
# 把内置精选电台清单分发到四端资源目录。
#
# 为什么要复制而不是引用:四套构建体系(gradle assets / SPM+package.sh / hvigor rawfile / Xcode bundle)
# 都要求资源在各自的目录树里,软链在打包环节不可靠(会被解引用或直接漏掉)。
# 所以规范副本在 shared/radio/,各端留一份**由本脚本生成**的拷贝,一起入库。
#
# 用法:
#   ./sync.sh            分发
#   ./sync.sh --check    只校验各端副本与规范副本是否一致(提交前用),不写文件
#
# ⚠️ 合规口径与 shared/seed/ 那块不同,写在这里免得下次有人按种子播客的先例"顺手删掉鸿蒙":
# 种子播客清单当初不打进鸿蒙,是因为商店把「内置内容目录」视为需前置审批的视听服务;
# 电台清单是同一性质。本脚本**按维护者 2026-11-24 的范围决定四端都分发**——
# 鸿蒙侧由默认关闭的 `radio_full_enabled` 开关隐藏精选与管理入口,用户可手动开启。
# 代码、账本与随包清单都保留;不要再用删文件或删读取分支的方式实现界面隐藏。
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

SRC="stations.json"
[ -f "$SRC" ] || { echo "✗ 缺 $SRC"; exit 1; }
python3 -c "import json,sys; json.load(open('$SRC'))" || { echo "✗ $SRC 不是合法 JSON"; exit 1; }

TARGETS=(
  "$ROOT/android/app/src/main/assets/radio_stations.json"
  "$ROOT/macos/Resources/radio_stations.json"
  "$ROOT/ios/Resources/radio_stations.json"
  "$ROOT/harmony/entry/src/main/resources/rawfile/radio_stations.json"
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
  [ "$FAIL" = "0" ] && echo "✓ 各端副本与 shared/radio/$SRC 一致" || {
    echo "✗ 有副本不一致,请跑 ./sync.sh 重新分发"; exit 1; }
else
  echo "✓ 已分发($(( $(stat -f%z "$SRC") / 1024 )) KB × ${#TARGETS[@]})"
fi
