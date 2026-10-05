#!/bin/bash
# verify-bundle.sh 的自检:手搭一个假 bundle,先跑正向(必须通过),再把每条断言逐个弄坏
# (必须各自失败)。为什么需要它 —— 见 verify-bundle.sh 头部与 H136:
# 一条从没被执行过的断言,和没有断言是同一件事。而这里的断言恰恰**不能**靠"下次出包时顺带看看"
# 来验:package.sh 要走完 swift build 才到验收段,本仓库的开发机跑不了 swift build。
# 所以把验收段做成可以在任何 Mac 上独立跑的脚本,判据词与 bundle 都用假的造。
#
# 跑法:bash macos/tools/selftest-verify.sh      退出 0 = 正向通过 + 七道变异各自被抓到
# 依赖:clang / lipo / codesign / plutil(命令行工具链即可,不需要 Xcode,也不需要能编本工程)
set -uo pipefail
cd "$(dirname "$0")/.."          # → macos/
VERIFY="./verify-bundle.sh"
WORK=$(mktemp -d /tmp/selftest-verify.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# 判据词清单与 verify-bundle.sh 里那 11 个是**两份副本**,靠得住的原因是它们一漂就炸:
# 加了词而这里没加 → 正向用例的假 bundle 少那个词 → 正向 exit 1 → 本自检红。
# (而不是"两边各自演进也能过" —— 那种重复才是隐患。)变异用的「少一个词」版由这里派生。
WORDS='play_mode_map play_mode SEQUENTIAL REPEAT_ONE SHUFFLE 顺序播放 单曲循环 随机播放 notes.json 批注 记下这一秒'
LANGS=(en es fr zh-Hant)   # 五语里 zh-Hans 是基础语言(键即简体原文),所以 .lproj 只有四套

printf 'static const char *w = "%s";\nint main(void){return 0;}\nconst char *getw(void){return w;}\n' \
  "$WORDS" > "$WORK/all.c"
# 少最后一个词的版本(中文词按整串删,不做子串,免得删出半个 UTF-8 序列让 grep 行为变得不可预期)
printf 'static const char *w = "%s";\nint main(void){return 0;}\nconst char *getw(void){return w;}\n' \
  "${WORDS% 记下这一秒}" > "$WORK/less.c"

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
  out=$("$VERIFY" "$bundle" "$@" 2>&1); rc=$?
  if [ "$want_fails" -eq 0 ]; then concl="全部断言通过"; else concl="结论:$want_fails 条断言不通过"; fi
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

echo "==> 变异 1:二进制少一个判据词(记下这一秒)—— 架构仍是两个,所以只有词判据该失败"
M="$WORK/M1.app"; build_good "$M"
cp "$WORK/less_univ" "$M/Contents/MacOS/Fake"
codesign --force --deep --sign - "$M" >/dev/null 2>&1
WANT_FAILS=1 expect "missing-word" "$M" 1 "「记下这一秒」在二进制里 0 命中" "${VARGS[@]}"

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

echo "==> 自检结论:pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
