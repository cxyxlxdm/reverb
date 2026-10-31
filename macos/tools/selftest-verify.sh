#!/bin/bash
# verify-bundle.sh 的自检:手搭一个假 bundle,先跑正向(必须通过),再把每条断言逐个弄坏
# (必须各自失败)。为什么需要它 —— 见 verify-bundle.sh 头部与 H136:
# 一条从没被执行过的断言,和没有断言是同一件事。而这里的断言恰恰**不能**靠"下次出包时顺带看看"
# 来验:package.sh 要走完 swift build 才到验收段,本仓库的开发机跑不了 swift build。
# ▶ 10-24 傍晚起这台跑得动了(H208 的许可门 + H209 的判据门都过了),但本脚本不因此退役:
#   全量出包只证明"这次没报红",本脚本证明的是"每条断言各自都有牙齿"(把每条单独弄坏都必须被抓到)。
# 所以把验收段做成可以在任何 Mac 上独立跑的脚本,判据词与 bundle 都用假的造。
#
# 跑法:bash macos/tools/selftest-verify.sh      退出 0 = 正向通过 + 每道变异各自被抓到
# (通过的条数由脚本最后一行自己打印,别往任何文档里抄 —— 加一道变异它就变。)
# 依赖:clang / lipo / codesign / plutil(命令行工具链即可,不需要 Xcode,也不需要能编本工程)
# ⚠️ 但这些工具都走 developer dir 的 shim,**许可未同意时它们只回一句提示** —— 这条环境门写在下面,
#    脚本会自己 exit 69 说清是环境而不是断言(10-24 下午踩过"clang x86_64 失败"的误读,见 H208 教训 10)。
set -uo pipefail
cd "$(dirname "$0")/.."          # → macos/

# 环境门,排在任何断言之前。为什么要有它:developer dir 的许可没同意时,clang / lipo / codesign / plutil
# 这些 shim 全部只回一句许可提示,于是本脚本第一条 clang 就失败、报成 `clang x86_64 失败` ——
# 那读起来像"验收断言出了问题",其实是环境(10-24 下午真踩过,见 H208 教训 10)。
# 判据用**退出码**而不是比对输出里的字样,这样它可以被别的脚本当闸门复用;69 = EX_CONFIG。
if ! xcrun --show-sdk-path >/dev/null 2>&1; then
  echo "环境门:xcrun --show-sdk-path 取不到 SDK(developer dir 不通)。"
  echo "        最常见原因是 Xcode 许可未同意 —— 跑 sudo xcodebuild -license accept 之后再来的。"
  echo "        这不是 verify-bundle.sh 的断言失败,别照着这句话去改判据。"
  exit 69
fi
VERIFY="./verify-bundle.sh"
WORK=$(mktemp -d /tmp/selftest-verify.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# 判据词清单与 verify-bundle.sh 里那张表是**两份副本**,靠得住的原因是它们一漂就炸:
# 加了词而这里没加 → 正向用例的假 bundle 少那个词 → 正向 exit 1 → 本自检红。
# (而不是"两边各自演进也能过" —— 那种重复才是隐患。)变异用的「少一个词」版由这里派生。
# ⚠️ 这里只写**裸词**(不带 lit8:/lit16:/sym: 前缀):假 bundle 是 C 源码里的一个连续字符串,
# 类别约束由 verify-bundle.sh 自己执行,而它对类别的自检是下面那条「配置错」变异(变异 8)。
# 词的字节数别乱改 —— 9~15 字节的字面量在真 release 包里会被拆成两条立即数,整词 grep 恒 0,
# 那种词在这里能过、在真包上永远过不了(见 H209)。
WORDS='SHUFFLE repeat.1 批注 square.and.pencil playModeByTag setPlayMode NoteStore EpisodeNote retry after fast failure elapsed= noteComposer'
LANGS=(en es fr zh-Hant)   # 五语里 zh-Hans 是基础语言(键即简体原文),所以 .lproj 只有四套

printf 'static const char *w = "%s";\nint main(void){return 0;}\nconst char *getw(void){return w;}\n' \
  "$WORDS" > "$WORK/all.c"
# 少最后一个词的版本(中文词按整串删,不做子串,免得删出半个 UTF-8 序列让 grep 行为变得不可预期)
printf 'static const char *w = "%s";\nint main(void){return 0;}\nconst char *getw(void){return w;}\n' \
  "${WORDS% noteComposer}" > "$WORK/less.c"

for src in all less; do
  clang -arch x86_64 -mmacosx-version-min=13.0 -o "$WORK/${src}_x" "$WORK/$src.c" || { echo "clang x86_64 失败"; exit 1; }
  clang -arch arm64  -mmacosx-version-min=13.0 -o "$WORK/${src}_a" "$WORK/$src.c" || { echo "clang arm64 失败(本机编不出 arm64,自检跑不了)"; exit 1; }
  lipo -create -o "$WORK/${src}_univ" "$WORK/${src}_a" "$WORK/${src}_x"
done

cat > "$WORK/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fake</string>
<key>CFBundleIdentifier</key><string>com.example.fake</string>
<key>CFBundleShortVersionString</key><string>1.0.4</string>
<key>CFBundleVersion</key><string>1000004</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF

# 从「一切都好」的模板复制一份再破坏一处 —— 保证每个变异用例的失败只归因于那一处。
build_good() {
  local B="$1"
  rm -rf "$B"
  mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources"
  cp "$WORK/all_univ" "$B/Contents/MacOS/Fake"
  cp "$WORK/Info.plist" "$B/Contents/Info.plist"
  local l
  for l in "${LANGS[@]}"; do
    mkdir -p "$B/Contents/Resources/$l.lproj"
    printf '"k" = "v";\n' > "$B/Contents/Resources/$l.lproj/Localizable.strings"
  done
  codesign --force --deep --sign - "$B" >/dev/null 2>&1
}

PASS=0 FAIL=0
# expect <名称> <bundle> <期望退出码> <必须命中的那条判据原文> [verify 额外参数...]
# 两道检查,缺一不可:
#  ① 输出里有**那条具体 fail 的原文**(不是"任何含该词的行都算" —— 判据词那条会先打印命中数再打 ✗,
#     只 grep 词本身的话,那行打印也算命中,于是断言其实没牙齿也照样"通过");
#  ② 不通过的条数正好等于 WANT_FAILS(默认 1)—— 证明这个变异**只**触发了那一条判据,
#     而不是被别的判据顺带拦下(那样这条变异验的就不是它自己声称的那条了)。
expect() {
  local name="$1" bundle="$2" want="$3" needle="$4"; shift 4
  local want_fails="${WANT_FAILS:-1}" out rc concl
  out=$("${V:-$VERIFY}" "$bundle" "$@" 2>&1); rc=$?
  # WANT_EARLY=1:这条判据是"读不到就直接退出"的前置检查(压根走不到结论行),只比对退出码与那条原文
  if [ "${WANT_EARLY:-0}" = 1 ]; then concl="$needle"
  elif [ "$want_fails" -eq 0 ]; then concl="全部断言通过"
  else concl="结论:$want_fails 条断言不通过"; fi
  if [ "$rc" -ne "$want" ] || ! printf '%s' "$out" | grep -q -- "$needle" \
     || ! printf '%s' "$out" | grep -q -- "$concl"; then
    echo "   FAIL $name —— 期望 exit=$want + 含「$needle」+ 含「$concl」;实际 exit=$rc"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  else
    echo "   ok   $name(命中「$needle」,且只有这 $want_fails 条失败)"
    PASS=$((PASS + 1))
  fi
}

VARGS=(arm64 x86_64 --langs "${LANGS[@]}")

echo "==> 正向:完好的 universal bundle 必须通过"
GOOD="$WORK/Good.app"; build_good "$GOOD"
WANT_FAILS=0 expect "positive" "$GOOD" 0 "全部断言通过" "${VARGS[@]}"

echo "==> 变异 1:二进制少一个判据词(noteComposer)—— 架构仍是两个,所以只有词判据该失败"
M="$WORK/M1.app"; build_good "$M"
cp "$WORK/less_univ" "$M/Contents/MacOS/Fake"
codesign --force --deep --sign - "$M" >/dev/null 2>&1
WANT_FAILS=1 expect "missing-word" "$M" 1 "「noteComposer」在二进制里 0 命中" "${VARGS[@]}"

echo "==> 变异 2:一份 .strings 语法坏(少了分号)"
M="$WORK/M2.app"; build_good "$M"
printf '"k" = "v"\n' > "$M/Contents/Resources/fr.lproj/Localizable.strings"
codesign --force --deep --sign - "$M" >/dev/null 2>&1   # 改完资源要重签,否则这条变异会连签名一起坏掉(实测会多报一条)
WANT_FAILS=1 expect "bad-strings" "$M" 1 "lint 不过" "${VARGS[@]}"

echo "==> 变异 3:整个 .lproj 少一套(删掉 zh-Hant)—— 剩下的都 lint OK,只打印的版本看不出来"
M="$WORK/M3.app"; build_good "$M"
rm -rf "$M/Contents/Resources/zh-Hant.lproj"
codesign --force --deep --sign - "$M" >/dev/null 2>&1   # 同上:变异只该破坏一处判据
WANT_FAILS=1 expect "missing-language" "$M" 1 "缺 zh-Hant.lproj" "${VARGS[@]}"

echo "==> 变异 4:期望两个架构、实际只有 arm64(1.0.2 那个包的形状)"
M="$WORK/M4.app"; build_good "$M"
cp "$WORK/all_a" "$M/Contents/MacOS/Fake"
codesign --force --deep --sign - "$M" >/dev/null 2>&1
WANT_FAILS=1 expect "arm64-only" "$M" 1 "缺 x86_64" "${VARGS[@]}"

echo "==> 变异 4b:期望单架构、实际 universal(多出来的架构也该拦 —— 文件名与构建口径会不一致)"
WANT_FAILS=1 expect "extra-arch" "$GOOD" 1 "多出 x86_64" arm64 --langs "${LANGS[@]}"

echo "==> 变异 5:Info.plist 缺 CFBundleVersion"
M="$WORK/M5.app"; build_good "$M"
plutil -remove CFBundleVersion "$M/Contents/Info.plist" >/dev/null 2>&1
codesign --force --deep --sign - "$M" >/dev/null 2>&1
WANT_FAILS=1 expect "no-build-version" "$M" 1 "Info.plist 的 CFBundleVersion" "${VARGS[@]}"

echo '==> 变异 6:签完名再改二进制(签名失效)。前一版只跑 `codesign -dvv` 打印描述,拦不住这个'
M="$WORK/M6.app"; build_good "$M"
printf 'x' >> "$M/Contents/MacOS/Fake"
WANT_FAILS=1 expect "bad-signature" "$M" 1 "codesign --verify 不通过" "${VARGS[@]}"

echo '==> 变异 7:Info.plist 没有 CFBundleExecutable(前置检查,直接退出 —— 走到下面那套判据毫无意义)'
M="$WORK/M7.app"; build_good "$M"
plutil -remove CFBundleExecutable "$M/Contents/Info.plist" >/dev/null 2>&1
codesign --force --deep --sign - "$M" >/dev/null 2>&1
WANT_FAILS=1 WANT_EARLY=1 expect "no-executable-key" "$M" 1 "没有 CFBundleExecutable" "${VARGS[@]}"

echo "==> 变异 8:词表本身写错(类别与字节数不符)。这一组验的不是产品,是「配置错」那三条断言有没有牙齿"
# 为什么要有这一组:2026-10-24 那次 universal 出包报 9 条「改动没进包」,真相是 9 个词全落在
# 9~15 字节的拆分档里(见 H209)—— 判据错的时候**必须报「判据写错了」**,不能报「功能没进包」,
# 否则下一个人会去查源码。而一条没人触发过的配置断言等于没有(同 H136 那条训)。
bad_verify() {   # $1=词表里的原词 $2=改坏后的词 $3=必须命中的说明片段
  sed "s|$1|$2|" "$VERIFY" > "$WORK/verify-bad.sh"
  chmod +x "$WORK/verify-bad.sh"
  WANT_FAILS=1 V="$WORK/verify-bad.sh" expect "bad-table-$1" "$GOOD" 1 "$3" "${VARGS[@]}"
}
bad_verify 'lit8:SHUFFLE'          'lit8:顺序播放'        '配置错:lit8 词「顺序播放」有 12 字节'
bad_verify 'lit16:square.and.pencil' 'lit16:repeat.1'     '配置错:lit16 词「repeat.1」只有 8 字节'
bad_verify 'sym:NoteStore'         'symx:NoteStore'       "配置错:判据词「NoteStore」的类别「symx」不认识"

echo "==> 自检结论:pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
