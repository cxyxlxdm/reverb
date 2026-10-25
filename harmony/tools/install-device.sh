#!/bin/bash
#
# 装机一条命令(硬规矩 12 的工具化):默认装 debug hap,识别签名口径冲突并给指路。
#
# 用法:
#   ./install-device.sh                装 entry/build/.../entry-default-signed.hap(debug,日常装机验证)
#   ./install-device.sh --app          装 build/outputs/release/harmony-release-signed.app(release 签名)
#   ./install-device.sh --hap <路径>    装指定 hap/app
#   附加 --replace                     覆盖被拒(provision 不同型)时自动「卸载 + 重装」
#
# 为什么要有这个脚本(2026-10-25,见 TROUBLESHOOTING H216 教训 ③):
#   hdc install -r 被拒 code:9568286 "install provision type not same" 的成因是
#   **签名口径不同型**,不是包坏了 —— 本地 `assembleHap --mode module`(debug 或 release
#   模式都一样)出的 hap 走的是 build-profile 的 default 段(DevEco 自动签名,debug profile);
#   而机上若装过 build-release.sh 那条链(assembleApp project,release 正式材料)的包,
#   两种 profile 互不让覆盖,**双向都拒**。报错本身没说人话,这里翻译并给两条出路。
#
# ⚠️ --replace 会卸载(= 丢应用数据)。测试机沙箱是空的(启动停在隐私同意门)随便换;
#   有数据的机器先走硬规矩 12 的备份四步(应用内完整备份 → 收到本机 → wc -c 断言非 0),
#   再回来跑 --replace。
#
set -euo pipefail
cd "$(dirname "$0")/.."

HDC="${HDC:-/Users/cxyxl/Library/OpenHarmony/Sdk/26.0.0/toolchains/hdc}"
[ -x "$HDC" ] || HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
[ -x "$HDC" ] || { echo "✗ 找不到 hdc(可用 HDC=... 覆盖)"; exit 1; }

DEBUG_HAP="entry/build/default/outputs/default/entry-default-signed.hap"
RELEASE_APP="build/outputs/release/harmony-release-signed.app"

TARGET=""; REPLACE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app)     TARGET="$RELEASE_APP" ;;
    --hap)     shift; TARGET="${1:?--hap 需要路径}" ;;
    --replace) REPLACE=1 ;;
    *) echo "未知参数:$1"; exit 1 ;;
  esac
  shift
done
[ -n "$TARGET" ] || TARGET="$DEBUG_HAP"
[ -f "$TARGET" ] || { echo "✗ 找不到包:$TARGET(先构建:debug 见 AGENTS 鸿蒙一节 / release 跑 build-release.sh)"; exit 1; }

TARGETS_OUT="$("$HDC" list targets | grep -v '^\[' | grep -v '^$' | head -1)"
[ -n "$TARGETS_OUT" ] || { echo "✗ hdc 看不到设备。若 USB 已插,先看总线上有没有枚举:"; \
  echo "    ioreg -p IOUSB -l | grep -A2 'HDC Device'"; \
  echo "  有 \"HDC Device\" = 授权没放行:看手机上的「允许 USB 调试」弹窗,或开发人员选项里"; \
  echo "  撤销授权后重插线(见 AGENTS 环境准备表 hdc 那条)。"; exit 1; }

BUNDLE="com.yuyin.reverb"
install_one() {  # $1 = -r 或空;重装路径传 ""
  # ⚠️ hdc 的退出码不可用:安装失败(甚至 hdc 自身报错)也 exit 0,实测 9568448 那次
  # 脚本就把它当成功了。成败只能认输出:失败必带 "error",成功的输出里没有。
  OUT="$("$HDC" install ${1:-} "$TARGET" 2>&1)"
  echo "$OUT" | tail -2
  if echo "$OUT" | grep -qiE 'msg:error|error:|failed to install'; then return 1; fi
  return 0
}

echo "▸ 装 $TARGET → $TARGETS_OUT"
if install_one -r; then
  echo "✓ 覆盖安装成功(数据保留)"
  exit 0
fi

if echo "$OUT" | grep -qE '9568286|9568448'; then
  INSTALLED_TYPE="$("$HDC" shell bm dump -n "$BUNDLE" 2>/dev/null \
    | grep -o '"appProvisionType"[^,]*' | head -1 || true)"
  if [ -z "$INSTALLED_TYPE" ]; then
    # 空机也报 9568448(2026-10-25 实测,连 dist 里在架的正式包都被拒):
    # 不是包的问题,是设备侧对 **release 签名包侧载**的拦截 —— HarmonyOS 的
    # 纯净模式/外部来源安装限制只拦正式签名包,debug profile 走开发者调试通道不受影响。
    echo "✗ 验签失败(9568448),且机上原本就没装这个应用 —— 这是设备侧拦截 release 包侧载,"
    echo "  不是包坏了(判据:换 dist/ 里那份在架正式包装,同样报 9568448)。"
    echo "  出路:① 手机 设置 → 安全(和隐私) → 更多安全设置 → 关闭「纯净模式」/允许外部来源安装;"
    echo "        ② 或就用 debug 包装(本脚本默认),日常装机验证不受影响。"
  else
    echo "✗ 覆盖被拒:签名口径冲突(9568286 provision type not same / 9568448 verify signature"
    echo "  failed,是同一件事的两个报法)。机上现状:$INSTALLED_TYPE"
    echo "  成因:assembleHap(module)出的 hap 是 debug profile;build-release.sh 那条链(assembleApp"
    echo "  project)出的是 release 正式材料 —— 两种 profile 互不让覆盖。两条出路:"
    echo "  ① 换与机上同口径的包装(日常装机验证用本脚本默认的 debug hap;要 release 口径用 --app)"
    echo "  ② 确认可丢数据后重装:./tools/install-device.sh ${TARGET:+--hap $TARGET} --replace"
  fi
  if [ "$REPLACE" = 1 ]; then
    if [ -z "$INSTALLED_TYPE" ]; then
      echo "✗ --replace 无从替换(机上本来就没装),先按上面的出路处理设备侧限制"
      exit 1
    fi
    echo "▸ --replace 已给:卸载 $BUNDLE 后重装(应用数据随之清空)"
    "$HDC" shell bm uninstall -n "$BUNDLE" | tail -1
    install_one ""
    echo "✓ 重装完成 —— 若这台机原有用户数据,现在按硬规矩 12 的恢复步骤导回"
  fi
  exit 0
fi

echo "✗ 安装失败(非签名口径问题),原始输出在上面"
exit 1
