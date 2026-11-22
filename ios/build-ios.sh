#!/bin/bash
# iOS 出包:编译验收 / 归档 / 导出 ipa / 上传 TestFlight。
#
# 为什么单独一份:macOS 走 SwiftPM(`macos/package.sh`),Android 与鸿蒙各有 `build-release.sh`;
# iOS 是 Xcode 工程,产物是 .xcarchive / .ipa,命令与验收判据都不同。
# 与另三端一样,**出包与验收焊成一条命令**(硬规矩 1、20):产物落 dist/,当场解包核对。
#
# 用法:
#   ./build-ios.sh                 # 只编译 + 验收(不需要签名,本机就能跑)
#   ./build-ios.sh --archive       # 归档成 .xcarchive(需要签名:DEVELOPMENT_TEAM 环境变量)
#   ./build-ios.sh --export        # 归档 + 导出 .ipa 到 dist/
#   ./build-ios.sh --upload        # 归档 + 导出 + 上传 App Store Connect(TestFlight)
#   BUILD_NUMBER=2 ./build-ios.sh --upload   # 覆盖构建号(TestFlight 每次上传必须递增)
#
# 签名与凭据都从环境变量读,**不写进工程文件、不改任何签名材料**
# (本项目约束:keystore / 口令 / 签名配置一律只读):
#   签名:  DEVELOPMENT_TEAM=<10 位 Team ID>
#   上传(二选一):
#     ① App Store Connect API Key:ASC_KEY_ID + ASC_ISSUER_ID
#        私钥 AuthKey_<ASC_KEY_ID>.p8 放在 altool 会找的位置之一:
#        ./private_keys/ · ~/private_keys/ · ~/.appstoreconnect/private_keys/
#     ② Apple ID:ASC_USERNAME + ASC_PASSWORD(专用密码,不是账号密码)
#
# 前提(缺一不可,脚本逐条检查并给出下一步):
#   · Xcode + iOS SDK(本机 Xcode 27.2 / iOS 27.2)
#   · Apple Developer Program 会员(TestFlight 需要;免费账号不能传)
#   · App Store Connect 里已创建 bundle id 为 com.yuyin.reverb 的 App 记录
#   · 签名:自动签名 + 上面那个 DEVELOPMENT_TEAM
# 详见 docs/IOS.md。
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="Reverb.xcodeproj"
SCHEME="Reverb"
CONFIG="Release"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release-iphoneos/Reverb.app"
ARCHIVE="build/Reverb.xcarchive"
EXPORT_DIR="build/export"
DIST="dist"
BUNDLE_ID="com.yuyin.reverb"

mode="verify"
case "${1:-}" in
  ""|--verify)   mode="verify" ;;
  --archive)     mode="archive" ;;
  --export)      mode="export" ;;
  --upload)      mode="upload" ;;
  -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
  *) echo "未知参数:$1(用 --help 看用法)"; exit 2 ;;
esac

say() { printf '==> %s\n' "$*"; }
die() { printf '   ✗ %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 期望值
# 版本号来自工程设置(pbxproj),不从 Info.plist 反推 —— 反推等于用产物给自己出题。
SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null)"
expect_ver="$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')"
expect_build="$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *CURRENT_PROJECT_VERSION = /{print $2; exit}')"
[ -n "$expect_ver" ] || die "读不到 MARKETING_VERSION(工程设置异常)"
[ -n "$expect_build" ] || die "读不到 CURRENT_PROJECT_VERSION(工程设置异常)"
if [ -n "${BUILD_NUMBER:-}" ]; then
  expect_build="$BUILD_NUMBER"
fi
expect_product="$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *FULL_PRODUCT_NAME = /{print $2; exit}')"
[ "$expect_product" = "Reverb.app" ] || die "产物名不是 Reverb.app(实际 '$expect_product'),脚本里的路径要跟着改"

LANGS=()
for d in Localization/*.lproj; do
  [ -d "$d" ] && LANGS+=("$(basename "$d" .lproj)")
done
[ ${#LANGS[@]} -gt 0 ] || die "Localization/ 下一套 .lproj 都没有"

# ---------------------------------------------------------------- 验收
# 判据全部用退出码,不靠"打印出来看着像"。
verify_bundle() {
  local app="$1"
  [ -d "$app" ] || die "找不到 bundle:$app"

  local files bytes
  files="$(find "$app" -type f | wc -l | tr -d ' ')"
  bytes="$(du -sk "$app" | awk '{print $1}')"
  say "验收 $app(处理量:$files 个文件 / ${bytes} KB)"

  # 1) 版本与构建号
  local ver build minos
  ver="$(plutil -extract CFBundleShortVersionString raw "$app/Info.plist")" \
    || die "Info.plist 里没有 CFBundleShortVersionString"
  build="$(plutil -extract CFBundleVersion raw "$app/Info.plist")" \
    || die "Info.plist 里没有 CFBundleVersion"
  minos="$(plutil -extract MinimumOSVersion raw "$app/Info.plist")" \
    || die "Info.plist 里没有 MinimumOSVersion"
  [ "$ver" = "$expect_ver" ] || die "版本号 $ver ≠ 工程里的 $expect_ver"
  [ "$build" = "$expect_build" ] || die "构建号 $build ≠ 期望的 $expect_build"
  case "$minos" in
    17.0|17.*|18.*|26.*|27.*) ;;
    *) die "MinimumOSVersion=$minos,与 IPHONEOS_DEPLOYMENT_TARGET=17.0 不符" ;;
  esac
  echo "   ok: 版本 $ver($build)/ 最低 iOS $minos"

  # 2) 背景播放:没有它,锁屏就会停
  plutil -extract UIBackgroundModes json -o - "$app/Info.plist" | grep -q '"audio"' \
    || die "Info.plist 缺 UIBackgroundModes=audio"
  echo "   ok: UIBackgroundModes 含 audio"

  # 2b) 实时活动:缺这个键时 `Activity.request` 不抛错、活动也不出现(模拟器上
  #     表现为"什么都没发生" —— 2026-11-15 实测过一次旧包),所以必须在门上拦。
  [ "$(plutil -extract NSSupportsLiveActivities raw "$app/Info.plist" 2>/dev/null || true)" = "true" ] \
    || die "Info.plist 缺 NSSupportsLiveActivities=true(锁屏 / 灵动岛的实时活动不会出现)"
  echo "   ok: NSSupportsLiveActivities=true"

  # 3) 本地化集合相等(不是"至少有")
  local got
  got="$(plutil -extract CFBundleLocalizations json -o - "$app/Info.plist" | tr -d '[]" \n' | tr ',' '\n' | sed '/^$/d' | sort)"
  local want
  want="$(printf '%s\n' zh-Hans "${LANGS[@]}" | sort)"
  [ "$got" = "$want" ] || die "CFBundleLocalizations 集合不符:得到 [$got],期望 [$want]"
  local n=0
  for d in "$app"/*.lproj; do
    [ -d "$d" ] || die "bundle 里一套 .lproj 都没有"
    [ -s "$d/Localizable.strings" ] || die "$(basename "$d") 里缺 Localizable.strings"
    plutil -lint "$d/Localizable.strings" >/dev/null || die "$(basename "$d") 的 .strings 不是合法 plist"
    # 权限说明会弹在用户面前,英文界面下弹中文等于没本地化(见 H246 同族问题)
    [ -s "$d/InfoPlist.strings" ] || die "$(basename "$d") 里缺 InfoPlist.strings"
    plutil -lint "$d/InfoPlist.strings" >/dev/null || die "$(basename "$d") 的 InfoPlist.strings 不是合法 plist"
    for k in NSPhotoLibraryAddUsageDescription NSSpeechRecognitionUsageDescription; do
      [ -n "$(plutil -extract "$k" raw -o - "$d/InfoPlist.strings" 2>/dev/null)" ] \
        || die "$(basename "$d") 的 InfoPlist.strings 缺 $k"
    done
    n=$((n + 1))
  done
  [ "$n" -eq "${#LANGS[@]}" ] || die "bundle 里 $n 套 .lproj,期望 ${#LANGS[@]} 套(简中是基础语言,没有 zh-Hans.lproj)"
  echo "   ok: $n 套 .lproj 全部可 lint(键名即简体中文原文)"

  # 4) 内置物料
  [ -s "$app/seed_podcasts.json" ] || die "缺 seed_podcasts.json(发现页无兜底)"
  [ -s "$app/guide_intro.m4a" ] || die "缺 guide_intro.m4a(首启引导不可用)"
  [ -s "$app/radio_stations.json" ] || die "缺 radio_stations.json(电台页无内置兜底)"
  echo "   ok: seed_podcasts.json / guide_intro.m4a / radio_stations.json 都在"

  # 5) 图标(TestFlight 不收缺图标的包)
  [ -f "$app/AppIcon60x60@2x.png" ] || die "缺 AppIcon60x60@2x.png —— 上传会被拒"
  echo "   ok: 应用图标已编译进包"

  # 5b) 桌面卡片扩展:嵌入阶段漏掉 .appex 时 App 照常能跑、卡片却永远不出现 ——
  #     这一条是"卡片真的进了包"的唯一判据(硬规矩 20:解包看,不看构建日志)。
  local appex="$app/PlugIns/ReverbWidget.appex"
  [ -d "$appex" ] || die "缺小组件扩展 ReverbWidget.appex(嵌入阶段没把 target 带进包)"
  local point
  point="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$appex/Info.plist" 2>/dev/null || true)"
  [ "$point" = "com.apple.widgetkit-extension" ] || die "appex 的 NSExtensionPointIdentifier 不是 widgetkit-extension(实际 '$point')"
  local wver wbuild
  wver="$(plutil -extract CFBundleShortVersionString raw "$appex/Info.plist" 2>/dev/null || true)"
  wbuild="$(plutil -extract CFBundleVersion raw "$appex/Info.plist" 2>/dev/null || true)"
  [ "$wver" = "$expect_ver" ] || die "appex 版本 $wver ≠ 主包 $expect_ver"
  [ "$wbuild" = "$expect_build" ] || die "appex 构建号 $wbuild ≠ 主包 $expect_build"
  local wn=0
  for d in "$appex"/*.lproj; do
    [ -d "$d" ] || continue
    plutil -lint "$d/Localizable.strings" >/dev/null || die "appex $(basename "$d") 的 .strings 不是合法 plist"
    # 编进包之后 .strings 会变成二进制 plist,中文键在这里是 UTF-16,不能用 grep 找
    [ -n "$(plutil -extract "继续收听" raw -o - "$d/Localizable.strings" 2>/dev/null)" ] \
      || die "appex $(basename "$d") 缺卡片画廊文案"
    wn=$((wn + 1))
  done
  [ "$wn" -eq "${#LANGS[@]}" ] || die "appex 里 $wn 套 .lproj,期望 ${#LANGS[@]} 套(简中是基础语言)"
  echo "   ok: ReverbWidget.appex 在包内(版本 $wver/$wbuild,$wn 套本地化)"

  # 6) 二进制架构:设备包只有 arm64;出现 x86_64 说明拿错了模拟器产物
  local archs
  archs="$(lipo -archs "$app/Reverb" 2>/dev/null || echo '')"
  [ -n "$archs" ] || die "读不出二进制架构:$app/Reverb"
  case " $archs " in
    *" arm64 "*) ;;
    *) die "二进制架构 '$archs' 里没有 arm64" ;;
  esac
  case " $archs " in
    *" x86_64 "*) die "设备包不该有 x86_64(实际 '$archs')" ;;
  esac
  echo "   ok: 二进制架构 = $archs"
}

# ---------------------------------------------------------------- 编译
build_unsigned() {
  say "编译($CONFIG / 不签名)—— 这是本机不需要任何证书就能跑的编译门"
  rm -rf "$DERIVED"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$expect_ver" CURRENT_PROJECT_VERSION="$expect_build" \
    build > build/compile.log 2>&1 \
    || { tail -40 build/compile.log >&2; die "编译失败(完整日志 build/compile.log)"; }
  verify_bundle "$APP"
}

# ---------------------------------------------------------------- 归档 / 导出 / 上传
require_team() {
  [ -n "${DEVELOPMENT_TEAM:-}" ] \
    || die "缺 DEVELOPMENT_TEAM。用法:DEVELOPMENT_TEAM=<10 位 Team ID> $0 ${1}"
  say "签名团队:${DEVELOPMENT_TEAM}(只作为命令行参数传入,不写进工程文件)"
}

do_archive() {
  require_team "--archive"
  rm -rf "$ARCHIVE"
  say "归档 → $ARCHIVE"
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    MARKETING_VERSION="$expect_ver" CURRENT_PROJECT_VERSION="$expect_build" \
    > build/archive.log 2>&1 \
    || { tail -40 build/archive.log >&2; die "归档失败。先看 Xcode 里是否已登录开发者账号、App 记录是否已创建(见 docs/IOS.md)"; }
  verify_bundle "$ARCHIVE/Products/Applications/Reverb.app"
  say "归档完成:$(du -sh "$ARCHIVE" | awk '{print $1}')"
}

do_export() {
  [ -d "$ARCHIVE" ] || do_archive
  rm -rf "$EXPORT_DIR"; mkdir -p "$EXPORT_DIR" "$DIST"
  local opts="build/exportOptions.plist"
  cat > "$opts" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${DEVELOPMENT_TEAM:-}</string>
  <key>uploadSymbols</key><true/>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
  say "导出 ipa(app-store-connect 方法)"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$opts" \
    -allowProvisioningUpdates \
    > build/export.log 2>&1 \
    || { tail -40 build/export.log >&2; die "导出失败(完整日志 build/export.log)"; }

  local ipa
  ipa="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
  [ -n "$ipa" ] || die "导出成功但 $EXPORT_DIR 里没有 .ipa"
  local out="$DIST/reverb-ios-${expect_ver}-${expect_build}.ipa"
  cp "$ipa" "$out"

  # ipa 是 zip:解出来再核一遍,别只信导出日志
  local tmp; tmp="$(mktemp -d)"
  unzip -q "$out" -d "$tmp"
  verify_bundle "$tmp/Payload/Reverb.app"
  # 归档后必须带签名与描述文件,否则 TestFlight 会拒
  [ -s "$tmp/Payload/Reverb.app/embedded.mobileprovision" ] || die "ipa 里没有 embedded.mobileprovision(签名没进去)"
  codesign --verify --deep --strict "$tmp/Payload/Reverb.app" \
    || die "codesign --verify 失败 —— 这个 ipa 上传也会被拒"
  rm -rf "$tmp"
  echo "   ok: ipa 已签名、描述文件在包内"
  say "done: $out($(du -h "$out" | awk '{print $1}'))"
}

do_upload() {
  [ -f "$DIST/reverb-ios-${expect_ver}-${expect_build}.ipa" ] || do_export
  local ipa="$DIST/reverb-ios-${expect_ver}-${expect_build}.ipa"

  local -a auth
  if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    local found=""
    for p in "./private_keys/AuthKey_${ASC_KEY_ID}.p8" \
             "$HOME/private_keys/AuthKey_${ASC_KEY_ID}.p8" \
             "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"; do
      [ -s "$p" ] && { found="$p"; break; }
    done
    [ -n "$found" ] || die "找不到 AuthKey_${ASC_KEY_ID}.p8。把它放到 ~/.appstoreconnect/private_keys/(altool 会去那里找)"
    say "App Store Connect API Key:${ASC_KEY_ID}(私钥 $found)"
    auth=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID")
  elif [ -n "${ASC_USERNAME:-}" ] && [ -n "${ASC_PASSWORD:-}" ]; then
    say "Apple ID 上传:${ASC_USERNAME}(专用密码)"
    auth=(-u "$ASC_USERNAME" -p "@env:ASC_PASSWORD")
  else
    die "缺上传凭据。二选一:① ASC_KEY_ID + ASC_ISSUER_ID + AuthKey_<id>.p8;② ASC_USERNAME + ASC_PASSWORD(专用密码)。见 docs/IOS.md"
  fi

  say "上传 TestFlight(先 validate 再 upload)"
  xcrun altool --validate-app -f "$ipa" -t ios "${auth[@]}" \
    || die "validate 失败 —— 多数是包/版本/描述文件问题,看上面的错误码"
  xcrun altool --upload-app -f "$ipa" -t ios "${auth[@]}" \
    || die "上传失败"
  say "已上传。到 App Store Connect → TestFlight 等处理完成;内部测试员立即可装,外部测试员需过一次 Beta App Review。"
}

mkdir -p build
case "$mode" in
  verify)  build_unsigned ;;
  archive) do_archive ;;
  export)  do_export ;;
  upload)  do_upload ;;
esac