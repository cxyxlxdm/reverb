#!/bin/bash
# 编译 → 组装 .app bundle → ad-hoc 签名 → 打 .dmg。全程命令行,无需 Xcode GUI。
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

echo "==> build dmg"
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/余音-Reverb.dmg"
rm -f "$DMG"
hdiutil create -volname "余音 Reverb" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "==> done: $DMG"
ls -la "$DMG"
