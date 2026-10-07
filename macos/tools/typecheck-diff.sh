#!/usr/bin/env bash
# 本机对 macOS 改动的最强验收:整模块 typecheck 差分。
#
# 为什么要有这个脚本(AGENTS.md「macOS」一节 + H128):
# 本机跑不了 package.sh(没有完整 Xcode / 没有 xcbuild / SDK 上限 13.1),
# 所以「改完 macOS 代码」在这台机器上唯一能拿出的硬证据就是 ——
# **基线树(HEAD)与改动树(工作区)在同一个中性化口径下都走到 0 错误**。
#
# 三条判据,缺一不可:
#   1. 两棵树都 **0 错误**。不是「改前改后错误条数相同」—— swiftc 在第一个含错的文件之后
#      就不再有意义地继续(H128),同样的条数证明不了其余文件被检查过。
#   2. 中性化脚本每条改写都必须命中(不命中它自己 MISS 退出),否则那个 0 可能只是漏改;
#      两棵树的改写类数还必须相同,否则两边口径不一样,差分无从比较。
#   3. 阳性对照:往本次改动的每个 swift 文件里各注入一个语义错(每次只留一个),
#      各自都必须被报出来。没有这一条,那个 0 不成立。
#
# 天花板(必须如实说):这只证明**类型**没变多。一帧都没跑起来,证明不了界面与行为。
#
# 用法:cd macos && bash tools/typecheck-diff.sh
set -o pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${TMPDIR:-/tmp}/tcdiff.$$
SDK=$(xcrun --show-sdk-path)
TARGET=x86_64-apple-macos13.0
rc=0

say()  { printf '%s\n' "$*"; }
fail() { printf '✗ %s\n' "$*"; rc=1; }
ok()   { printf '✓ %s\n' "$*"; }

command -v swiftc >/dev/null || { say "swiftc 不存在,本机跑不了这个验收"; exit 2; }
[ -d "$SDK" ] || { say "拿不到 SDK:$SDK"; exit 2; }

say "== 处理量 =="
say "SDK=$SDK · target=$TARGET"

# ---- 1) 两棵树:基线 = HEAD,改动 = 工作区(都不动工作区本身) ----
mkdir -p "$WORK/base" "$WORK/mod"
( cd "$REPO" && git archive HEAD macos ) | tar -x -C "$WORK/base" || { say "git archive 失败"; exit 2; }
BASE=$WORK/base/macos
# 工作区侧只取源码与资源,跳过 dist / .build(产物可能几百 MB,且与类型无关)
rsync -a --exclude dist --exclude .build --exclude '.DS_Store' "$REPO/macos/" "$WORK/mod/" || { say "rsync 失败"; exit 2; }

vol() { printf '%s 个 swift 文件 / %s 字节' \
  "$(find "$1/Sources" -name '*.swift' | wc -l | tr -d ' ')" \
  "$(find "$1/Sources" -name '*.swift' -exec cat {} + | wc -c | tr -d ' ')"; }
say "base(HEAD):  $(vol "$BASE")"
say "mod(工作区):  $(vol "$WORK/mod")"

DIFF=$(cd "$REPO" && git diff --name-only HEAD -- macos/Sources | grep '\.swift$')
n_diff=$(printf '%s\n' "$DIFF" | grep -c .)
say "本次改动的 swift 文件:$n_diff 个"
[ "$n_diff" = 0 ] || printf '%s\n' "$DIFF" | sed 's/^/  /'

# ---- 2) 同一份中性化脚本,两棵树各跑一遍 ----
say "== 中性化(14+/26-only 依赖) =="
classes_for() { tail -1 | sed 's/.* 共 //; s/ 类.*//'; }
N_base=$(python3 "$REPO/macos/tools/neutralize-sdk13.py" "$BASE" 2>&1 | tee "$WORK/neutralize.base.txt" | classes_for)
N_mod=$(python3 "$REPO/macos/tools/neutralize-sdk13.py" "$WORK/mod" 2>&1 | tee "$WORK/neutralize.mod.txt" | classes_for)
sed "s/^/  [base] /" "$WORK/neutralize.base.txt"
sed "s/^/  [mod]  /" "$WORK/neutralize.mod.txt"
if ! grep -q '^NEUTRALIZED' "$WORK/neutralize.base.txt" || ! grep -q '^NEUTRALIZED' "$WORK/neutralize.mod.txt"; then
  fail "中性化有判据没命中(脚本自己 MISS 退出)—— 差分不可比"
  exit 1
fi
if ! printf '%s' "$N_base" | grep -qE '^[1-9][0-9]*$' || ! printf '%s' "$N_mod" | grep -qE '^[1-9][0-9]*$'; then
  fail "没从脚本输出里读到类数(base=$N_base mod=$N_mod)—— 判据 2 无法成立"
  exit 1
fi
if [ "$N_base" != "$N_mod" ]; then
  fail "两棵树的中性化类数不同(base=$N_base mod=$N_mod) —— 口径不一致,差分没有意义"
else
  ok "两棵树各中性化 $N_base 类(同一份脚本)"
fi

tc() { # $1 = 树目录;输出 swiftc 的全部诊断
  ( cd "$1" && swiftc -typecheck -sdk "$SDK" -target "$TARGET" $(find Sources -name '*.swift') 2>&1 )
}

# ---- 3) 两棵树都必须 0 错误 ----
say "== typecheck 差分 =="
for t in base mod; do
  d=$BASE; [ "$t" = mod ] && d=$WORK/mod
  log=$(tc "$d")
  printf '%s\n' "$log" > "$WORK/$t.log"
  e=$(grep -c ': error' "$WORK/$t.log")
  if [ "$e" = 0 ]; then
    ok "$t: 0 错误(检查了 $(find "$d/Sources" -name '*.swift' | wc -l | tr -d ' ') 个文件)"
  else
    fail "$t: $e 条错误 —— 差分不成立,先修中性化或代码"
    grep ': error' "$WORK/$t.log" | head -20 | sed 's/^/    /'
  fi
done

# ---- 4) 阳性对照:每个改动文件各注入一个语义错,每次只留一个 ----
say "== 阳性对照 =="
if [ "$n_diff" = 0 ]; then
  targets=( "Sources/Reverb/RootView.swift" )
  say "(本次没有 swift 改动,对照改用 ${targets[0]})"
else
  targets=()
  while IFS= read -r f; do
    [ -n "$f" ] && targets+=( "${f#macos/}" )
  done <<< "$DIFF"
fi
i=0
for f in "${targets[@]}"; do
  i=$((i+1))
  if [ ! -f "$WORK/mod/$f" ]; then fail "改动文件在 scratch 树里找不到:$f"; continue; fi
  cp "$WORK/mod/$f" "$WORK/f.bak"
  printf '\nenum __TypecheckControl%d { static let x: Int = "注入用的类型错" }\n' "$i" >> "$WORK/mod/$f"
  log=$(tc "$WORK/mod")
  hit=$(printf '%s\n' "$log" | grep ': error' | head -1)
  if [ -n "$hit" ]; then
    ok "注入 $f -> 被报出来:$hit"
  else
    fail "注入 $f 却没报任何错 —— 这条路径没被检查,前面那个 0 不成立"
  fi
  mv "$WORK/f.bak" "$WORK/mod/$f"
done
log=$(tc "$WORK/mod")
if printf '%s\n' "$log" | grep -q ': error'; then
  fail "对照结束时 mod 树仍非 0 错误(注入没撤净,或本次改动本身有错)"
else
  ok "撤掉全部注入:mod 树回到 0 错误"
fi

# ---- 5) 未覆盖范围(必须打印,不能沉默) ----
say "== 这次没覆盖到什么 =="
cat <<'EOF'
  · 只过类型:**一帧都没跑起来**,界面与行为没有任何证据(实跑清单见 docs/ROADMAP.md 三-A)。
  · Transcriber 换成同签名桩、TranscriptStore.run 换成一句赋值(中性化 ⑧⑨):
    26-only 的转录实现本体**不在本次检查范围内**。
  · 轮播四个 modifier / SettingsLink / focusEffectDisabled / 双参 onChange / assumeIsolated /
    nonisolated(unsafe) 都被换成本机能解析的形状:这些 14+ API 的**用法对不对,本机验不了**。
  · 资源侧不检查:.strings 的键集与译值要靠人工对照(五语种口径见 AGENTS.md 硬规矩 5)。
  · 链接期与运行时(.app、签名、universal 架构、dmg)一概不覆盖 —— 那要在构建机上跑 package.sh。
EOF
rm -rf "$WORK"
if [ "$rc" = 0 ]; then
  say "结论:差分成立(两棵树同口径 0 错误 + 阳性对照全部报出)。仅证明类型层面。"
else
  say "结论:差分不成立,见上面 ✗。"
fi
exit $rc
