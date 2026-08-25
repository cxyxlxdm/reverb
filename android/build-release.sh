#!/bin/bash
#
# 打发布包。产物统一命名并放到 android/dist/(与鸿蒙端 harmony/build-release.sh 一致):
#   reverb.apk           已签名 —— 发布传这个
#   reverb-unsigned.apk  未签名 —— 缺 keystore.properties 时才会出现,不能发布
#   reverb-mapping.txt   R8 混淆映射 —— **务必留档并上传**,否则崩溃栈无法还原
#
# 用法:
#   ./build-release.sh                 默认渠道 → dist/reverb.apk          (com.yuyin.reverb)
#   ./build-release.sh --store        商店渠道 → dist/reverb-store.apk   (com.yuyin.reverb.android)
#   ./build-release.sh [渠道] --bundle 同时打 AAB(Google Play 需要 AAB)
#
# 为什么有这个渠道:它是**大陆商店版**(各家应用市场 共用),与默认渠道功能不同
# (无内容目录,合规口径见 docs/BEIAN.md),故必须是独立包名 com.yuyin.reverb.android ——
# 否则商店更新会把功能完整的自分发版覆盖成删减版。默认渠道包名不变。
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

# 解析渠道参数
CHANNEL=default
BUNDLE=0
for a in "$@"; do
  case "$a" in
    --store) CHANNEL=store ;;
    --bundle) BUNDLE=1 ;;
    *) echo "✗ 未知参数:$a"; exit 1 ;;
  esac
done
if [ "$CHANNEL" = "store" ]; then
  GRADLE_FLAVOR=Store; APP_ID="com.yuyin.reverb.android"; OUT_APK=reverb-store.apk
else
  GRADLE_FLAVOR=Default; APP_ID="com.yuyin.reverb";        OUT_APK=reverb.apk
fi

# 默认渠道带离线语音识别,那两样东西**不入版本管理**(一个 57 MB 的模型 + 一个 .so),
# 由 tools/build-asr.sh 备好。缺了照样能构建成功,只是装上之后转写入口点了没反应 ——
# 那种"打出来才发现"的包最难查,所以在这里挡住。商店渠道压根不含引擎,不检查。
# 只有引擎真的启用时才检查 —— HAS_ENGINE 还没跑通时置了 false,
# 那种情况下默认渠道在任何机器上都该能直接构建,不该被这两个本地产物挡住。
ASR_ON=$(grep -c 'HAS_ENGINE = true' app/src/default/java/com/yuyin/reverb/playback/asr/AsrFactory.kt || true)
if [ "$CHANNEL" = "default" ] && [ "$ASR_ON" != "0" ]; then
  MISSING=0
  [ -f app/src/default/jniLibs/arm64-v8a/libreverb_asr.so ] || MISSING=1
  [ -f app/src/default/assets/whisper-model.bin ] || MISSING=1
  if [ "$MISSING" = "1" ]; then
    echo "✗ 默认渠道缺少离线识别的产物,先跑一次:"
    echo "    ./tools/build-asr.sh"
    echo "  (会编译 libreverb_asr.so 并下载 57 MB 的模型;只需跑一次)"
    exit 1
  fi
fi

VER_NAME=$(sed -n 's/.*versionName "\([^"]*\)".*/\1/p' app/build.gradle | head -1)
VER_CODE=$(sed -n 's/.*versionCode \([0-9]*\).*/\1/p' app/build.gradle | head -1)
echo "▸ 余音 Reverb (Android)  versionName=$VER_NAME  versionCode=$VER_CODE"
echo "  渠道=$CHANNEL  applicationId=$APP_ID"

echo "▸ 构建 release(R8 混淆 + 资源压缩)"
./gradlew "assemble${GRADLE_FLAVOR}Release" -q
if [ "$BUNDLE" = "1" ]; then
  echo "▸ 构建 AAB"
  ./gradlew "bundle${GRADLE_FLAVOR}Release" -q
fi

DIST="$ROOT/dist"
mkdir -p "$DIST"
VARIANT_DIR=$(echo "$CHANNEL" | tr 'A-Z' 'a-z')Release
rm -f "$DIST/$OUT_APK" "$DIST/${OUT_APK%.apk}-unsigned.apk" "$DIST/${OUT_APK%.apk}.aab" "$DIST/${OUT_APK%.apk}-mapping.txt"

APK=$(find "app/build/outputs/apk/$CHANNEL/release" -name "*.apk" 2>/dev/null | head -1)
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
  cp "$APK" "$DIST/$OUT_APK"
  OUT_NAME="$OUT_APK"
else
  OUT_NAME="${OUT_APK%.apk}-unsigned.apk"
  cp "$APK" "$DIST/$OUT_NAME"
fi

# 校验产物里的 applicationId 与渠道一致 —— 渠道搞错会传错包,而两个包长得一模一样
AAPT=$(ls "$SDK"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$AAPT" ]; then
  REAL_ID=$("$AAPT" dump packagename "$DIST/$OUT_NAME" 2>/dev/null || true)
  if [ -n "$REAL_ID" ] && [ "$REAL_ID" != "$APP_ID" ]; then
    echo "✗ 产物包名是 $REAL_ID,与渠道 $CHANNEL 期望的 $APP_ID 不一致"; exit 1
  fi
  echo "  产物包名校验通过:$REAL_ID"
fi

# R8 映射:发布后要靠它还原崩溃栈,每个版本都必须留档
MAP=$(find "app/build/outputs/mapping/${CHANNEL}Release" -name mapping.txt 2>/dev/null | head -1 || true)
[ -n "$MAP" ] && cp "$MAP" "$DIST/${OUT_APK%.apk}-mapping.txt"
AAB=$(find "app/build/outputs/bundle/${CHANNEL}Release" -name "*.aab" 2>/dev/null | head -1 || true)
[ -n "$AAB" ] && cp "$AAB" "$DIST/${OUT_APK%.apk}.aab"

echo
echo "▸ 产物(android/dist/):"
for f in "$OUT_APK" "${OUT_APK%.apk}-unsigned.apk" "${OUT_APK%.apk}.aab" "${OUT_APK%.apk}-mapping.txt"; do
  [ -f "$DIST/$f" ] && printf '    %-22s %6s KB\n' "$f" "$(( $(stat -f%z "$DIST/$f") / 1024 ))"
done
echo
if [ "$IS_SIGNED" = "1" ]; then
  echo "✓ 已签名:$SIGNER_DN"
  echo "  发布传 dist/$OUT_NAME;dist/${OUT_APK%.apk}-mapping.txt 请一并上传(崩溃栈还原)"
else
  echo "✗ 未签名 —— dist/$OUT_NAME 不能发布"
  exit 1
fi
