#!/bin/bash
#
# 把内置精选清单分发到各端资源目录(注意:**不含鸿蒙**,理由见下)。
#
# 为什么要复制而不是引用:各套构建体系(gradle assets / SPM+package.sh)
# 都要求资源在各自的目录树里,软链在打包环节不可靠(会被解引用或直接漏掉)。
# 所以规范副本在 shared/seed/,各端留一份**由本脚本生成**的拷贝,一起入库。
#
# 用法:
#   ./sync.sh            分发
#   ./sync.sh --check    只校验各端副本与规范副本是否一致(CI/提交前用),不写文件
#
# 改清单的正确顺序:python3 gen-seed.py → ./sync.sh → 把规范副本与各端拷贝一起提交
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

SRC="seed_podcasts.json"
[ -f "$SRC" ] || { echo "✗ 缺 $SRC,先跑 python3 gen-seed.py"; exit 1; }

# 目标路径:各端的「随包资源」约定位置
# 完整清单(含标题/封面/分类)给 Android / macOS / iOS 三个。鸿蒙**不打这份完整清单** ——
# 它是"内置内容目录",合规口径见下。但鸿蒙需要一份**候选源映射**(只有主 feedUrl → 备用
# feedUrl 数组,没有任何节目名/封面/分类,不构成可浏览目录),用于主源被平台拦截时换源,
# 由 gen-seed.py --sync-harmony-map 生成到 rawfile/。
#
# 合规口径的背景(2026-10-18 之前的写法):应用市场把「内置内容目录 / 分类浏览 /
# 内容推荐」判定为提供视听节目服务(需前置审批,个人主体拿不到),而「用户自行添加
# RSS 源」的纯工具不需要。这份清单是最直白的"内置内容目录"—— 解压安装包就能看到,
# 所以原先只打进 Android 的 default 渠道、商店那份 APK 里根本不存在这个文件。
# **2026-10-18 两个 flavor 合成一份包之后不再有这套隔离**,清单直接进 src/main/assets,
# 大陆商店的提审口径改由 App 内可浏览目录的实际形态承担(见 H205 与 docs/FEATURES.md)。
# 鸿蒙只经应用市场分发,所以照旧不打包;那份要走的是官网 OPML「导入推荐订阅」,
# 由用户主动点击导入,App 内不渲染任何可浏览的节目目录(OPML 由 `gen-seed.py --opml` 生成)。
TARGETS=(
  "$ROOT/android/app/src/main/assets/seed_podcasts.json"
  "$ROOT/macos/Resources/seed_podcasts.json"
  "$ROOT/ios/Resources/seed_podcasts.json"
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

# 鸿蒙专用:候选源映射。只有 "主 feedUrl → 备用源数组",**没有**节目标题/封面/分类,
# 不构成"内置内容目录"(合规口径见上),仅用于主源被平台拦截时换源(H311)。
HM_MAP="$ROOT/harmony/entry/src/main/resources/rawfile/feed_alternates.json"
python3 - "$SRC" "$HM_MAP" <<'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    data = json.load(f)
m = {}
for entries in data.get("lists", {}).values():
    for e in entries:
        alts = e.get("altFeeds") or []
        if alts:
            m[e["feedUrl"]] = alts
with open(out, "w", encoding="utf-8") as f:
    json.dump(m, f, ensure_ascii=False, indent=1, sort_keys=True)
    f.write("\n")
print(f"→ 鸿蒙候选源映射 {len(m)} 条: {out}")
PY

if [ "$CHECK" = "1" ]; then
  [ "$FAIL" = "0" ] && echo "✓ 各端副本与 shared/seed/$SRC 一致" || {
    echo "✗ 有副本不一致,请跑 ./sync.sh 重新分发"; exit 1; }
else
  echo "✓ 已分发($(( $(stat -f%z "$SRC") / 1024 )) KB × ${#TARGETS[@]})"
fi
