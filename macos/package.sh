#!/bin/bash
# 编译(universal)→ 组装 .app bundle → ad-hoc 签名 → 解包验收(含架构硬断言)→ 打 .dmg(进 dist/)。
#
# 为什么要末尾那一整段验收:AGENTS.md 硬规矩 1 说「包里有 / 没有,都必须可验证」,
# 而 macOS 端此前只有 `swift build` 一句,打完就交付,从没核对过 bundle 里到底有什么。
# 2026-09-29 移植播放模式时,本机跑不起来构建(Swift 5.7 / 无 Xcode),
# 才发现 `build/` 里躺着一个 9 天前别的机器打的 1.0.2 dmg —— 既不在 dist/ 也无人验收过。
# 所以这里把「出包 → 落到 dist/ → 当场解包核对」焊成一条命令,换机器跑也不会漏。
#
# 为什么默认出 universal(两个架构):`swift build` 不带 --arch 时**只跟随构建机芯片**。
# 1.0.2 那个包就是这么变成 arm64 单架构的(`lipo -archs` = arm64),而 arm64-only 的二进制
# 在 Intel Mac 上没有退路可跑(Rosetta 只做 x86→arm 这一个方向)⇒ 所有 Intel 用户装上打不开。
# SwiftPM 支持 `--arch arm64 --arch x86_64` 一次出两份再合,但它**有静默失败的前科**
# (swiftlang/swift-package-manager#8013:多 --arch 在部分版本上报错或只出一份)。
# 所以这里不信任构建日志,只在产物上断言:少一个架构就当场退出,别让包带病出门。
set -euo pipefail
cd "$(dirname "$0")"

APP="Reverb"
CONFIG="release"
# 出包架构:与「在架的那台构建机芯片」解耦。要单架构改这里即可。
ARCHS=(--arch arm64 --arch x86_64)

echo "==> swift build ($CONFIG ${ARCHS[*]})"
swift build -c "$CONFIG" "${ARCHS[@]}"
BINDIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

# 架构硬断言(在组装 .app 之前,免得失败时浪费一次签名与打包)。
# 判据只看产物,不看构建日志:SwiftPM 多 --arch 可能只出一份。
# 期望集合直接取自主命令的 --arch 列表,所以改 ARCHS 出单架构时这条断言不会反过来卡住。
EXPECTED=()
prev=""
for a in "${ARCHS[@]}"; do
  [ "$prev" = "--arch" ] && EXPECTED+=("$a")
  prev="$a"
done
assert_archs() {
  local bin="$1" label="$2" got
  got="$(lipo -archs "$bin" 2>/dev/null || echo '')"
  echo "==> 架构断言:$label lipo -archs = '${got}'(期望:${EXPECTED[*]})"
  for want in "${EXPECTED[@]}"; do
    case " $got " in
      *" $want "*) echo "   ok: $want" ;;
      *) echo "   ✗ $label 缺 $want —— 这个包在对应芯片的 Mac 上跑不起来,不出 dmg。"
         echo "     多 --arch 走 xcbuild,**只有完整 Xcode 有,CLT 没有**(2026-09-30 在 CLT-only 机器上实测:"
         echo "     error: xcbuild executable ... does not exist)。遇到这种机器请退回:分别 --arch 编译两次再 lipo -create 合并。"
         exit 1 ;;
    esac
  done
}
[ -x "$BINDIR/ReverbWidget" ] || { echo "   ✗ 找不到 $BINDIR/ReverbWidget —— SwiftPM 没编出卡片扩展(检查 Package.swift 的 ReverbWidget target)"; exit 1; }
assert_archs "$BINDIR/$APP" "主程序"
assert_archs "$BINDIR/ReverbWidget" "卡片扩展"

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

# ---- 卡片扩展(WidgetKit)---------------------------------------------------
# SwiftPM 只会给出一个可执行文件,不认 .appex 这种 bundle;这里把它按宿主 App 的布局装进去:
#   Reverb.app/Contents/PlugIns/ReverbWidget.appex/Contents/{Info.plist,MacOS/,Resources/}
# 扩展的 Info.plist 里版本两项**从宿主抄**:WidgetKit 发现版本不一致时不会装载,
# 而版本号在本仓库有四处要手改(AGENTS.md),不能让第五处再成为漏改点。
APPEX="$BUNDLE/Contents/PlugIns/ReverbWidget.appex"
echo "==> assemble $APPEX"
rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$BINDIR/ReverbWidget" "$APPEX/Contents/MacOS/ReverbWidget"
cp Widget/Info.plist "$APPEX/Contents/Info.plist"
cp -R Widget/Localization/*.lproj "$APPEX/Contents/Resources/"
APP_VER="$(plutil -extract CFBundleShortVersionString raw "$BUNDLE/Contents/Info.plist")"
APP_BUILD="$(plutil -extract CFBundleVersion raw "$BUNDLE/Contents/Info.plist")"
plutil -replace CFBundleShortVersionString -string "$APP_VER" "$APPEX/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$APP_BUILD" "$APPEX/Contents/Info.plist"

echo "==> ad-hoc codesign"
# 顺序要紧:先签内层 appex(带 entitlements),再签外层 app。
# 外层**不带 --deep** —— 带它会把内层按同一套参数重签一遍,沙箱与只读例外就丢了(卡片读不到数据)。
codesign --force --sign - --entitlements Widget/ReverbWidget.entitlements "$APPEX"
codesign --force --sign - "$BUNDLE"

# ---- 解包验收(硬规矩 1)---------------------------------------------------
# 断言在 ./verify-bundle.sh 里,不在这里:那个脚本要能脱离 swift build 单独跑,
# 才好在没有完整 Xcode 的机器上拿假 bundle 自检(见 tools/selftest-verify.sh)。
# 期望架构与 verify 共用同一个 EXPECTED;期望语言取自 Localization/ —— 和上面那行
# `cp -R Localization/*.lproj` 同源,所以加一门语言只需要改 Localization/,判据自己跟上。
LANGS=()
for d in Localization/*.lproj; do
  [ -d "$d" ] && LANGS+=("$(basename "$d" .lproj)")   # 没有匹配时 glob 会原样留下,所以要判 -d
done
if [ ${#LANGS[@]} -eq 0 ]; then
  echo "   ✗ Localization/ 下一套 .lproj 都没有 —— 验收无法断言语言集合,不出 dmg。"
  exit 1
fi
./verify-bundle.sh "$BUNDLE" "${EXPECTED[@]}" --langs "${LANGS[@]}"
# --------------------------------------------------------------------------

echo "==> build dmg"
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# 上架/交付物一律落 dist/(与 android、harmony 同规矩);build/ 只是中间产物。
# 文件名带版本与架构:dist/ 里会同时躺着历史包,不带版本的文件名一旦重名就只能靠 mtime 猜是哪个。
# 架构标记**由 EXPECTED 推导,不再写死 universal** —— 1.0.2 那个包正是"名字叫 universal、
# 实际 arm64 单架构"才让 Intel 用户装不上却看不出来;写死的字符串只会重复同一个错误。
mkdir -p dist
VER="$APP_VER"
if [ "${#EXPECTED[@]}" -gt 1 ]; then TAG="universal"; else TAG="${EXPECTED[0]}"; fi
DMG="dist/余音-Reverb-${VER}-${TAG}.dmg"
rm -f "$DMG"
hdiutil create -volname "余音 Reverb" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "==> done: $DMG"
ls -la "$DMG"
