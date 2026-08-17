#!/bin/bash
#
# 打发布包。产物统一命名并放到 android/dist/(与鸿蒙端 harmony/build-release.sh 一致):
#   reverb.apk           已签名 —— 发布传这个
#   reverb-unsigned.apk  未签名 —— 缺 keystore.properties 时才会出现,不能发布
#   reverb-mapping.txt   R8 混淆映射 —— **务必留档并上传**,否则崩溃栈无法还原
#
# 用法:
#   ./build-release.sh            打 release APK
#   ./build-release.sh --bundle   同时打 AAB(Google Play 需要 AAB,应用市场用 APK)
#
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

[ -x ./gradlew ] || { echo "✗ 找不到 ./gradlew"; exit 1; }

# 签名材料检查。缺了不会构建失败,而是**静默打出未签名包** —— 那种包发布会被拒,
# 且不易察觉,所以提前说清楚。
SIGNED_EXPECTED=1
if [ ! -f keystore.properties ]; then
  SIGNED_EXPECTED=0
  echo "⚠ 缺 keystore.properties,将打出**未签名**包(不能发布)。"
  echo "  需要它包含 storeFile / storePassword / keyAlias / keyPassword 四项;"
  echo "  该文件与 .jks 都不入版本管理。"
fi

VER_NAME=$(sed -n 's/.*versionName "\([^"]*\)".*/\1/p' app/build.gradle | head -1)
VER_CODE=$(sed -n 's/.*versionCode \([0-9]*\).*/\1/p' app/build.gradle | head -1)
echo "▸ 余音 Reverb (Android)  versionName=$VER_NAME  versionCode=$VER_CODE"

echo "▸ 构建 release(R8 混淆 + 资源压缩)"
./gradlew assembleRelease -q
if [ "${1:-}" = "--bundle" ]; then
  echo "▸ 构建 AAB"
  ./gradlew bundleRelease -q
fi

DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -f "$DIST"/reverb.apk "$DIST"/reverb-unsigned.apk "$DIST"/reverb.aab "$DIST"/reverb-mapping.txt

APK=$(find app/build/outputs/apk/release -name "*.apk" | head -1)
[ -n "$APK" ] || { echo "✗ 没找到 release APK"; exit 1; }

# 用 apksigner 判定是否真的签了,以及签名者是谁 —— 不靠"有没有 keystore.properties"猜。
# 早先在鸿蒙端就吃过"以为签了其实是调试签名"的亏,这里直接验产物。
APKSIGNER=$(ls "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)
IS_SIGNED=0
SIGNER_DN=""
if [ -n "$APKSIGNER" ] && "$APKSIGNER" verify "$APK" >/dev/null 2>&1; then
  IS_SIGNED=1
  SIGNER_DN=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/^Signer #1 certificate DN: //p' | head -1)
fi

if [ "$IS_SIGNED" = "1" ]; then
  case "$SIGNER_DN" in
    *"CN=Android Debug"*)
      echo "✗ 这个包是**调试证书**签的($SIGNER_DN),发布会被拒。检查 keystore.properties。"
      exit 1;;
  esac
  cp "$APK" "$DIST/reverb.apk"
  OUT_NAME="reverb.apk"
else
  cp "$APK" "$DIST/reverb-unsigned.apk"
  OUT_NAME="reverb-unsigned.apk"
fi

# R8 映射:发布后要靠它还原崩溃栈,每个版本都必须留档
MAP=$(find app/build/outputs/mapping/release -name mapping.txt 2>/dev/null | head -1 || true)
[ -n "$MAP" ] && cp "$MAP" "$DIST/reverb-mapping.txt"
AAB=$(find app/build/outputs/bundle/release -name "*.aab" 2>/dev/null | head -1 || true)
[ -n "$AAB" ] && cp "$AAB" "$DIST/reverb.aab"

echo
echo "▸ 产物(android/dist/):"
for f in reverb.apk reverb-unsigned.apk reverb.aab reverb-mapping.txt; do
  [ -f "$DIST/$f" ] && printf '    %-22s %6s KB\n' "$f" "$(( $(stat -f%z "$DIST/$f") / 1024 ))"
done
echo
if [ "$IS_SIGNED" = "1" ]; then
  echo "✓ 已签名:$SIGNER_DN"
  echo "  发布传 dist/$OUT_NAME;dist/reverb-mapping.txt 请一并上传(崩溃栈还原)"
else
  echo "✗ 未签名 —— dist/$OUT_NAME 不能发布"
  exit 1
fi
