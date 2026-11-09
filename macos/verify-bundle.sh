#!/bin/bash
# 解包验收(硬规矩 1):**断言**版 —— 每条判据不通过就记一条 ✗,最后非 0 退出。
#
# 为什么单独成文件,而不是留在 package.sh 里:package.sh 要 `swift build` 才能走到验收段,
# 而本仓库的构建机与开发机是两台(见 AGENTS.md macOS 那一块),开发机上 `swift build` 六层都跑不了
# ⇒ 验收脚本永远没机会在这台机器上被执行,也就永远没人知道**它自己**是对是错。
# 抽出来之后可以拿一个手搭的假 bundle 直接跑:正向要 PASS,把每项判据逐个弄坏要各自 FAIL。
# 一条从不被执行的断言,和没有断言是同一件事(package.sh 的前一版就是「只打印不断言」,见 H136)。
# ▶ 2026-10-24 傍晚换机后这台已经能 `swift build` + `./package.sh` 了(旧"两台"那层拦路消失,H208/H209),
#   但**单独成文件这条不跟着回收**:全量出包是分钟级、自检是秒级,而且自检能在没有任何真产物的时候
#   把每条断言逐个弄坏 —— 那是"断言有牙齿"的唯一证法,真包只能证明它这次没报红。
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
# ⚠️ **挑词之前先看长度,这不是风格问题。** Swift 的 -O 把 **9~15 字节**的字符串字面量按
# 「小字符串」直接编码进**两条 movabsq 立即数**(头 8 字节一条、余下字节一条),整词在二进制里
# **根本不连续** —— 整词 grep 恒 0,而功能是进去的。2026-10-24 换机后第一次在本机跑 universal 出包,
# 老词表 11 个里恰好 9 个落在这个窗口,于是「包是好的、断言报 9 条失败」;
# 那两条立即数的十六进制与逐词读数见 `docs/TROUBLESHOOTING.md` **H209**。
# 所以词表按「这个串在 release 包里以什么形态存在」分三类,类别写死在词前面:
#   lit8  :≤8 字节字面量 —— 小字符串的头 8 字节就是整词,连续
#   lit16 :≥16 字节字面量 —— 走原生 String(指针 + __cstring),整词连续
#   sym   :标识符(类型/属性/方法名)—— 在符号表与反射元数据里,与字面量编码无关
# 每个词都单独做过负控制(归档包 dist/余音-Reverb-1.0.2-arm64.dmg,那批功能还不存在):
# 下面这些词在那个包里**全部为 0**(2026-10-24 逐词重跑),所以这里报非 0 才算数。
# ⚠️ **新加的词要自己补一次负控制,别蹭 10-24 那批的结论。** `retry after fast failure elapsed=`
# 是 2026-10-31 随 H233 加的,同日在 1.0.2 那份里量过:= 0(处理量 4 443 392 B / arm64 单架构,
# 阳性对照 `TranscriptStore` 234 处)。顺带一个读数能说明为什么 0 是真的:**同一份包里
# `api.bilibili.com` 与 `playurl` 也都是 0** —— B 站那条源在 1.0.2 根本不存在,不是扫不动。
# 应用内更新那三条(2026-10-31 macOS 移植)的负控制用的是**本机现成的上一份发布包**:
# `dist/_backup-1.0.6-published-1030/…dmg` 里的二进制(12 438 992 B / universal),三条逐个 = 0;
# 正向对照在同一份包里 `TranscriptStore` 非 0。挑这三条的理由:仓库路径与 UserDefaults 键都 ≥16 字节
# (lit16,不会被 -O 拆成两条立即数),类名走符号表(sym);`api.github.com` 那 14 字节**在危险窗口里**,
# 所以不用它。
# ⚠️ sym 类依赖二进制没被 strip。哪天真加了 strip,这几条会一起变 0 —— 那是「换成 lit16 词」的信号,
#    不是「功能没进包」;别照着 0 去查源码。
# 中文必须用 LC_ALL=C grep -a 搜原始字节(硬规矩 1);**必须带 -F**:`repeat.1` / `square.and.pencil`
# 里的点是正则元字符,不加 -F 会把「repeat 加任意一个字符加 1」也算命中 —— 判据就虚了。
WORDS=(
  lit8:SHUFFLE
  lit8:repeat.1
  lit8:批注
  lit16:square.and.pencil
  sym:playModeByTag
  sym:setPlayMode
  sym:NoteStore
  sym:EpisodeNote
  'lit16:retry after fast failure elapsed='
  'lit16:repos/cxyxlxdm/revert-cast'
  'lit16:update_skipped_tag'
  sym:UpdateDownloader
  sym:noteComposer
)
echo "   判据词(${#WORDS[@]} 个,期望全部非 0):"
for spec in "${WORDS[@]}"; do
  cls="${spec%%:*}"; w="${spec#*:}"
  # 字节数用 LC_ALL=C 数,不能用字符数:「顺序播放」是 4 个字符、12 个字节,落哪个档由字节决定
  L=$(printf '%s' "$w" | LC_ALL=C wc -c | tr -d ' ')
  case "$cls" in
    lit8)
      [ "$L" -le 8 ] || { fail "配置错:lit8 词「$w」有 ${L} 字节(>8)—— 9~15 字节的字面量在 release 里被拆成两条立即数,整词 grep 必然 0,它不能当判据"; continue; } ;;
    lit16)
      [ "$L" -ge 16 ] || { fail "配置错:lit16 词「$w」只有 ${L} 字节(<16)—— 落在小字符串的拆分档里,整词 grep 必然 0"; continue; } ;;
    sym) : ;;   # 标识符不看字节数:它在符号表里连续,9 个字符也没被拆(被拆的是**字面量**)
    *) fail "配置错:判据词「$w」的类别「$cls」不认识(只有 lit8 / lit16 / sym)" ; continue ;;
  esac
  c=$(LC_ALL=C grep -a -o -F -- "$w" "$BIN" 2>/dev/null | wc -l | tr -d ' ')
  printf '      %-5s %-18s %-4s %sB\n' "$cls" "$w" "$c" "$L"
  [ "$c" -gt 0 ] || fail "判据词「$w」在二进制里 0 命中 —— 这批改动没进包(类别 $cls)"
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

# ---- 5. 卡片扩展(.appex)---------------------------------------------------
# 「继续收听」卡片在 macOS 上是一个 PlugIns 里的 .appex,由 SwiftPM 编出的裸可执行文件
# + package.sh 手工组装。**少了它 App 本身照样跑**,只是小组件库里查无此项 ——
# 正是「打印出来看着正常」的那类失败,所以这里逐项断言。
APPEX="$BUNDLE/Contents/PlugIns/ReverbWidget.appex"
APPEX_PLIST="$APPEX/Contents/Info.plist"
echo "   卡片扩展:${APPEX#$BUNDLE/}"
if [ ! -f "$APPEX_PLIST" ]; then
  fail "缺 Contents/PlugIns/ReverbWidget.appex —— 「继续收听」卡片不会出现在系统小组件库"
else
  point=$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$APPEX_PLIST" 2>/dev/null || true)
  if [ "$point" = "com.apple.widgetkit-extension" ]; then
    echo "      扩展点:$point"
  else
    fail "卡片扩展的 NSExtensionPointIdentifier 是「${point:-<缺失>}」,期望 com.apple.widgetkit-extension"
  fi
  # 版本必须与宿主一致:不一致时 WidgetKit 不装载(症状是"卡片突然不见了",与代码无关)
  for k in CFBundleShortVersionString CFBundleVersion; do
    hv=$(plutil -extract "$k" raw "$PLIST" 2>/dev/null || true)
    wv=$(plutil -extract "$k" raw "$APPEX_PLIST" 2>/dev/null || true)
    # 宿主本身缺这个键时第 4 段已经报过了,这里不再补一刀(否则一个缺键报两条,
    # 自检里「只触发一条」的变异用例会失真)。
    [ -n "$hv" ] || continue
    if [ "$wv" = "$hv" ]; then
      printf '      %-26s %s\n' "$k" "$wv"
    else
      fail "卡片扩展的 $k=「${wv:-<缺失>}」与主程序「${hv:-<缺失>}」不一致 —— 系统会拒绝装载"
    fi
  done
  # 架构:与主程序同一份期望集合(少一个架构 = 那类 Mac 上卡片加载不了)
  WIDGET_NAME=$(plutil -extract CFBundleExecutable raw "$APPEX_PLIST" 2>/dev/null || true)
  WIDGET_BIN="$APPEX/Contents/MacOS/${WIDGET_NAME:-ReverbWidget}"
  if [ ! -f "$WIDGET_BIN" ]; then
    fail "卡片扩展没有可执行文件 Contents/MacOS/${WIDGET_NAME:-ReverbWidget}"
  else
    WARCHS=$(LC_ALL=C lipo -archs "$WIDGET_BIN" 2>/dev/null || echo '')
    echo "      卡片扩展架构:${WARCHS:-<读不出>}"
    [ -n "$WARCHS" ] || fail "卡片扩展二进制架构读不出来(lipo -archs 空)"
    for a in "${EXPECTED[@]}"; do
      case " $WARCHS " in *" $a "*) ;; *) fail "卡片扩展缺架构 $a" ;; esac
    done
  fi
  # 画廊文案:正文由 App 写,这里只要求每门语言都有表、且能取到那个键
  APPEX_WANT=("${WANT_LANGS[@]}")
  if [ ${#APPEX_WANT[@]} -eq 0 ]; then
    APPEX_WANT=($(find "$APPEX/Contents/Resources" -maxdepth 1 -type d -name '*.lproj' 2>/dev/null | while IFS= read -r d; do basename "$d" .lproj; done))
  fi
  for l in "${APPEX_WANT[@]}"; do
    f="$APPEX/Contents/Resources/$l.lproj/Localizable.strings"
    if [ ! -f "$f" ]; then
      fail "卡片扩展缺 $l.lproj/Localizable.strings —— 小组件库里的名字会退回英文/键名"
      continue
    fi
    lint=$(plutil -lint "$f" 2>&1 | awk -F': ' '{print $NF}')
    [ "$lint" = "OK" ] || fail "卡片扩展 $l 的 Localizable.strings lint 不过:$lint"
    # 编译后是二进制 plist 且键是 UTF-16,**只能 plutil 取**,grep 中文恒 0(与 iOS 那条同一个坑)
    [ -n "$(plutil -extract "继续收听" raw -o - "$f" 2>/dev/null)" ] \
      || fail "卡片扩展 $l 的 Localizable.strings 缺「继续收听」键"
  done
  # entitlements:沙箱是 WidgetKit 的装载前提;只读例外是卡片能读到 App 数据的**唯一**通道 ——
  # 漏了它不会报错,只会永久显示空态,所以必须在包上验。
  ENT=$(mktemp)
  if codesign -d --entitlements :- "$APPEX" >"$ENT" 2>/dev/null && [ -s "$ENT" ]; then
    # ⚠️ 这里**不能用 `plutil -extract com.apple.security.app-sandbox`** —— 键名里带点,
    # 而 plutil 的 key path 也拿点当分隔符,于是它报「No value at that key path」
    # (2026-11-09 自检第一跑就这样把正向用例拦成 2 条失败)。`plutil -p` 的文本形状稳定。
    if plutil -p "$ENT" 2>/dev/null | grep -q -F '"com.apple.security.app-sandbox" => true'; then
      :
    else
      fail "卡片扩展缺 com.apple.security.app-sandbox=true(WidgetKit 只装载沙箱扩展)"
    fi
    if plutil -convert xml1 -o - "$ENT" 2>/dev/null | grep -q -F -- "/Library/Application Support/Reverb/widget"; then
      echo "      entitlements:app-sandbox + 卡片目录只读例外"
    else
      fail "卡片扩展缺对 ~/Library/Application Support/Reverb/widget 的只读例外(卡片会永远显示空态)"
    fi
  else
    fail "读不到卡片扩展的 entitlements(签名没进去?)"
  fi
  rm -f "$ENT"
fi

# ---- 6. 签名:要真验,不是只 dump 描述 ------------------------------------
# `codesign -dvv` 是「读签名信息」,签坏了也可能照样打印;`--verify` 才是校验。
if codesign --verify --deep --strict "$BUNDLE" 2>/dev/null; then
  echo "   签名:codesign --verify 通过($(codesign -dvv "$BUNDLE" 2>&1 | grep -E '^Signature=' | sed 's/Signature=//' | tr -d ' '))"
else
  fail "codesign --verify 不通过"
fi

# ---- 结果 -----------------------------------------------------------------
echo "==> 验收结论:$([ "$FAILS" -eq 0 ] && echo '全部断言通过' || echo "$FAILS 条断言不通过")"
# 这一行不可省略:说清这次**没扫**什么,和说清扫到什么同等重要。
echo "   未覆盖范围:①界面与运行时行为(一帧都没跑;10-24 起这台就能出包,运行验收仍没做)②minos/sdk 的取值是否合意"
echo "   ③内置 seed_podcasts.json / guide_intro.m4a 是否存在(由 package.sh 警告,不判据)"
echo "   ④Assets.car 与图标资源 ⑤二进制里除上面这 ${#WORDS[@]} 个判据词以外的功能面"
[ ${#WANT_LANGS[@]} -gt 0 ] || echo "   ⑥语言齐不齐:本次没传 --langs,只验了「已有的每套 .strings 都能 lint」,没验「该有五套」"
[ "$FAILS" -eq 0 ] || exit 1
