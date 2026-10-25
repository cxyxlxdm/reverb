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

# ── Node 版本闸(H216,2026-10-25)─────────────────────────────────────────
# hvigor 的 native 任务(BuildNativeWithNinja)在清理目录时调 fs.rmdirSync(recursive),
# 这个 API 在 Node 23 起被整个移除 —— 本机 PATH 的 node 26 与 DevEco 自带的 node 24 都会炸,
# 报 Error Code 00308018 + "options.recursive is no longer supported"。debug 构建
# 之所以"没事",只是增量缓存让它跳过了那段清理;release 必走,一进就炸。
# 这里先解析 hvigorw 实际会用的 node(NODE_HOME 优先于 PATH,与 hvigorw 的查找序一致),
# 主版本 ≥23 就切到本机持久安装的 node 22(~/Library/OpenHarmony/,不进 brew 不进仓库)。
# 用户显式设过 NODE_HOME 的不动它 —— 尊重覆盖,哪怕设错了也让 hvigor 自己报。
resolve_node() {
  if [ -n "${NODE_HOME:-}" ] && [ -x "${NODE_HOME}/bin/node" ]; then
    echo "${NODE_HOME}/bin/node"; return
  fi
  command -v node 2>/dev/null || true
}
BUILD_NODE="$(resolve_node)"
NODE_VER="$("$BUILD_NODE" --version 2>/dev/null || echo v0)"
NODE_MAJOR="${NODE_VER#v}"; NODE_MAJOR="${NODE_MAJOR%%.*}"
if [ -z "$BUILD_NODE" ] || [ "${NODE_MAJOR:-0}" -ge 23 ]; then
  NODE22_DIR="$HOME/Library/OpenHarmony/node-v22.14.0"
  if [ -x "$NODE22_DIR/bin/node" ]; then
    export NODE_HOME="$NODE22_DIR"
    echo "▸ node ${NODE_MAJOR:-无} ≥23 会炸 release native 构建(H216),已切 NODE_HOME → node 22"
  else
    echo "✗ 将被 hvigor 使用的 node 是 ${NODE_MAJOR:-找不到} 版(≥23),release 的 native 构建必炸(H216),"
    echo "  且本机没有 node 22 可切。装一份(不走 brew,直接解官方 tarball,重启不丢):"
    echo "    mkdir -p ~/Library/OpenHarmony/node-v22.14.0"
    echo "    curl -sL https://nodejs.org/dist/v22.14.0/node-v22.14.0-darwin-arm64.tar.gz \\"
    echo "      | tar -xz -C ~/Library/OpenHarmony/node-v22.14.0 --strip-components=1"
    exit 1
  fi
fi

# build-profile.json5 不入库(存签名口令),新 clone 后需从模板复制再填
if [ ! -f build-profile.json5 ]; then
  echo "✗ 缺 build-profile.json5(它不入版本管理,因为存签名口令)"
  echo "    cp build-profile.template.json5 build-profile.json5"
  echo "  然后在 DevEco → Project Structure → Signing Configs 给 release 那条填三项口令。"
  exit 1
fi
if grep -q '"name": "release"' build-profile.json5 && \
   sed -n '/"name": "release"/,/}/p' build-profile.json5 | grep -q '"keyAlias": ""'; then
  echo "✗ build-profile.json5 里 release 签名的 keyAlias 还是空的,请先在 DevEco 里填。"
  exit 1
fi

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

# 签名段的三条前置校验(H123):装机测试临时改过包名之后,DevEco 的「自动生成签名」
# 会把 build-profile 的 **release 段一起改写**成新生成的调试材料 —— 那种包既装不了机也提交不了市场,
# 而要等 90 秒编译全跑完、停在 SignHap 才暴露。所以在这里 1 秒内判掉。
#   1) release 段指向的必须还是 signature/reverb.*(指向 ~/.ohos/config = 已被自动签名覆盖)
#   2) profile 里的 bundle-name 必须等于 AppScope/app.json5 的 bundleName(不等 = 00303074)
#   3) profile 的 type 必须是 release(调试型 profile 上不了架)
python3 - <<'PY'
import json, re, sys

raw = open('build-profile.json5', encoding='utf-8').read()
clean = '\n'.join(l for l in raw.split('\n') if not l.strip().startswith('//'))
sc = [x for x in json.loads(clean)['app']['signingConfigs'] if x['name'] == 'release']
if not sc:
    sys.exit('✗ build-profile.json5 里没有名为 release 的 signingConfig')
m = sc[0]['material']

app = open('AppScope/app.json5', encoding='utf-8').read()
bundle = re.search(r'"bundleName"\s*:\s*"([^"]+)"', app).group(1)

prof_path = m.get('profile', '')
ok, why = True, []
if 'signature/' not in prof_path:
    ok = False
    why.append('release 段的 profile 指向 %s —— 这是 DevEco 自动生成签名的材料,'
               '绑的是临时测试包名,不能提交市场。' % prof_path)
try:
    blob = open(prof_path, 'rb').read()
except OSError as e:
    ok = False
    why.append('profile 读不到:%s' % e)
    blob = b''
pfb = re.search(rb'"bundle-name"\s*:\s*"([^"]+)"', blob)
pft = re.search(rb'"type"\s*:\s*"([^"]+)"', blob)
if pfb and pfb.group(1).decode() != bundle:
    ok = False
    why.append('profile 绑的包名是 %s,而 AppScope/app.json5 是 %s(00303074)。'
               % (pfb.group(1).decode(), bundle))
if pft and pft.group(1).decode() != 'release':
    ok = False
    why.append('profile 的 type 是 %s(不是 release),这种 profile 上不了架。'
               % pft.group(1).decode())
if not ok:
    print('✗ 发布签名配置不对,先别编译:')
    [print('    ' + x) for x in why]
    print('  修法:DevEco → File → Project Structure → Signing Configs → 选中 release →')
    print('  Store file = ./signature/reverb.p12 / Profile = ./signature/reverb.p7b /')
    print('  Cert = ./signature/reverb.cer / Key alias = yuyin / 填明文口令 → Apply。')
    print('  (口令只有加密串存在 build-profile 里,被覆盖就只能重填,明文不在仓库 —— 见 H123)')
    sys.exit(1)
print('▸ release 签名段校验通过(profile 绑 %s / type release)' % bundle)
PY

VER_NAME=$(sed -n 's/.*"versionName"[^"]*"\([^"]*\)".*/\1/p' AppScope/app.json5 | head -1)
VER_CODE=$(sed -n 's/.*"versionCode"[^0-9]*\([0-9]*\).*/\1/p' AppScope/app.json5 | head -1)
echo "▸ 余音 Reverb  versionName=$VER_NAME  versionCode=$VER_CODE"

if [ "${1:-}" != "--fast" ]; then
  echo "▸ 清理构建缓存(避免资源走缓存,见脚本头部说明)"
  rm -rf build entry/build .hvigor/cache
fi

# ── 构建结果判定(见 REVIEW-2026-10-25 中-9)──────────────────────────────
# 原先这一行是:
#     "$HVIGOR" ... | grep -iE "ERROR|WARN|BUILD SUCCESSFUL|BUILD FAILED" || true
# 三个洞叠在一起,失败也能一路走到 exit 0:
#   1) 管道尾部的 `|| true` 把 **hvigor 自己的非零退出码**吞了(`set -o pipefail` 救不了带 || 的末段);
#   2) 一行都没匹配上(构建半途挂掉,既没打 ERROR 也没打 BUILD FAILED)同样被 `|| true` 放过;
#   3) 之后 `[ -d "$OUT" ]` 只证明**目录**在 —— 目录是上一次构建留下的,`--fast` 不清缓存,
#      于是 `cp "$OUT"/*-signed.app → dist/reverb.app` 拷的是**旧包**,末尾的 debugKey 校验
#      检的也是那个旧包(它当然不含 debugKey),脚本最后 exit 0。
#      审核原话:发出去的是上一次那个包,不是本次代码编出来的那份。
# 现在:整份输出进日志文件,先按 hvigor 的**退出码**判成败(失败就 tail 出来给人看),
# 再断言日志里有 BUILD SUCCESSFUL 且无 BUILD FAILED —— 两道都判是因为退出码与自述结果
# 理论上可以不一致(工具链把某个任务记挂但仍整体成功),宁可多一道。
# 日志放 mktemp 目录而不是工程内:非 --fast 会 `rm -rf build`,而构建缓存 `.hvigor/` 绝不入库(硬规矩 14)。
START_TS=$(date +%s)
BUILD_TMP=$(mktemp -d)
BUILD_LOG="$BUILD_TMP/hvigor.log"

echo "▸ 构建 release(含混淆)"
set +e
"$HVIGOR" assembleApp --mode project -p product=release -p buildMode=release --no-daemon \
  > "$BUILD_LOG" 2>&1
HVIGOR_RC=$?
set -e
grep -iE "ERROR|WARN|BUILD SUCCESSFUL|BUILD FAILED" "$BUILD_LOG" || true

if [ "$HVIGOR_RC" -ne 0 ]; then
  echo "✗ hvigor 退出码 $HVIGOR_RC —— 构建失败,日志最后 30 行:"
  tail -30 "$BUILD_LOG"
  echo "  (完整日志:$BUILD_LOG)"
  exit 1
fi
if ! grep -qiE "BUILD SUCCESSFUL" "$BUILD_LOG"; then
  echo "✗ hvigor 退出码 0,但日志里没有 BUILD SUCCESSFUL,不认这次构建。日志最后 30 行:"
  tail -30 "$BUILD_LOG"
  echo "  (完整日志:$BUILD_LOG)"
  exit 1
fi
if grep -qiE "BUILD FAILED" "$BUILD_LOG"; then
  echo "✗ 日志里出现 BUILD FAILED(和 BUILD SUCCESSFUL 同时打印说明有任务挂了),不出包。"
  echo "  (完整日志:$BUILD_LOG)"
  exit 1
fi

OUT="build/outputs/release"
[ -d "$OUT" ] || { echo "✗ 构建报成功却没有产物目录 $OUT,这不该发生;完整日志:$BUILD_LOG"; exit 1; }

# 产物新鲜度闸门:光有 BUILD SUCCESSFUL 还不够,得证明 dist 里那份是**本次**生成的。
# 审核给的写法是 `find "$OUT" -name '*-signed.app' -newermt "@$START_TS"`,但实测本机
# (macOS 的 BSD find)不认 `@epoch` —— `find: Can't parse date/time: @1792825404`,退出码 1;
# `-newermt "2026-10-25"` 那种日期串虽然能用,却要多过格式与时区两套解析。所以这里改成
# 拿 `stat -f %m` 的 mtime 与 START_TS 直接比数值:判据相同,中间没有任何解析环节。
# 留 2 秒余量:同一秒内写完的产物不该被判成旧(要防的"旧包"是上一次构建留下的,
# 时间差是分钟/天级,几秒余量挡不住它,不影响本条要防的事故)。
is_fresh() {
  [ -e "$1" ] || return 1
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || return 1
  [ "$m" -ge $((START_TS - 2)) ]
}

# 挑同类产物里 mtime 最新的一个(原先的 `ls | head -1` 按名字取第一个,
# 目录里同时留着 release 与旧文件时会挑错;--fast 场景下"最新"恰恰是判据要的语义)。
freshest() {
  local f best="" bt=-1 m
  for f in "$OUT"/$1; do
    [ -e "$f" ] || continue
    m=$(stat -f %m "$f" 2>/dev/null) || continue
    if [ "$m" -gt "$bt" ]; then bt=$m; best="$f"; fi
  done
  printf '%s' "$best"
}

DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -f "$DIST"/reverb.app "$DIST"/reverb-unsigned.app "$DIST"/reverb-symbol.zip

SIGNED=$(freshest '*-signed.app')
if [ -z "$SIGNED" ]; then
  echo "✗ 没有生成已签名包($OUT 里有:$(ls "$OUT" 2>/dev/null | tr '\n' ' '))。"
  echo "  只有 unsigned 的话:检查 build-profile.json5 的 release 签名配置。"
  exit 1
fi
if ! is_fresh "$SIGNED"; then
  # 这一条是 中-9 的正主:构建没真跑出产物时,绝不把上一次那份 cp 进 dist。
  echo "✗ $SIGNED 的修改时间($(stat -f '%Sm' "$SIGNED"))早于本次构建开始($(date -r "$START_TS" '+%Y-%m-%d %H:%M:%S')),"
  echo "  说明本次构建没有产出新的签名包 —— 那是**上一次**那个包,不能当本次发布物。"
  echo "  修法:去掉 --fast 全量重打(默认路径会清 build/entry/build/.hvigor/cache)。"
  exit 1
fi
cp "$SIGNED" "$DIST/reverb.app"

# 次要产物:一份备查、一份用于还原崩溃栈,都不直接进市场,所以不为它们挂掉整个发布;
# 但**过期的一律不拷** —— dist 里留一份和当前包不匹配的 mapping,比留个空更坏(崩溃栈会误导人)。
UNSIGNED=$(freshest '*-unsigned.app')
if [ -n "$UNSIGNED" ]; then
  if is_fresh "$UNSIGNED"; then cp "$UNSIGNED" "$DIST/reverb-unsigned.app";
  else echo "! $UNSIGNED 是旧产物,跳过不拷"; fi
fi
SYMBOL="$OUT/symbol/release/app-symbol.zip"
if [ -f "$SYMBOL" ]; then
  if is_fresh "$SYMBOL"; then cp "$SYMBOL" "$DIST/reverb-symbol.zip";
  else echo "! 符号包早于本次构建,跳过不拷 —— dist 里没有它就别上传旧的"; fi
fi

# 关键校验:确认签的是发布证书而不是调试证书。
# 早先就因为用调试签名打了"发布包",这一条能挡住同类事故。
# 顺带把这条校验自身的两个静默口子补掉(同 中-9 的"不许静默判过"口径):
#   - `unzip ... || true` + `grep ... 2>/dev/null`:unzip 没提出东西时 $HAP 是空文件,
#     grep 找不到 debugKey 就"通过"了 —— 校验实际什么都没做。现在先断言取到了内容。
#   - 上面加了新鲜度闸门之后,这里检的确定是本次那份(原先可能检的是旧包,白检)。
HAP="$BUILD_TMP/entry.hap"
unzip -p "$DIST/reverb.app" '*.hap' > "$HAP" 2>/dev/null || true
if [ ! -s "$HAP" ]; then
  echo "✗ 从 dist/reverb.app 里没取出 .hap,签名校验做不了 —— 不出包(别把'没查出问题'当'查过了')。"
  exit 1
fi
if grep -aq debugKey "$HAP" 2>/dev/null; then
  echo "✗ 包内含 debugKey —— 这是**调试签名**,应用市场会拒。请检查 product=release 的签名配置。"
  exit 1
fi
rm -rf "$BUILD_TMP"

echo
echo "▸ 产物(harmony/dist/):"
for f in reverb.app reverb-unsigned.app reverb-symbol.zip; do
  [ -f "$DIST/$f" ] && printf '    %-22s %6s KB\n' "$f" "$(( $(stat -f%z "$DIST/$f") / 1024 ))"
done
echo
echo "✓ 发布传 dist/reverb.app;符号文件 dist/reverb-symbol.zip 建议一并上传"
echo "  已确认不含 debugKey(发布签名)"
