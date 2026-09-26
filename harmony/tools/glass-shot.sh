#!/bin/bash
# 玻璃栏折射层的真机标定夹具:编译装机 → 把一张封面摆到栏底下 → 按住透镜 → 截屏回本地裁图。
#
# 为什么要脚本化:折射的错法(坐标单位、位移方向、画布偏移)和"参数没调好"**同形** ——
# 症状都是"镜内内容看着不对"。只能靠反复在**同一块背景**上按同一下,截同一处的帧来分辨。
# 手工做一轮两分钟,十轮就没人做了。
#
# 用法:harmony/tools/glass-shot.sh [输出前缀]
# 前置:装机需真机连着 hdc;bundleName 从 AppScope/app.json5 读(测试期临时改名也照样能跑)。
set -e
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
OUT=${1:-glass}
cd "$(dirname "$0")/.."

BUNDLE=$(python3 -c "import json;print(json.load(open('AppScope/app.json5'))['app']['bundleName'])")

export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon 2>&1 \
  | grep -E "ERROR|error:|BUILD" | tail -5

$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap >/dev/null
$HDC shell aa start -b "$BUNDLE" -a EntryAbility >/dev/null
sleep 3

# 摆背景:回「发现」页并把列表往上推一点,让一行封面的下缘正好压在栏底下。
# 页面滚到空档时透镜里是全黑的,那种帧标定不出任何东西 —— 这一步就是为了避开它。
$HDC shell uitest uiInput click 300 2490 >/dev/null
sleep 1
$HDC shell "uitest uiInput swipe 600 1900 600 1500 900" >/dev/null
sleep 1

# 按住:注入的 swipe 无论 velocity 给多少都固定演 ~1.5s(见 H98),所以后台发命令、
# 主线程睡 0.6s 再截,截到的就是"按住且弹簧已落定"的那一帧。
( $HDC shell "uitest uiInput swipe 300 2490 301 2490 600" >/dev/null 2>&1 ) &
sleep 0.6
$HDC shell snapshot_display -f /data/local/tmp/$OUT.jpeg >/dev/null 2>&1
wait
$HDC file recv /data/local/tmp/$OUT.jpeg /tmp/$OUT.jpeg >/dev/null 2>&1

python3 - "$OUT" <<'PY'
import sys
from PIL import Image
n = sys.argv[1]
im = Image.open('/tmp/%s.jpeg' % n)
a = im.crop((60, 2380, 640, 2688))
a.resize((a.width * 2, a.height * 2), Image.LANCZOS).save('/tmp/%s_press.png' % n)
im.crop((0, 2050, 1216, 2688)).save('/tmp/%s_wide.png' % n)
PY
echo "OK /tmp/${OUT}_press.png"
