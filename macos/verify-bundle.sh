#!/bin/bash
# 解包验收(硬规矩 1):**断言**版 —— 每条判据不通过就记一条 ✗,最后非 0 退出。
#
# 为什么单独成文件,而不是留在 package.sh 里:package.sh 要 `swift build` 才能走到验收段,
# 而本仓库的构建机与开发机是两台(见 AGENTS.md macOS 那一块),开发机上 `swift build` 六层都跑不了
# ⇒ 验收脚本永远没机会在这台机器上被执行,也就永远没人知道**它自己**是对是错。
# 抽出来之后可以拿一个手搭的假 bundle 直接跑:正向要 PASS,把每项判据逐个弄坏要各自 FAIL。
# 一条从不被执行的断言,和没有断言是同一件事(package.sh 的前一版就是「只打印不断言」,见 H136)。
#
# 为什么判据是「断言」而不是「打印给人看」:1.0.2 那个包在名字里写着 universal,
# 实际是 arm64 单架构,而当时的验收段把 `lipo -archs` 打印出来了 —— 打印出来 ≠ 拦住。
# 所以这里的架构判据是**集合相等**,不是「包含期望项」:多一个架构同样是出包口径变了。
#
# 用法:verify-bundle.sh <bundle.app> [期望架构...] [--langs 期望语言...]
#   期望架构由调用方传入(和它给 swift build 的 --arch 列表同源),这样脚本本身不猜构建口径。
#   不传期望架构时只断言「至少有一个能读出来的架构」—— 那是「有没有产物」级别的检查,不是 universal。
#   语言同理:不传就只断言「每套已有的 .lproj 都带能 lint 过的 .strings」,
#   传了才断言「集合相等」—— 少拷一套语言在只打印的版本里长得跟正常一样(见 H136 变异 3)。
set -uo pipefail

BUNDLE="${1:?用法: verify-bundle.sh <bundle.app> [期望架构...] [--langs 期望语言...]}"
shift
EXPECTED=()
WANT_LANGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --langs) shift; while [ $# -gt 0 ]; do WANT_LANGS+=("$1"); shift; done ;;
    *) EXPECTED+=("$1"); shift ;;
  esac
done

PLIST="$BUNDLE/Contents/Info.plist"
RES="$BUNDLE/Contents/Resources"
[ -f "$PLIST" ] || { echo "✗ 找不到 $PLIST"; exit 1; }

# 可执行文件名以 Info.plist 的 CFBundleExecutable 为准,不拿 `.app` 目录名去猜:
# 两者不一致时 LaunchServices 起不来,而按目录名去找会去查一个根本不该存在的路径,
# 报出来的错和真实问题(键写错/没同步)完全脱节。
# 这里也认**退出码**而不是"字符串非空" —— 与下面版本号那一段同一个坑:`plutil -extract`
# 在键缺失时把报错句子打到 stdout,只看非空等于把报错当成了文件名。
if ! APP_NAME=$(plutil -extract CFBundleExecutable raw "$PLIST" 2>/dev/null); then
  echo "✗ Info.plist 没有 CFBundleExecutable(取不到,不是"值为空")"
  exit 1
fi
BIN="$BUNDLE/Contents/MacOS/$APP_NAME"

FAILS=0
fail() { echo "   ✗ $*"; FAILS=$((FAILS + 1)); }

# ---- 0. 处理量先行 ---------------------------------------------------------
# 没有「扫了多少」,后面的 0 与「齐了」都不成立(见 zero-hit-must-prove-scan)。
[ -f "$BIN" ] || { echo "✗ 找不到可执行文件 $BIN(CFBundleExecutable 与 MacOS/ 下的文件名不一致?)"; exit 1; }
BIN_BYTES=$(wc -c <"$BIN" | tr -d ' ')
LPROJ_LIST=$(find "$RES" -maxdepth 1 -type d -name '*.lproj' 2>/dev/null | sort)
LPROJ_N=$(printf '%s' "$LPROJ_LIST" | grep -c . )
RES_N=$(find "$RES" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
STR_N=$(find "$RES" -name 'Localizable.strings' 2>/dev/null | wc -l | tr -d ' ')
echo "==> 验收 处理量:二进制 ${BIN_BYTES} B / .lproj ${LPROJ_N} 套 / .strings ${STR_N} 份 / Resources ${RES_N} 项"

# ---- 1. 架构:期望集合 == 实际集合 ----------------------------------------
ARCHS_OUT=$(LC_ALL=C lipo -archs "$BIN" 2>/dev/null || echo '')
if [ -z "$ARCHS_OUT" ]; then
  fail "架构读不出来(lipo -archs 空)—— 二进制可能损坏或不是 Mach-O"
elif [ ${#EXPECTED[@]} -eq 0 ]; then
  echo "   架构:${ARCHS_OUT}(未传期望架构,只断言「能读出来」)"
else
  want=$(printf '%s\n' "${EXPECTED[@]}" | LC_ALL=C sort | tr '\n' ' ')
  got=$(printf '%s\n' $ARCHS_OUT | LC_ALL=C sort | tr '\n' ' ')
  echo "   架构断言:期望 [${want}] / 实际 [${got}]"
  if [ "$want" != "$got" ]; then
    for a in "${EXPECTED[@]}"; do
      case " $ARCHS_OUT " in *" $a "*) ;; *) fail "缺 $a —— 这个包在对应芯片的 Mac 上跑不起来" ;; esac
    done
    for a in $ARCHS_OUT; do
      case " $want " in *" $a "*) ;; *) fail "多出 $a —— 期望集合里没有它,构建口径与文件名会不一致" ;; esac
    done
  fi
fi

# ---- 2. 判据词:每个都期望非 0 --------------------------------------------
# 这些词是「播放模式」与「批注」两批改动的判据(字符串字面量会留在二进制里,
# 所以「键即简体原文」的词与 UserDefaults 键名都可判据)。
# 负控制已实测:拿归档的 dist/余音-Reverb-1.0.2-arm64.dmg 跑过,这 11 个词**全是 0**
# (2026-09-29 播控那三个词;2026-10-01 批注那三个词,同包重跑)。所以「非 0」才有意义。
# 注意 play_mode 那一行会把 play_mode_map 的命中一起算进去(前缀),它恒 ≥ play_mode_map,这是预期的。
# 中文必须用 LC_ALL=C grep -a 搜原始字节(硬规矩 1)。
echo "   判据词(期望全部非 0):"
for w in play_mode_map play_mode SEQUENTIAL REPEAT_ONE SHUFFLE 顺序播放 单曲循环 随机播放 \
         notes.json 批注 记下这一秒; do
  c=$(LC_ALL=C grep -a -o "$w" "$BIN" 2>/dev/null | wc -l | tr -d ' ')
  printf '      %-14s %s\n' "$w" "$c"
  [ "$c" -gt 0 ] || fail "判据词「$w」在二进制里 0 命中 —— 这批改动没进包"
done

# ---- 3. 本地化:语言集合相等 + 每套都要有能 lint 过的 .strings -------------
# 只检查「已有的 .lproj 每套都齐」会漏掉最真实的失败形状:cp -R 漏了一门语言,
# 剩下的三套全都 lint OK,输出看起来和四套齐时一模一样。所以传了 --langs 就断言集合相等。
# 同样用 while-read(路径带空格时按空白拆词会把一门语言拆成两半,见下面第 3 段那条注释)
HAVE_LANGS=$(while IFS= read -r d; do [ -n "$d" ] && basename "$d" .lproj; done <<< "$LPROJ_LIST" | LC_ALL=C sort | tr '\n' ' ')
if [ ${#WANT_LANGS[@]} -gt 0 ]; then
  wl=$(printf '%s\n' "${WANT_LANGS[@]}" | LC_ALL=C sort | tr '\n' ' ')
  echo "   语言断言:期望 [$wl] / 实际 [${HAVE_LANGS}]"
  for l in "${WANT_LANGS[@]}"; do
    case " $HAVE_LANGS " in *" $l "*) ;; *) fail "缺 $l.lproj —— 这门语言没进包(五语文案会缺)" ;; esac
  done
  for l in $HAVE_LANGS; do
    case " $wl " in *" $l "*) ;; *) fail "多出 $l.lproj —— 期望清单里没有它,Localization/ 与包不一致" ;; esac
  done
fi
if [ "$LPROJ_N" -eq 0 ]; then
  fail "Resources 下一套 .lproj 都没有"
else
  # 用 while-read 而不是 `for d in $LPROJ_LIST`:bundle 路径可能带空格(拷到 ~/Desktop/My App.app 之类),
  # 按空白拆词会把一套语言拆成两半,于是报出看不懂的"缺文件"。
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    lang=$(basename "$d")
    f="$d/Localizable.strings"
    if [ ! -f "$f" ]; then
      fail "$lang 缺 Localizable.strings"
      continue
    fi
    lint=$(plutil -lint "$f" 2>&1 | awk -F': ' '{print $NF}')
    printf '      %-10s %s\n' "$lang" "$lint"
    [ "$lint" = "OK" ] || fail "$lang 的 Localizable.strings lint 不过:$lint"
  done <<< "$LPROJ_LIST"
fi

# ---- 4. 版本号与运行门槛:三个键都要非空 ----------------------------------
# 只打印的话,键缺失(空值)和值正常在输出里都「看起来有一行」。
echo "   版本与运行门槛(期望三个键都非空):"
# 判据是 **plutil 的退出码**,不是「取到的字符串非空」:键缺失时 plutil 把
# `Could not extract value...` 整句打到 **stdout**、退出码 1 —— 只看非空等于把报错文本当成了版本号。
for k in CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
  if v=$(plutil -extract "$k" raw "$PLIST" 2>/dev/null); then :; else v=""; fi
  printf '      %-26s %s\n' "$k" "${v:-<缺失>}"
  [ -n "$v" ] || fail "Info.plist 的 $k 取不到或为空"
done
# minos / sdk / platform 与签名身份只展示,不判据:
# minos 由构建机的 SDK 与 deployment target 决定,这台脚本无从知道期望值;
# 判「跑不跑得起来」要在 ≥ 门槛的系统上实跑,那是构建机上的另一份清单(ROADMAP 三-A)。
vtool -show-build "$BIN" 2>/dev/null | grep -E 'minos|platform|sdk' | sed 's/^/      /' || echo "      (vtool 读不到 build load command)"

# ---- 5. 签名:要真验,不是只 dump 描述 ------------------------------------
# `codesign -dvv` 是「读签名信息」,签坏了也可能照样打印;`--verify` 才是校验。
if codesign --verify --deep --strict "$BUNDLE" 2>/dev/null; then
  echo "   签名:codesign --verify 通过($(codesign -dvv "$BUNDLE" 2>&1 | grep -E '^Signature=' | sed 's/Signature=//' | tr -d ' '))"
else
  fail "codesign --verify 不通过"
fi

# ---- 结果 -----------------------------------------------------------------
echo "==> 验收结论:$([ "$FAILS" -eq 0 ] && echo '全部断言通过' || echo "$FAILS 条断言不通过")"
# 这一行不可省略:说清这次**没扫**什么,和说清扫到什么同等重要。
echo "   未覆盖范围:①界面与运行时行为(一帧都没跑,要构建机实跑)②minos/sdk 的取值是否合意"
echo "   ③内置 seed_podcasts.json / guide_intro.m4a 是否存在(由 package.sh 警告,不判据)"
echo "   ④Assets.car 与图标资源 ⑤二进制里除这 11 个词以外的功能面"
[ ${#WANT_LANGS[@]} -gt 0 ] || echo "   ⑥语言齐不齐:本次没传 --langs,只验了「已有的每套 .strings 都能 lint」,没验「该有五套」"
[ "$FAILS" -eq 0 ] || exit 1
