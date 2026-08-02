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
