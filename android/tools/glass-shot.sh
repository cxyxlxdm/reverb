#!/bin/bash
# 玻璃栏的真机取证夹具(与 harmony/tools/glass-shot.sh 同一套思路,那一套是鸿蒙端
# 折射调参时逼出来的):编译装机 → 把列表推到有一行封面压在栏底下 → 一次抓三帧(静止 / 按住 / 拖动中)。
#
# 为什么要脚本化:玻璃的错法(锚点、缩放派生、透明度挂在哪个节点)和"参数没调好"**同形** ——
# 症状都是"看着不对"。只能靠反复在**同一块背景**上按同一下、截同一处的帧来分辨。
# 手工做一轮两分钟,十轮就没人做了。
#
# 三帧对应三条口径(2026-09-27 首次真机跑通时按这三条判的):
#   rest  静止:栏上只有一块扁的灰色静止底,**没有**任何玻璃感的东西。
#   press 按住:透镜从静止底那里"长"出来;静止底仍在原位。
#   drag  拖动中:透镜**宽度与 press 帧一致**(只改位置)。上一版 Android 是越拖越大,
#         鸿蒙那端撤过三次,所以这一对帧是这次移植的主要判据。
#
# 用法:android/tools/glass-shot.sh [输出前缀]
# 前置:一台 Android 设备连着 adb(Android SDK 路径可用 ADB= 或 ANDROID_HOME 指定)。
set -e
OUT=${1:-glass-android}
cd "$(dirname "$0")/.."

ADB=${ADB:-$(command -v adb || echo "/usr/local/share/android-commandlinetools/platform-tools/adb")}
[ -x "$ADB" ] || { echo "找不到 adb(设 ADB= 或 ANDROID_HOME)"; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "没有设备连着"; exit 1; }

SIZE=$("$ADB" shell wm size | tr -cd '0-9x')
# `wm density` 有两行(Physical / Override)时取**后一行** —— Override 才是应用 dp 换算用的那个。
DENSITY=$("$ADB" shell wm density | grep -o '[0-9]\+' | tail -1)
W=${SIZE%x*}; H=${SIZE#*x}
# 栏底到屏底 = 手势导航条的 inset。直接从窗口服务读(帧框是物理像素):
#   InsetsSource id=… type=navigationBars frame=[0,2752][1272,2800]  →  48
NAV_PX=${NAV_PX:-$("$ADB" shell dumpsys window 2>/dev/null \
  | grep -o 'type=navigationBars frame=\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]' \
  | head -1 | grep -o '[0-9]\+' \
  | awk 'NR==2{t=$1}NR==4{print $1-t}')}
NAV_PX=${NAV_PX:-48}

# 几何全部按 dp→px 浮点算(整数截断会让按压点偏出一档;PX 在 476dpi 上是 2.975)
eval "$(awk -v w="$W" -v h="$H" -v nav="$NAV_PX" -v d="$DENSITY" 'BEGIN{
  px = d/160.0
  bar_h = 48*px; pad = 24*px; inset = 22*px
  bar_bottom = h - nav
  band = (w - 2*pad) - 2*inset
  slot0 = pad + inset + band*0.25
  slot1 = pad + inset + band*0.75
  printf "PX=%.4f; BAR_H=%d; BAR_BOTTOM=%d; X0=%d; X1=%d; MIDY=%d\n", \
    px, bar_h, bar_bottom, slot0, slot1, bar_bottom - bar_h/2
}')"
echo "屏幕 $SIZE 密度 $DENSITY(${PX}px/dp) 手势条 ${NAV_PX}px"
echo "栏高 ${BAR_H}px 底边 y=$BAR_BOTTOM;左格中心 ($X0,$MIDY) 右格中心 ($X1,$MIDY)"

# INSTALL=0 只抓取不重编(同一版包反复抓不同帧时用)。
# ⚠️ 部分定制 ROM 上 `adb install` 会在机子上弹「涉及敏感权限 → 继续安装」的门禁,
# 命令就挂着不回来自作主张地等 —— 首次装机要先在手机上点掉它。
if [ "${INSTALL:-1}" = 1 ]; then
  ./gradlew :app:assembleDefaultDebug -q
  # debug 变体的 applicationId 带 .debug 后缀(见 app/build.gradle),组件名要写全
  APK=$(ls app/build/outputs/apk/default/debug/*.apk | head -1)
  "$ADB" install -r "$APK" >/dev/null
fi
"$ADB" shell am start -n "com.yuyin.reverb.android.debug/com.yuyin.reverb.MainActivity" >/dev/null
sleep 3

# 摆背景:回「发现」页(点左格 = 选中所在 tab,幂等)并把列表往上推一点,让一行封面的下缘压在栏底下。
# 页面滚到空档时镜内是全黑的,那种帧标定不出任何东西 —— 这一步就是为了避开它。
"$ADB" shell input tap "$X0" "$MIDY" >/dev/null
sleep 1
"$ADB" shell input swipe "$((W / 2))" "$((H * 7 / 10))" "$((W / 2))" "$((H * 5 / 10))" 400 >/dev/null
sleep 1

# 1) 静止帧:验"没有常驻玻璃"
"$ADB" exec-out screencap -p > "/tmp/${OUT}_rest_raw.png"

# 2) 按住帧:起终点同点、duration 3000ms(留足 screencap 自身耗时,别让它在松手后才落图)
("$ADB" shell input swipe "$X0" "$MIDY" "$X0" "$MIDY" 3000 >/dev/null 2>&1 ) &
sleep 1.2
"$ADB" exec-out screencap -p > "/tmp/${OUT}_press_raw.png"
wait

# 3) 拖动中帧:从左格拖向右格,拖到中段时截图 —— 量这一帧的透镜宽度
("$ADB" shell input swipe "$X0" "$MIDY" "$X1" "$MIDY" 2400 >/dev/null 2>&1 ) &
sleep 1.1
"$ADB" exec-out screencap -p > "/tmp/${OUT}_drag_raw.png"
wait

python3 - "$OUT" "$W" "$H" "$PX" "$X0" "$MIDY" <<'PY'
import sys
from PIL import Image
n, w, h, px, x, y = sys.argv[1:7]
w, h, x, y = map(int, (w, h, x, y))
px = float(px)
for tag in ('rest', 'press', 'drag'):
    im = Image.open('/tmp/%s_%s_raw.png' % (n, tag))
    # 栏 + 上下各 40dp:量栏高、透镜鼓出栏外的量、静止底与灰底的相对位置都在这张里
    im.crop((0, max(0, h - int(88 * px)), w, h)).save('/tmp/%s_%s_wide.png' % (n, tag))
    # 按压点周围 120×60dp 放大两倍:看透镜边界与镜外磨砂接不接得上
    a = im.crop((x - int(60 * px), y - int(30 * px), x + int(60 * px), y + int(30 * px)))
    a.resize((a.width * 2, a.height * 2), Image.LANCZOS).save('/tmp/%s_%s_zoom.png' % (n, tag))
    print(tag, im.size)
PY

# —————————————————————— 纵向居中的量化判据(装机反馈「透镜置底」)——————————————————————
# 为什么要有这一段:**「透镜在栏里偏下」这句话,光看代码和光看截图都判不了。**
# 代码里两颗椭圆的 y 是 `(栏高 - 镜高)/2`,算出来必然居中;截图上"看着低"也可能是
# 栏自己的方向光投影把镜的下鼓出糊掉了(对比度问题,不是几何问题)。两种症状同形,
# 修法相反 —— 前者改锚点,后者改投影。所以要把**上下鼓出量各是多少 px**打成数。
#
# 取的是**透镜中心那一列**的亮度折线:透镜那圈 1dp 高光亮边是这一列上最锐的两个峰,
# 上峰 - 栏顶 = 上鼓出,栏底 - 下峰 = 下鼓出。折线整条都打印,判错也看得见(硬规矩 18:
# 看不见中间值就先把中间值打出来,别靠眼睛在 2800 高的截图里估)。
python3 - "$OUT" "$W" "$H" "$PX" "$X0" "$MIDY" <<'PY'
import sys
from PIL import Image
n, w, h, px, x, ymid = sys.argv[1:7]
w, h, x, ymid = map(int, (w, h, x, ymid))
px = float(px)
# 栏的落点:底边 = 屏底 - 手势条,高度 48dp(与 ReverbRoot 的落点同源;
# 若装机时改过栏高或底边,以这里重算的为准 —— 这段的目的就是把"假设"摊开成数)
BAR_H = round(48 * px)
bar_bot = ymid + BAR_H // 2
bar_top = bar_bot - BAR_H
top = max(0, bar_top - round(16 * px))
bot = min(h, bar_bot + round(16 * px))


def prof(tag):
    im = Image.open('/tmp/%s_%s_raw.png' % (n, tag)).convert('L')
    # 中心列左右各 3px 取均值:单列会撞上图标描边的竖线,均值只留下横向的边
    rows = []
    for yy in range(top, bot):
        s = sum(im.getpixel((xx, yy)) for xx in range(x - 3, x + 4))
        rows.append((yy, s / 7.0))
    return rows


for tag in ('rest', 'press'):
    rows = prof(tag)
    print('== %s  栏顶=%d 栏底=%d 栏中线=%d ==' % (tag, bar_top, bar_bot, (bar_top + bar_bot) // 2))
    # 找最锐的两个"上跳"边:亮度在一行内跳升最多的位置(高光亮边的上沿)
    jumps = sorted(
        ((rows[i][1] - rows[i - 1][1], rows[i][0]) for i in range(1, len(rows))),
        reverse=True,
    )[:6]
    print('   亮度上跳最大的 6 处 (Δ亮度, y):', [(round(d, 1), yy) for d, yy in jumps])
    print('   折线 (y:亮度):', ' '.join('%d:%d' % (yy, round(l)) for yy, l in rows[::2]))

# 差分框:按住帧比静止帧**多出来**的那一段 = 透镜(含它鼓出栏外的上下两截)。
# 上下两个鼓出量应该相等(几何上两颗椭圆都锚在栏中线)。注意两处已知的对称污染:
#   · 整栏按 1.06 放大 ⇒ 栏自己的边上下各外移 ≈3 px(两边等量,不影响"对不对称"的判读);
#   · 栏的投影**只在下缘**(spot 往下偏)⇒ 下缘的差分框会被影子撑大。
#     这正是本次要分清的两件事:若 Δ 不对称且多出的量落在**下方**,读数会被影子污染,
#     不代表几何偏心(本轮已把 spot 归零,重测即可验证)。
# ⚠️ **读数有 ±2 px 的地板**:栏顶/栏底是按 48dp 常量重算的,与真机布局的取整差 1~2 px。
#    小于这个量不要下结论 —— 这一版几何的算法本身就居中,要推翻它需要看得见的偏离(≥4 px)。
a = prof('rest')
b = prof('press')
diff = {yy: abs(l1 - l2) for (yy, l1), (_, l2) in zip(a, b) if abs(l1 - l2) > 40}
if diff:
    ys = sorted(diff)
    up = bar_top - ys[0]
    dn = ys[-1] - bar_bot
    print('== 差分框 == 顶=%d 底=%d 中线=%d' % (ys[0], ys[-1], (ys[0] + ys[-1]) // 2))
    print('   鼓出栏外:上 %d px / 下 %d px  → 差 %+d px(正=偏下)'
          % (max(up, 0), max(dn, 0), (dn - up)))
    print('   与栏中线的偏离:%+d px' % ((ys[0] + ys[-1]) // 2 - (bar_top + bar_bot) // 2))
else:
    print('== 差分框 == 没找到差异(两帧同一状态?检查抓取时序)')
PY
echo "OK /tmp/${OUT}_{rest,press,drag}_{wide,zoom}.png"
