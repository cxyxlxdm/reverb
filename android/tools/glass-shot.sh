#!/bin/bash
# 玻璃栏的真机取证夹具(与 harmony/tools/glass-shot.sh 同一套思路,那一套是鸿蒙端
# 折射调参时逼出来的):编译装机 → 把列表推到有一行封面压在栏底下 → 按住左格 → 截屏回本地裁图。
#
# 为什么要脚本化:玻璃的错法(锚点、缩放派生、透明度挂在哪个节点)和"参数没调好"**同形** ——
# 症状都是"看着不对"。只能靠反复在**同一块背景**上按同一下、截同一处的帧来分辨。
# 手工做一轮两分钟,十轮就没人做了。
#
# 用法:android/tools/glass-shot.sh [输出前缀] [按压点 x y]
# 前置:一台 Android 设备连着 adb(Android SDK 路径可用 ANDROID_HOME 指定)。
#
# ⚠️ 本脚本**还没跑过**(写的时候没有 Android 设备连着)。第一次跑要先确认三件事:
# ①`adb shell input swipe` 的 duration 参数能不能撑住不演成 fling;
# ②默认按压点算得对不对(它按"左格中心 = 栏宽的四等分点"估,栏高取 48dp);
# ③裁图框(见文件末尾)要按本机分辨率改。
set -e
OUT=${1:-glass-android}
cd "$(dirname "$0")/.."

ADB=${ADB:-$(command -v adb || echo "/usr/local/share/android-commandlinetools/platform-tools/adb")}
[ -x "$ADB" ] || { echo "找不到 adb(设 ADB= 或 ANDROID_HOME)"; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "没有设备连着"; exit 1; }

SIZE=$("$ADB" shell wm size | tr -cd '0-9x')
DENSITY=$("$ADB" shell wm density | tr -cd '0-9')
W=${SIZE%x*}; H=${SIZE#*x}
PX=$(awk -v d="$DENSITY" 'BEGIN{printf "%d", d/160}')   # px/dp(密度 420 → 2.625)
# 栏底到屏底 = 手势导航条的 inset。**随机型不同**,第一次跑要么肉眼核过再用:
#   adb shell dumpsys window | grep -i navigationBarBottomInsets
# 鸿蒙那一端实测把这道留白收到 0.62 倍手势区高才对上(见 GlassTabBar 的 INSET_KEEP),
# Android 这一端现在仍然是"整个 inset 留空",所以两处栏的落点还没对上 —— 量出来再定。
NAV_PX=${NAV_PX:-48}
BAR_BOTTOM=$(( H - NAV_PX ))
X=${3:-$(( 24 * PX + (W - 2 * 24 * PX) / 4 ))}   # 左格中心(栏宽的四等分点)
Y=${4:-$(( BAR_BOTTOM - 24 * PX ))}              # 栏的竖向中线
echo "屏幕 $SIZE 密度 $DENSITY(${PX}px/dp)→ 按压点 $X,$Y"

./gradlew :app:assembleDefaultDebug -q
# debug 变体的 applicationId 带 .debug 后缀(见 app/build.gradle),组件名要写全
APK=$(ls app/build/outputs/apk/default/debug/*.apk | head -1)
"$ADB" install -r "$APK" >/dev/null
"$ADB" shell am start -n "com.yuyin.reverb.android.debug/com.yuyin.reverb.MainActivity" >/dev/null
sleep 3

# 摆背景:回「发现」页并把列表往上推一点,让一行封面的下缘正好压在栏底下。
# 页面滚到空档时镜内是全黑的,那种帧标定不出任何东西 —— 这一步就是为了避开它。
"$ADB" shell input tap "$(( W / 4 ))" "$(( H - 200 ))" >/dev/null
sleep 1
"$ADB" shell input swipe "$(( W / 2 ))" "$(( H * 7 / 10 ))" "$(( W / 2 ))" "$(( H * 5 / 10 ))" 400 >/dev/null
sleep 1

# 按住:input swipe 起终点取同一个点、duration 给 1500ms,截屏落在中段 = 弹簧已落定
("$ADB" shell input swipe "$X" "$Y" "$X" "$Y" 1500 >/dev/null 2>&1 ) &
sleep 0.6
"$ADB" exec-out screencap -p > "/tmp/$OUT.png"
wait

python3 - "$OUT" "$X" "$Y" "$W" "$H" "$PX" <<'PY'
import sys
from PIL import Image
n, x, y, w, h, px = sys.argv[1:7]
x, y, w, h, px = map(int, (x, y, w, h, px))
im = Image.open('/tmp/%s.png' % n)
# 栏 + 上下各 40dp:量栏高、透镜鼓出栏外的量、静止底与灰底的相对位置都在这张里
top, bot = h - 88 * px, h
im.crop((0, max(0, top), w, bot)).save('/tmp/%s_wide.png' % n)
# 按压点周围 120×60dp:看镜内内容与镜外磨砂接不接得上
a = im.crop((x - 60 * px, y - 30 * px, x + 60 * px, y + 30 * px))
a.resize((a.width * 2, a.height * 2), Image.LANCZOS).save('/tmp/%s_press.png' % n)
PY
echo "OK /tmp/${OUT}_press.png  /tmp/${OUT}_wide.png"
