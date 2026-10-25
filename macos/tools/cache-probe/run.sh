#!/usr/bin/env bash
# 缓存探针:把**产品源码**编成一个临时可执行文件,对本机的缓存做可复现断言。
#
# 为什么要有这一条:本仓库没有单元测试,而 M8(播放缓存)/ M9(封面磁盘缓存)里
# 那些"0 / 不算 / 拒绝"的结论(不含 `.part`、清缓存不碰订阅、坏图不落盘……)
# 只靠读代码是证明不了的 —— 硬规矩 1 的同一条:报 0 之前先证明扫描真的跑过。
# 所以每条判据都配了阳性对照,详见 probe.swift 里各段的注释。
#
# 判据落在真实的 ~/Library/Application Support/Reverb/ 上:`AppSupport.dir` 不认
# `HOME` 重定向(实测)。探针自己记录原有条目、收尾只删它新建的那些,但**跑之前**
# 那个目录里除了 `Logs` 不该有别的东西 —— 有的话先备份。
#
# 依赖:python3(只用来起一个本地静态文件服务器当图源/音源,不联网)
# 用法:bash macos/tools/cache-probe/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/Sources/Reverb"
WORK="${TMPDIR:-/tmp}/reverb-cache-probe"
SRV="$WORK/srv"

# 参与编译的产品源码。**改这几个文件的依赖时要同步这里** ——
# 少一个会在编译期直接报错(不会静默通过),这是刻意选的失败方式。
FILES=(
  "Data/Models.swift"
  "Data/Stores.swift"
  "Data/Log.swift"
  "Data/HTTPClient.swift"
  "Data/GuideEpisode.swift"
  "Data/AudioCacheStore.swift"
  "Data/ArtworkCache.swift"
  "Data/PopularCacheStore.swift"
  "Data/FeedCacheStore.swift"
  "Playback/AudioCacheManager.swift"
)

rm -rf "$WORK"
mkdir -p "$WORK/srv"
for f in "${FILES[@]}"; do cp "$SRC/$f" "$WORK/"; done
cp "$HERE/probe.swift" "$WORK/main.swift"

echo "== 编译(产品源码 ${#FILES[@]} 个 + 探针)"
swiftc -O -o "$WORK/probe" "$WORK"/*.swift

PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0))
print(s.getsockname()[1]); s.close()
PY
)"
echo "== 起本地图源/音源 127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# 等端口真的能接(只等,不 sleep 猜)
for _ in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then break; fi
  sleep 0.1
done

# `set -e` 下不能让探针的非 0 直接终止脚本,否则退出码就丢了
CODE=0
PROBE_SRV="$SRV" PROBE_PORT="$PORT" "$WORK/probe" || CODE=$?
echo "== exit=$CODE  工作目录=$WORK(探针自己会清掉 srv)"
exit $CODE
