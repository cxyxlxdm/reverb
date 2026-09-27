#!/bin/bash
# 播放模式按钮的装机取证:点一次起播、再点两轮换模式,把 logcat 里那几行打回来。
#
# 为什么也要脚本化(和 glass-shot.sh 同一条理由):这条链的失败方式全是"看着像没反应" ——
# 按钮没渲染、tag 没带上、点了只切模式不起播,三种症状在屏幕上都是"什么都没发生"。
# 所以判据不看截图,看 `playQueue … tag='…'` 与 `playMode A -> B` 这两行日志。
#
# 坐标一律从 uiautomator 的 bounds 现量,不写死:换一台机器/换一套 ROM,
# 写死的落点会静悄悄按到别处(玻璃栏夹具第一轮就是这么废掉一次)。
#
# 用法:android/tools/play-button-check.sh [段名](默认「最新」,可传 收藏 / 下载)
# 前置:连着 adb 的设备,且装的是 debug 包(applicationId 带 .debug)。
set -e
cd "$(dirname "$0")/.."
ADB=${ADB:-$(command -v adb || echo "/usr/local/share/android-commandlinetools/platform-tools/adb")}
PKG=com.yuyin.reverb.android.debug
SEC=${1:-最新}
[ -x "$ADB" ] || { echo "找不到 adb"; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "没有设备连着"; exit 1; }

"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true
"$ADB" shell am start -n "$PKG/com.yuyin.reverb.MainActivity" >/dev/null
sleep 3

# 量一个节点的屏幕中心。每次先删掉设备上的旧 dump —— `uiautomator dump` 偶尔会失败,
# 失败后 `cat` 读到的是**上一屏**的层级,拿那种坐标去点就是"看着没反应"的第二种成因。
#
# $2=bottom 时取**最靠下**的那个匹配:tab 文案与页面大标题**同名**(「音阁」既是右格 tab
# 也是这一页的标题),按第一个匹配点下去就点到标题上了。
center_of() { # $1 = 匹配 (content-desc|text)="…" 的正则片段, $2 = bottom(可选)
  local n pick=head
  [ "${2:-}" = bottom ] && pick=tail
  for n in 1 2 3; do
    "$ADB" shell rm -f /sdcard/pb.xml >/dev/null 2>&1 || true
    "$ADB" shell uiautomator dump /sdcard/pb.xml >/dev/null 2>&1 || true
    local hit
    hit=$("$ADB" shell cat /sdcard/pb.xml 2>/dev/null | tr '<' '\n<' |
      grep -oE "(content-desc|text)=\"[^\"]*$1[^\"]*\"[^/]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" |
      sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\1 \2 \3 \4/' |
      awk '{print int(($1+$3)/2), int(($2+$4)/2)}' |
      "$pick" -1)
    [ -n "$hit" ] && { echo "$hit"; return 0; }
    sleep 1
  done
  return 1
}
tap_node() { local p; if p=$(center_of "$1" "${2:-}"); then echo "   点「$1」→ $p"; "$ADB" shell input tap $p; else echo "   ❌ 屏幕上找不到「$1」"; return 1; fi; }

# 判据取**应用自己落盘的日志**(`Logger` 写 filesDir/logs/reverb.log),不靠 logcat 的 tag:
# 这个镜像的 tag 是 `Reverb/Player`(带斜杠),按 `-s Player:V` 过滤会把整条链全滤掉,
# 于是"日志里什么都没有"被误读成"按钮没生效"。debug 包可以 run-as 直接读文件。
read_log() { "$ADB" shell run-as "$PKG" cat files/logs/reverb.log 2>/dev/null || true; }
MARK=$(read_log | wc -l | tr -d ' ')

echo "== 1) 音阁「$SEC」段右端的播放按钮:起播应带 tag =="
tap_node 音阁 bottom; sleep 2     # 右格 tab = 音阁(按文案点,不写死坐标)
tap_node "$SEC"; sleep 2          # 选段
tap_node "播放这个列表"; sleep 3

echo "== 2) 再点两下:顺序 → 循环 → 随机 =="
tap_node "顺序播放"; sleep 1
tap_node "循环播放"; sleep 2

echo "== 3) 落盘日志里这一段的新增 =="
"$ADB" shell input keyevent KEYCODE_MEDIA_PAUSE >/dev/null 2>&1 || true
sleep 1
NEW=$(read_log | tail -n +$((MARK + 1)))
echo "$NEW" | grep -E "playQueue|playMode|state |Player" | tail -20
echo "$NEW" | grep -qE "playQueue" || {
  echo "❌ 新增日志里没有 playQueue —— 按钮那一下没起效(整条链没通)"; exit 1; }

