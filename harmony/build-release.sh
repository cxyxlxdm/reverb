#!/bin/bash
#
# 打发布包。产物统一命名并放到 harmony/dist/:
#   reverb.app           已签名 —— 传应用市场用这个
#   reverb-unsigned.app  未签名 —— 一般不用,留着备查
#   reverb-symbol.zip    符号文件 —— 建议一并上传,崩溃栈才能还原
#
# 用法:
#   ./build-release.sh            打 release(默认清构建缓存,见下)
#   ./build-release.sh --fast     跳过清缓存(赶时间时用,但有风险,见下)
#
# 为什么默认清缓存:hvigor 的资源编译任务会命中缓存 —— 换过图标/字符串后照常
# BUILD SUCCESSFUL,但包里仍是旧资源(踩过一次,详见 TROUBLESHOOTING H39)。
# 发布包一年打不了几次,宁可多等 10 秒。
#
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"

export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
HVIGOR="${HVIGOR:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"

[ -x "$HVIGOR" ] || { echo "✗ 找不到 hvigorw:$HVIGOR(可用 HVIGOR=... 覆盖)"; exit 1; }

# 缺任何一样签名材料都会在 SignHap 阶段失败,提前说清楚比看 hvigor 的报错友好
MISSING=()
for f in signature/reverb.p12 signature/reverb.cer signature/reverb.p7b; do
  [ -f "$f" ] || MISSING+=("$f")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "✗ 缺少发布签名材料:"
  printf '    %s\n' "${MISSING[@]}"
  echo "  .cer 在 分发平台「证书管理」用 signature/reverb.csr 换取;"
  echo "  .p7b 在 分发平台「Profile 管理」按包名 com.yuyin.reverb 申请(类型选发布)。"
  exit 1
fi

VER_NAME=$(sed -n 's/.*"versionName"[^"]*"\([^"]*\)".*/\1/p' AppScope/app.json5 | head -1)
VER_CODE=$(sed -n 's/.*"versionCode"[^0-9]*\([0-9]*\).*/\1/p' AppScope/app.json5 | head -1)
echo "▸ 余音 Reverb  versionName=$VER_NAME  versionCode=$VER_CODE"

if [ "${1:-}" != "--fast" ]; then
  echo "▸ 清理构建缓存(避免资源走缓存,见脚本头部说明)"
  rm -rf build entry/build .hvigor/cache
fi

echo "▸ 构建 release(含混淆)"
"$HVIGOR" assembleApp --mode project -p product=release -p buildMode=release --no-daemon \
  | grep -iE "ERROR|WARN|BUILD SUCCESSFUL|BUILD FAILED" || true

OUT="build/outputs/release"
[ -d "$OUT" ] || { echo "✗ 没有产物目录 $OUT,构建应该失败了"; exit 1; }

DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -f "$DIST"/reverb.app "$DIST"/reverb-unsigned.app "$DIST"/reverb-symbol.zip

SIGNED=$(ls "$OUT"/*-signed.app 2>/dev/null | head -1 || true)
UNSIGNED=$(ls "$OUT"/*-unsigned.app 2>/dev/null | head -1 || true)
SYMBOL="$OUT/symbol/release/app-symbol.zip"

[ -n "$UNSIGNED" ] && cp "$UNSIGNED" "$DIST/reverb-unsigned.app"
[ -f "$SYMBOL" ]   && cp "$SYMBOL"   "$DIST/reverb-symbol.zip"

if [ -z "$SIGNED" ]; then
  echo "✗ 没有生成已签名包,只有 unsigned。检查 build-profile.json5 的 release 签名配置。"
  exit 1
fi
cp "$SIGNED" "$DIST/reverb.app"

# 关键校验:确认签的是发布证书而不是调试证书。
# 早先就因为用调试签名打了"发布包",这一条能挡住同类事故。
HAP=$(mktemp -d)/entry.hap
unzip -p "$DIST/reverb.app" '*.hap' > "$HAP" 2>/dev/null || true
if grep -aq debugKey "$HAP" 2>/dev/null; then
  echo "✗ 包内含 debugKey —— 这是**调试签名**,应用市场会拒。请检查 product=release 的签名配置。"
  exit 1
fi

echo
echo "▸ 产物(harmony/dist/):"
for f in reverb.app reverb-unsigned.app reverb-symbol.zip; do
  [ -f "$DIST/$f" ] && printf '    %-22s %6s KB\n' "$f" "$(( $(stat -f%z "$DIST/$f") / 1024 ))"
done
echo
echo "✓ 发布传 dist/reverb.app;符号文件 dist/reverb-symbol.zip 建议一并上传"
echo "  已确认不含 debugKey(发布签名)"
