#!/bin/bash
# 编译 → 组装 .app bundle → ad-hoc 签名 → 解包验收 → 打 .dmg(进 dist/)。
#
# 为什么要末尾那一整段验收:AGENTS.md 硬规矩 1 说「包里有 / 没有,都必须可验证」,
# 而 macOS 端此前只有 `swift build` 一句,打完就交付,从没核对过 bundle 里到底有什么。
# 2026-09-29 移植播放模式时,本机跑不起来构建(Swift 5.7 / 无 Xcode),
# 才发现 `build/` 里躺着一个 9 天前别的机器打的 1.0.2 dmg —— 既不在 dist/ 也无人验收过。
# 所以这里把「出包 → 落到 dist/ → 当场解包核对」焊成一条命令,换机器跑也不会漏。
set -euo pipefail
cd "$(dirname "$0")"

APP="Reverb"
CONFIG="release"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"

BUNDLE="build/${APP}.app"
echo "==> assemble $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINDIR/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp Info.plist "$BUNDLE/Contents/Info.plist"
# 若有图标资源则带上
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns" || true

# 本地化资源:各语言 .lproj 拷入 Resources(zh-Hans 为基础语言,键即简体中文原文)
cp -R Localization/*.lproj "$BUNDLE/Contents/Resources/"

# 内置精选清单:发现页在无缓存/无网时的兜底内容(规范副本在 shared/seed/,由 sync.sh 分发)。
# 缺了不会构建失败,只是退化成"首屏可能空白",所以这里显式提示一声。
if [ -f "Resources/seed_podcasts.json" ]; then
  cp "Resources/seed_podcasts.json" "$BUNDLE/Contents/Resources/seed_podcasts.json"
else
  echo "   ⚠ 缺 Resources/seed_podcasts.json,发现页将无内置兜底(跑 shared/seed/sync.sh 补上)"
fi

# 内置引导音频:首次使用时可直接播放,用来验证整条播放链路(规范副本在 shared/guide/)
if [ -f "Resources/guide_intro.m4a" ]; then
  cp "Resources/guide_intro.m4a" "$BUNDLE/Contents/Resources/guide_intro.m4a"
else
  echo "   ⚠ 缺 Resources/guide_intro.m4a,首启不显示引导入口(跑 shared/guide/sync.sh 补上)"
fi

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$BUNDLE"

# ---- 解包验收(硬规矩 1)---------------------------------------------------
# 处理量先行:没有「扫了多少」,后面的 0 不成立(见 zero-hit-must-prove-scan)。
BIN="$BUNDLE/Contents/MacOS/$APP"
RES="$BUNDLE/Contents/Resources"
LPROJ=$(find "$RES" -maxdepth 1 -name '*.lproj' -type d | wc -l | tr -d ' ')
echo "==> 验收:处理量 —— 二进制 $(wc -c <"$BIN" | tr -d ' ') B / .lproj $LPROJ 套 / Resources $(find "$RES" -maxdepth 1 | wc -l | tr -d ' ') 项"

# 期望非 0:播放模式这批改动确实在包里。字符串字面量会留在二进制里,
# 所以「键即简体原文」的那三个词与两个 UserDefaults 键名都是可判据。
# 注意 `play_mode` 那一行会把 `play_mode_map` 的命中一起算进去(它是它的前缀),
# 所以它恒 ≥ play_mode_map —— 这是预期的,不是重复计数错误。
# 期望 0:老包(1.0.2)里这些词全部 0 命中 —— 2026-09-29 拿 build/ 里那个旧 dmg
# 实测过这组负控制(play_mode_map / SEQUENTIAL / 顺序播放 均 0),所以非 0 才有意义。
for w in play_mode_map play_mode SEQUENTIAL REPEAT_ONE SHUFFLE 顺序播放 单曲循环 随机播放; do
  printf '   %-14s %s\n' "$w" "$(LC_ALL=C grep -a -o "$w" "$BIN" | wc -l | tr -d ' ')"
done

echo "   本地化:$(find "$RES" -name 'Localizable.strings' | wc -l | tr -d ' ') 份 .strings,lint 结果:"
for f in "$RES"/*.lproj/Localizable.strings; do
  printf '      %s %s\n' "$(basename "$(dirname "$f")")" "$(plutil -lint "$f" | awk -F': ' '{print $NF}')"
done

echo "   版本与运行门槛:"
plutil -p "$BUNDLE/Contents/Info.plist" | grep -E 'CFBundleShortVersionString|CFBundleVersion|LSMinimumSystemVersion' | sed 's/^/      /'
vtool -show-build "$BIN" 2>/dev/null | grep -E 'minos|sdk|platform' | sed 's/^/      /' || true
echo "      架构:$(lipo -archs "$BIN" 2>/dev/null || echo unknown)(单架构包在另一台芯片的机器上跑不起来,发版前要出 universal)"
codesign -dvv "$BUNDLE" 2>&1 | grep -E 'Signature=|Format=|Identifier=' | sed 's/^/      /'
# --------------------------------------------------------------------------

echo "==> build dmg"
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# 上架/交付物一律落 dist/(与 android、harmony 同规矩);build/ 只是中间产物。
mkdir -p dist
DMG="dist/余音-Reverb.dmg"
rm -f "$DMG"
hdiutil create -volname "余音 Reverb" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "==> done: $DMG"
ls -la "$DMG"
