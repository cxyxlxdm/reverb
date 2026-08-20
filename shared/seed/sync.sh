#!/bin/bash
#
# 把内置精选清单分发到各端资源目录(注意:**不含商店渠道与鸿蒙**,理由见下)。
#
# 为什么要复制而不是引用:三套构建体系(gradle assets / SPM+package.sh / hvigor rawfile)
# 都要求资源在各自的目录树里,软链在打包环节不可靠(会被解引用或直接漏掉)。
# 所以规范副本在 shared/seed/,三端各留一份**由本脚本生成**的拷贝,一起入库。
#
# 用法:
#   ./sync.sh            分发
#   ./sync.sh --check    只校验三端副本与规范副本是否一致(CI/提交前用),不写文件
#
# 改清单的正确顺序:python3 gen-seed.py → ./sync.sh → 提交(4 个文件一起)
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

SRC="seed_podcasts.json"
[ -f "$SRC" ] || { echo "✗ 缺 $SRC,先跑 python3 gen-seed.py"; exit 1; }

# 目标路径:各端的「随包资源」约定位置
# 注意目标只剩两个,且 Android 那份在 **src/default/** 而不是 src/main/。
#
# 起因:应用市场的合规口径把「内置内容目录 / 分类浏览 / 内容推荐」判定为提供视听节目
# 服务(需前置审批,个人主体拿不到),而「用户自行添加 RSS 源」的纯工具不需要。
# 这份清单是最直白的"内置内容目录"—— 解压安装包就能看到。因此:
#   - Android:只打进 default 渠道;商店渠道的 APK 里**根本不存在**这个文件
#   - 鸿蒙:只经应用市场分发,故完全不打包
#   - macOS:不走大陆应用商店(直接分发 dmg),保持原样
# 商店渠道改用「导入推荐订阅」:清单以 OPML 形式挂在官网,由用户主动点击导入,
# App 内不渲染任何可浏览的节目目录。那份 OPML 由 `gen-seed.py --opml` 生成。
TARGETS=(
  "$ROOT/android/app/src/default/assets/seed_podcasts.json"
  "$ROOT/macos/Resources/seed_podcasts.json"
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
  [ "$FAIL" = "0" ] && echo "✓ 各端副本与 shared/seed/$SRC 一致" || {
    echo "✗ 有副本不一致,请跑 ./sync.sh 重新分发"; exit 1; }
else
  echo "✓ 已分发($(( $(stat -f%z "$SRC") / 1024 )) KB × ${#TARGETS[@]})"
fi
