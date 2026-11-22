# 余音 · Reverb 核心技术实现

> 四端(Android / HarmonyOS / macOS / iOS)的架构与关键实现,以及**为什么这样选**。
> iOS 直接编译 macOS 的 `Data/` 与 `Playback/` 源码,不复制一份;
>
> 范围划分:功能全貌见 `PRODUCT.md` / `FEATURES.md`;逐字稿单独成篇见 `TRANSCRIPT.md`;
> 具体故障的现象-根因-修法见 `TROUBLESHOOTING.md`;做的顺序与返工见 `HISTORY.md`。
> 本文只讲**结构与取舍**,不重复那几份里的细节。

规模(2026-08-25):

| | 语言 / UI | 行数 | 文件 |
|---|---|---|---|
| Android | Kotlin / Jetpack Compose | 11 434 | 67 |
| HarmonyOS | ArkTS / ArkUI | 11 756 | 58 |
| macOS | Swift / SwiftUI | 5 979 | 38 |
| native | C / C++(两端各一个模块) | 767 | 2 |

---

## 一、贯穿三端的四条约束

这四条是所有具体决定的上游,先说它们能省很多解释。

1. **零后端。** 没有服务器,也就没有账号、没有云同步、没有任何上传代码路径。
   取源只用公开免鉴权接口,播放一律回落发布方 RSS 里 `enclosure` 的原始直链。
   连带好处是版权干净、成本为零;连带代价是「跨设备一致」只能靠备份文件与
   1.0.2 起的系统级备份解决,两者都是备份/恢复语义,不是同步(见第五节)。
2. **功能对齐,交互各自原生。** 三端功能范围尽量一致,但不共用界面代码,
   也不把一端的交互习惯搬到另一端(macOS 用 `⌘,` 设置窗口而不是全屏设置页,等等)。
3. **合规是设计输入,不是事后检查。** 隐私同意门、渠道功能隔离都在架构层面体现
   (第六节),而不是在界面上加判断。
4. **"删掉"必须可验证。** 凡是声明某个渠道没有某功能,验收方式是**解包 grep**,
   不是点界面。这条是被真实事故逼出来的(H46 / H54)。

---

## 二、分层与依赖装配

四端同一套分层,自下而上:

```
model      数据模型(各端字段逐一对齐,便于缓存/备份格式互通)
net        HTTP + RSS 解析 + 取源策略
store      本地持久化(每个域一个 store,JSON 落盘)
playback   播放门面 + 系统媒体会话 + 下载
view/ui    界面
```

**依赖装配用手写容器,不引 DI 框架**:Android `AppContainer`、鸿蒙 `AppContainer`、
macOS 与 iOS `AppEnvironment`,都是全局单例,界面直接取用。理由很实际——这个规模的应用
引入 DI 框架带来的样板代码多于它省下的,而且手写容器让「哪些组件在什么时候装配」
一眼可见,这一点在做隐私门控时是刚需(第六节)。

**播放层是树外单例**。各端都把播放器放在界面树之外,所以界面重建(比如切换语言导致整树重建)
不会打断播放。

**iOS 的复用边界**:`macos/Sources/Reverb/{Data,Playback}` 原文件直接进 iOS target,
平台差异收在 `#if os(iOS)` 与分开写的 `@available(macOS 26, *)` / `@available(iOS 26, *)`
里;界面按触屏重写。所以改这两个目录**两端都要过编译门**,见 `docs/IOS.md`。

---

## 三、播放链路

| | 播放器 | 系统媒体会话 | 后台保活 |
|---|---|---|---|
| Android | **AndroidX Media3 / ExoPlayer** + `MediaSessionService` | Media3 `MediaSession` | 前台服务(`mediaPlayback`) |
| macOS | `AVPlayer` | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` | 不需要 |
| HarmonyOS | `@ohos.multimedia.media` `AVPlayer` | `@ohos.multimedia.avsession` | `backgroundTaskManager` 长时任务 |

几个共同的实现要点:

- **进度采样 500ms 一次**。这个频率是「进度条够顺 + 不浪费」的折中,但它给逐字稿带来了
  一个问题:跟读高亮会一跳一跳。解法是**逐帧外推**——记住上一次采样值与采样时刻,
  两次采样之间按真实流逝时间往前推。三端都实现了,手法一致
  (macOS `anchorMs`/`anchorAt`、Android `rememberExtrapolatedPosition`、鸿蒙 80ms `setInterval`)。
- **续播有护栏**:>3 秒才回跳,避免「刚点开就被甩回开头」;听到接近结尾自动标记已播完并归零。
- **但「用户明确指定那一秒」是另一套护栏,不能共用**:批注「跳回那一秒」走的是
  `PlayerController.playAt(episode, startMs)`,起点由调用方给、绕开 `history.positionFor`
  (否则点哪一条都落回上次听到的位置)。它只受「别跳过片尾」约束(距结尾 2 秒内不跳),
  **不吃那条 10 秒规则** —— 否则写在片尾 8 秒处的批注永远点不开,而那恰恰是用户指定的位置。
  Android 侧用一个一次性的 `pendingSeekExplicit` 区分这两种意图,落空时打
  `跳点落空 seek=… dur=… explicit=…`。**鸿蒙与 macOS 2026-10-01 已把这条一起带过去**
  —— 移植的是"两套容差"这个判定,不是那一行 `if`:一次性的 override 必须在
  `playEpisode` **取续播点的那一处**消费,放在入口清掉会连"这一集根本没开始"的那些早退路径
  一起吞掉(鸿蒙有一条「代次不匹配就早退」,先于取点发生)。
  **但要如实说清它防住了什么、没防住什么**:放在取续播处**只**挡住早退,**挡不住装载重试** ——
  鸿蒙与 macOS 的自动重试会**再进一次 `playEpisode`**,而那时 override 已被首轮消费掉,
  于是重试那一轮重新从 `history.positionFor` 取点 ⇒ 用户明确指定的那一秒回落成续播位置。
  Android 没有这个回落**不是因为它处理得更好,而是它压根没有自动重试**
  (`onPlayerError` 只记日志),`pendingSeekMs` 因此能活到 STATE_READY。
  这条窄窗口记在 `ROADMAP` A2-3#12,选的是**改口径而不是改代码**:要收敛得在鸿蒙/macOS 各加一份
  "这一集还没落地的显式跳点"状态,而重试路径是播放链最敏感的一段,本机既不能装机也不能运行,
  拿不上证据的改动不该动它。
  macOS 另外一点:**它本来就没有那条"距片尾 10 秒不如从头播"的启发式**(只有 `>3000`),
  移植时**没有**给它补上,补的只是显式跳点这一侧的上限 `dur-2000`。
  片尾 8 秒内那一条**两端已实跳验过**:Android 2026-10-05、鸿蒙 2026-10-07(一条距片尾 **2919 ms**
  的批注,`playAt` 落在按下那一刻的同一毫秒,且全程零条 `跳点落空 explicit=true`);
  **macOS 仍未验** —— 本机跑不了产物,见 ROADMAP 三-A。
- **睡眠定时最后 8 秒线性渐弱**,不是硬停。
- **开播淡入约 0.9 秒**,避免炸耳。
- **上一集/下一集由「队列上下文」决定**:用户队列优先,其次是进入播放时所在的列表顺序。
- **系统命令必须接幂等的明确动作**(鸿蒙,见 H83):AVSession 的 play/pause 回调接
  `resumePlayback()` / `pausePlayback()`,而不是 toggle —— 系统会重复派发同一命令
  (锁屏 / 控制中心 / 蓝牙 AVRCP 状态重同步),接 toggle 就会让「暂停被翻成播放」,
  1.0.0 曾因此出现熄屏静置后自动开播。Android / macOS 由 Media3 与 `MPRemoteCommandCenter`
  的显式命令天然满足,鸿蒙 1.0.1 才补齐。
- **鸿蒙的 AudioSession 是一条异步操作链**:每次意图变化记「目标态 + 代次号」,排到队头的
  过期任务直接跳过;播放中激活(`CONCURRENCY_PAUSE_OTHERS`)、暂停即撤销。快速暂停/继续
  不能依赖系统接口的完成顺序 —— 旧 activate/deactivate 迟到时,新代次一定紧跟着收敛。

---

## 四、取源与解析

**取源策略是多层兜底**(当前三个端都有在线目录层;Android 侧只有一份包,不再有渠道之分,H205):
Apple iTunes Search / Charts → fyyd.de → gpodder.net → RSS 直连。
一处不通自动换下一处,最终一律回到发布方自己的 RSS。内置 `seed_podcasts.json` 现在随
**唯一那份** Android 包走(合并 flavor 前商店那份没有),所以 Android 首次无网也有精选快照兜底;
**鸿蒙包里仍然没有它**,那条回退在鸿蒙上不成立。

**RSS 解析器三端各写一份,但规则对齐**,都要处理真实世界的脏数据:

- CDATA 必须计入(大量中文播客的简介用 CDATA 包裹)
- `channel > image > title` 不能覆盖频道标题
- 音频地址优先级:`enclosure[url]` > `media:content`(且必须确认是 audio)> Atom `link[rel=enclosure]`
- `podcast:transcript` 是**只有属性的空元素**,一集可能给多条,按格式排序取最优
  (JSON > VTT > SRT——JSON 稿一词一条,带词级时间)
- 时长字段 `itunes:duration` 有 `秒` / `mm:ss` / `hh:mm:ss` 三种写法

HTTP 层各用平台原生:Android **OkHttp**、macOS **URLSession**、鸿蒙 **`@ohos.net.http`**。
请求统一带 `User-Agent`,**不携带任何鉴权凭据与用户标识**。

**取源与解析在哪个线程上跑**:Android 在 IO 调度器、macOS 在 `Task` 里;
鸿蒙没有协程,所以整段(取 + 解析)进 `taskpool` 子线程 —— 否则大源的同步解析会占住
UI 线程近两秒(见第十节与 H65)。

### 视频来源的音频(1.0.6)

「粘贴视频链接当单集听」看着像加了一个源,实际只用了两个公开接口 + 一条取流约定,
三端各写一份 `BilibiliSource`(Android `data/remote/`、鸿蒙 `net/`、macOS `Data/`),
形状刻意对齐:都只暴露「解析一条链接 / 取音频候选 / 取流头」三件事。

| 环节 | 事实 | 为什么这样写 |
|---|---|---|
| 元数据 | `x/web-interface/view?bvid=` 给标题、封面、时长、UP 主名、`cid` | 单集需要的字段一次拿全,不必再请求 |
| 音频地址 | `x/player/playurl?bvid=&cid=&fnval=16` 给 `dash.audio[]`,三档码率 × 每档两条 `backupUrl` | 取最高档;备份地址是对方给的镜像,**失败时按序重试**,不要自己拼 |
| 请求头 | 两个接口都**必须**带 `Referer: https://www.bilibili.com/`,UA 用**浏览器身份**(三端统一 iPhone Safari 17_5 串) | 缺 Referer 一律 403;**搜索接口对桌面 Chrome UA 软拦**——`code=0` 但带 `v_voucher`、结果为空,看上去像"没搜到",其实是没给播放权限 |
| 时效 | 直链带 `deadline` = 请求时刻 + 2 小时 | 所以持久化的**不是直链**,而是伪地址 `bilibili://audio/<bvid>/<cid>`;每次起播前解析一次(与 RSS 的直链口径是两条路) |
| 付费(充电)内容 | `dash.audio` 为空,只给 `durl` —— 一个混流 mp4 预览(实测 21 分 0 秒 / 整条 25 分 39 秒,ffprobe 读出 h264 + aac);`view.is_upower_exclusive` 为真 | **不接 `durl`**;在搜索出口就过滤掉,`view` 出口也直接拒,免得表现成「播放条切走了、然后报错」(见 H231)。⚠️ 旧版本文写「约 30 秒试看」,实测不成立 |
| 关键词相关度 | 搜索接口是**模糊匹配**(标题 / 简介 / 标签都算命中),20 条里可能掺进与关键词无关的推荐条目;出口再按**标题强相关**过滤 | 规则只借 `bilibili-search-purify` 的严格匹配:去停用词/标点后标题含整词或任意 2 字片段;它的擦边/标题党词表是主观判断,不接(见 H241)。全滤空时退回原列表,宁留杂音也不白屏 |
| 下载 | 视频来源的单集不允许下载(UI 置灰),自动缓存照旧 | 见 `FEATURES.md` 六;缓存与下载是两本账,不必为一件事连坐 |

**取流头的注入点三端完全不同,这是这块最容易写错的地方:**
Android 用 Media3 1.3.1,它的 `DefaultHttpDataSource.Factory` 默认 UA 是 **null**,
而工厂设的 UA 是在 `DataSpec` 自带头**之后**应用的(会覆盖掉),所以正确做法是
`ResolvingDataSource.Factory` 在 `resolveDataSpec` 里补 `DataSpec.Builder.setHttpRequestHeaders`
——既让头跟着这一路请求走,又不会像 `setDefaultRequestProperties` 那样把 Referer 泄漏给所有播客主机;
缓存那一路是 OkHttp,自己带头。鸿蒙是 `createMediaSourceWithUrl(url, headers)`(API 12+);
macOS 要 **`AVURLAssetHTTPHeaderFieldsKey` + `AVURLAssetOutOfBandMIMETypeKey: "audio/mp4"` 两条都给**。

踩过的四个坑各有编号,不要在这里重复结论,直接看:
UA 与接口的矩阵(H218)、「不带头也能播」的假绿(H219)、Media3 的覆盖顺序(H220)、
鸿蒙的 `CONTAINER_ERR` 其实是 403(H221)、直链两小时失效(H222)、macOS 缓存必须 `.m4a`(H223)。

鸿蒙与 macOS 这两份实现只过了编译门,运行验收未做(见 `ROADMAP.md`)。

### 直播流:只认响应头(1.0.7)

「把一路网络电台的地址粘进搜索框直接听」没有目录层、不收录、不需要后端 —— 用户点名的那一条,
与「粘 RSS」「粘视频链接」同一性质。三端各写一份 `LiveStream`(Android `data/remote/LiveStreamSource.kt`、
鸿蒙 `net/LiveStream.ets`、macOS `Data/LiveStream.swift`),形状对齐:只暴露
「这是不是像一条流 / 探一下、成则合成一集」。

**判据只有一条:响应必须自己表明它是音频流。** 收三种信号,任一成立即通过:

| 信号 | 覆盖的病 |
|---|---|
| `Content-Type` 落在 `audio/` 大类下(或 `application/ogg`) | 绝大多数 Icecast / Shoutcast 的 MP3 / AAC 直出 |
| HLS 的 MIME(`application/vnd.apple.mpegurl` 等)或路径以 `.m3u8` 结尾 | 播放列表不是网页,有的服务器 MIME 写得不规范 |
| 带任意 `icy-` 响应头 | ICY 协议自己的身份;顺带取 `icy-name` 当标题 |

`text/html` **一律拒绝** —— 粘一个普通网页或一条失效的 RSS 地址,不该被当成直播播出去。
`416` 与 `2xx` 同等看待:服务器认 Range 但一个字节也取不到(空流/地址尾正好在末尾)时,响应头仍然有效。
探测请求带 `Range: bytes=0-0` + `Icy-MetaData: 1`:前者只要我们拿到头就够(不把整路音频拖下来),
后者让支持 ICY 的服务器把 `icy-*` 头带回来。

**三端探头的机制完全不同,这是这块最容易写错的地方:**
Android 走 OkHttp 的 `enqueue` + 回调,响应一到就 `call.cancel()`;macOS 走
`URLSessionDataTask` + `URLSessionDataDelegate` 的 `didReceive response` 里 `completionHandler(.cancel)`
(**不能用 `session.data(for:)`**,见 H225);鸿蒙**不能用 `Http.probeCode`** —— 那个函数用
`request()`,它会等到整个响应体收完才返回,对一条无限长的音频流永远不返回。
鸿蒙必须换 `requestInStream` + `on('headersReceive')`,再接一条硬超时兜底(见 H237)。

**合成出来的那一集只有 `isLive = true` 这一个是特殊的**,其余都按普通 `Episode` 处理,
好让播放、队列、界面复用同一条路径。`id` 带地址(`live:<url>`),于是同一路流的两次粘贴视为同一集,
重复点不会在队列里堆两条。`durationSec = 0` —— 流没有分集边界。

**抑制项全部以 `isLive` 为闸**(三端同语义):不写历史、不写音频缓存、不计收听时长、
不存「上次在播哪一集」的播放态、不记断点、播完不自动续下一集、逐字稿页不出、
**倍速控件收起**(线性源没有"快进"这回事;鸿蒙的 AVPlayer 对直播直接拒绝设倍速,见 H239,
三端一起藏,免得同一颗控件在一端能按、一端按了没反应)。
最后一条理由是「流没有时间轴」;**界面闸门写成 `isLive && (时长未知 || 播放器判直播)`** ——
粘一条**有长度**的音频文件时,时长一到就恢复进度条与跳转(它按普通单集播);
而 HLS 直播的"时长"是**播放列表窗口的长度**(实测 60 秒),不是节目长度,
只看「时长未知」会退化成一条永远走不完的进度条(见 H238)。

**探测与目录搜索并行**,不是串行:串行要等 RSS 层的 12 秒兜底超时才轮到探测,
粘一条电台地址的体感会变成"卡十几秒才出声"。三端的写法都是「搜索与探测各起一条,
哪条先回先上屏」,且都按同一道查询版本号闸门丢弃过期结果。

**已知边界**:流掉线即停,不做自动重连。1.0.7 只到「当集听」,常驻电台列表与投播自 1.0.9 起补上(见下两节)。

### 直播电台(1.0.9):目录是第三方地址,清单是本地账本

顶层「电台」页把两类东西分开:**可留存的电台地址**(用户自己的账本)与**只读来源**(在线目录、随包精选)。

- **账本** `stations.json`,字段只有 `name / url / group / country`(group 取 `news / music / talk / retro`,
  文案在界面本地化)。地址是唯一键:添加与编辑都先查重,重复直接拒绝。
- **在线目录** `radio-browser.info`:先 `de1`,失败再 `de2`;请求不登录、不带用户标识,
  日志只记条数与错误类(不记搜索词、不记完整地址)。目录结果是只读的,要保留必须复制进账本。
- **随包精选** `shared/radio/stations.json`(16 条,只读)。`shared/radio/sync.sh` 分发到四端资源,
  自带 `--check` 供提交前校验。它与种子播客的合规口径不同:这份按维护者决定四端都带。
- **起播**不新造播放路径:现场合成 `isLive=true` 的 `Episode`(`id=live:<url>`),
  与粘贴地址那条同 id,所以同一路流不会在队列里出现两次。
- **备份**:只进手动备份的 `stations` 段;**不参与局域网同步**。同步的删除传播靠墓碑账本,
  给电台另开一套会把本轮拖进同步协议与两端 UI;电台被定义为"这台设备上的快捷方式",
  换机靠恢复备份即可。真要日常同步时,按 `SyncTombstones` 的现有形状补,不要在 `LanSyncMerge` 里直接塞分区。

### 投播(1.0.9):一端自研 DLNA,三端交系统

| 端 | 机制 | 关键约束 |
|---|---|---|
| Android | 自研 DLNA:`SsdpDiscovery` 发 `M-SEARCH`(ST MediaRenderer:1,目的 `239.255.255.250:1900`)→ 设备描述 XML → AVTransport `controlURL`;`DlnaClient` 发 SOAP 1.1 `SetAVTransportURI` / `Play` / `Pause` / `Stop` | 持 `MulticastLock`(同局域网同步,H276);描述 XML 用 **DOM** 解析 —— JVM 单测里 `XmlPullParserFactory` 是 android.jar 的 stub,会把解析静默打回 null。直播用 `audioBroadcast`、点播用 `musicTrack`,`protocolInfo` 用 `http-get:*:*:*` 放行 HLS。投播成功本机 `pauseIfPlaying()`(只暂停,队列与位置保留);换集或停止时同步 `Stop` 设备那一路 |
| HarmonyOS | 系统 `AVCastPicker` 组件,复用已有的音频 AVSession | 不自己扫网、不加权限、不接三方 SDK;系统完成发现与传输 |
| macOS / iOS | 系统 `AVRoutePickerView` 的 SwiftUI 包装(`RoutePickerView.swift`,两端各一份) | 路由由系统 AirPlay 负责,音频仍走本端 `AVPlayer`;桌面端电台页工具栏另有一枚 |

**状态机的落点**:Android 的 `CastController` 挂在应用级容器(`AppContainer.cast`),不放 ViewModel ——
弹层关掉之后电视仍在播,状态不能随界面销毁。**本会话没有真实渲染设备可用**,四端的投播链路都未做运行验收,
Android 只到纯逻辑单测 8 条。

---

## 五、持久化与备份

### 每个域一个 store,JSON 落盘

Android 的文件清单(**鸿蒙完全同名**;macOS 除热榜缓存与随包种子清单的存放方式略有不同,
其余同名):

```
subscriptions.json  favorites.json   history.json      inbox.json
downloads.json      stamps.json      notes.json        listen_stats.json
feed_cache.json     popular_cache.json  playback_state.json
audio_cache.json    transcripts/<单集>.<语言>.json
stations.json       (1.0.9;直播电台账本)
```

**`audio_cache.json` 是「播放缓存」的账本,它与 `downloads.json` 是两套文件、两本账、两个清理入口**
(2026-10-12 Android 与鸿蒙同时落,macOS 未做)。三条口径值得在移植时照抄:

- **为什么不是"边播边存"**:鸿蒙的 AVPlayer 播 http 流时**字节不经过 JS 层**,这一端压根拿不到数据;
  Android 侧虽有 `CacheDataSource` 这条现成的路,仍选**同一条语义** —— 首播时后台把整集拉全。
  换来的是"缓存目录里的每一个文件都是完整可离线播的一集"这个可验证的简单不变式,
  代价是多一次流量(受同一道蜂窝闸门管)。
- **三层分离是结构性的**:目录 `audio_cache/` vs `downloads/`、账本 `audio_cache.json` vs `downloads.json`、
  设置页两颗按钮各清各的。预算淘汰(300 MB / 按最久没听)**只遍历缓存账本**,
  所以"缓存把用户点名下载的那一份挤掉"在实现层就不成立,不靠界面判断。
- **选源次序 = 下载 → 缓存 → 流式**,而且这一步必须**同步**返回(鸿蒙复用已有的 `localFileProvider` 链:
  引导音频 → 下载 → 缓存)。所以缓存命中表是内存 `Map<id, 绝对路径>`,
  不能在那个调用点上 `fs.stat` —— 那是把 IO 摊进播放链路(硬规矩 6)。
  账本里的每一条**开机时按"文件在、非空"逐条同步校验**(条目数由预算封顶,个位数),
  真正 O(文件数) 的目录扫描(清孤儿文件与半截 `.part`)排在异步那一轮,不在启动路径上。
- **电台流不缓存**:直播流没有"整集"可存,而且每台几十 MB 会把预算刷爆。
- 封面图片另有第三层缓存:Android 复用 Coil 的磁盘缓存,**鸿蒙是自研 `store/ArtworkCache.ets`**
  (ArkUI 没有带磁盘缓存的图片库;20 MB 预算、限并发 4、无账本文件 —— 目录扫描就是它的账)。
  它计入设置页同一个"缓存"数字,与音频那两层同进同退。

**`playback_state.json` 是"会话态",但里面装着用户资产**(2026-10-02 Android 先落,
2026-10-06 鸿蒙同构并真机验过,macOS 待移植):`{version, current, listTag, context[], contextIndex, upNext[]}`。
一条反馈同时暴露了两个症状 —— 「加入队列的节目下次打开就没了」和「找不到正在播放栏」——
而后者早就存在,只是它的显示条件是 `current != null`,而 `current` 与前两样一起躺在内存里(见 H129)。
下面几条口径值得在移植时照抄:
- **上下文只存窗口**:以当前集为中心的前后各 40 集。整列可能是上千集 × 1 KB,
  每次动作同步写几 MB 是 H65 那笔账的同一个形状;到边界表现为「上一集/下一集」置灰,重点列表即恢复。
- **同步写,不走去抖**(Android `JsonWriter` / 鸿蒙 `JsonFile.writeJsonDebounced*`):
  去抖的代价(进程被杀丢掉最后一次)正是这条反馈的本体。
- **恢复现场,不恢复意图**:预载到就绪但保持暂停。`playWhenReady=false` 要排在 `prepare()` 之前,
  否则控制器会保留上一次的 `playWhenReady`(默认 true)并自己开播。
  鸿蒙没有 `playWhenReady`,对应物是内部标志 `playbackDesiredPlaying`(消费点在 `prepared` 分支的
  「若不希望播放就到此为止」),因此**同样必须在 `prepare()` 之前按下去**;而 `startEpisode` 原本
  无条件把它置真,所以移植时给它加了第三个参数 `autoplay`,恢复路径传 `false`。
  预载的隐私口径(打开应用即向发布方拉一次流)同步写在 `docs/PRIVACY.md` 第三节。
- **不进任何备份**:它不在 Android 的 `backup_rules.xml` / `data_extraction_rules.xml`、
  也不在鸿蒙的 `backup_config.json` 白名单里,同样不占手动备份的分区(那 9 项的**键名**是三端互通契约;
  顺序不是 —— 三端按键名读,见 ROADMAP A2-4)。
  判断标准与 `notes.json` 相反 ——
  批注是用户写出来的字,丢了补不回来;队列里每一集都能从历史或订阅里再找到。
- **电台模式不落 `current`**:电台的上下集走内存里的 `radioHistory`(随机抓来的序列,退出即弃),
  把它写成上下文会让重启后的「下一集」跳进一个不相干的列表。
- 由它引出的那道地闸值得单独记:**「当前集」现在会先于「播过」而存在**,
  所以一切由播放器状态派生的回写都要按**事件**设闸(`playbackStarted`,本会话真的响起过才回写进度),
  不能按**字段**(`current != null`)—— 后者会把用户上次听到的位置静默抹成 0(见 H129)。

**`notes.json` 是三端共用的一份格式,而且它是「嵌套」不是「摊平」**:
单条 = `{noteId, positionMs, text, createdAt, episode:{…整条单集}}`。
`noteId` 刻意带前缀 —— 内嵌的那份 `episode` 自己就有 `id`(= 全仓查表主键),
两者摊进同一个对象时后写的静默盖掉先写的、没有任何冲突信号(见 H127)。
新增一端时照这个结构写,不要顺手复用其它 store 的引用式写法。
`createdAt` 与 `positionMs` **都是毫秒**(2026-10-01 逐端核过写入点:Android
`System.currentTimeMillis()` / 鸿蒙 `Date.now()` / macOS `timeIntervalSince1970 * 1000`)。
macOS 端解码**不做秒/毫秒归一** —— 没有一端写秒,归一只会把真正的单位 bug 吃掉;
将来改口径按硬规矩 11 加版本号让旧数据作废。

**正因为它是共用的,守门点只能在读取侧。** 这份文件实际有四个写入方:三端各自的 `add`、
应用内手动恢复(`addAll`)、系统级备份还原(**整份文件覆盖回来,不经过 `addAll`**)、手工编辑。
所以硬规矩 10 那条"不变式在数据出口保证"在这里落地成三端同形的一条 `normalize`,
接在**读盘与恢复两处**(Android `load()`/`addAll`、鸿蒙 `load()`/`addAll`、macOS `init()`/`addAll`):
按 `createdAt` 倒序 + `positionMs < 0` 归 0(三端用的都是稳定排序,同一毫秒的两条不打乱先后)。
**读盘侧刻意不套 `add` 那条「上限夹到该集时长」**:那里夹得住是因为手上有播放器实时位置作真值,
而读盘时唯一可比的 RSS 元数据时长是发布方自报的近似值,常常比真实音频短 ——
用一个近似上限去改写用户早就写下的那一秒,比留着越界值更糟(时间戳自己跳位而用户不知道谁改的),
越界值到播放那一步由播放器按真实时长夹。逐条见 H138。

为什么是**一堆小 JSON 而不是数据库**:数据量小(订阅几十条、历史上百条)、
读写模式简单(整体读入内存 + 变更后整体落盘)、而且**备份/恢复与跨端互通都变成了文件拷贝**。
代价是不适合大数据量与复杂查询——目前没有这类需求。

落盘一律「失败静默、不影响内存态」:持久化坏了也不能让应用不可用。

### 收听时长:一个 G-Counter

「按频道累计实际听过的时长」的难点全在备份恢复:**同一份备份重复恢复不能翻倍,
换机恢复要正确汇总,各设备自己新听的不能被抹掉。**

做法是按**设备分账**:`{ 设备ID: 毫秒 }`,展示值取各设备之和,
备份合并规则是**按设备取 max**(不是相加)。这正好是一个 G-Counter CRDT,
上面三条性质自然成立。

计数口径也需要说清:累计的是**相邻进度采样的正向增量之和**,
且只在「同一集 / 正在播放 / 增量 ≤3 秒」时计入——于是 seek 跳过与暂停都不会被算进去,
倍速播放按内容时长计(1× 下等同耗时)。约每 5 秒落盘。

### 恢复的合并规则是保守的

历史按 `updatedAt` 取新——**旧备份不会让当前进度倒退**(这是踩过之后加的)。

### 系统级备份(1.0.2):向操作系统声明白名单,而不是自己写上传

手动备份(合并语义)之外,Android、鸿蒙与 iOS 还向操作系统声明了**文件级白名单**,
由系统把数据备份到用户自己的云(Google/厂商云、厂商云、iCloud)或换机直连——
应用没有参与上传的代码路径:

- Android:`allowBackup="true"` + `backup_rules.xml`(API≤30)+
  `data_extraction_rules.xml`(API31+,`cloud-backup` 与 `device-transfer` 两节)。
  **只写 include** —— 未列出的一律不进备份,音频、逐字稿、缓存、日志与
  随包的 239 MB 语音模型被隐式排除(单应用云备份 25 MB 配额)。
- 鸿蒙:`module.json5` 声明 `type:"backup"` 扩展 +
  `resources/base/profile/backup_config.json` 白名单。注意路径是**虚拟沙箱**
  `/data/storage/el2/base/haps/entry/...`,且鸿蒙偏好文件**无 .xml 后缀**。
- iOS:系统备份默认覆盖整个沙箱,**没有 include 白名单**,只能反向排除。
  `AppSupport.excludeFromBackup(_:)` 给音频下载、音频缓存目录与账本、封面、
  逐字稿、榜单缓存、播放态快照、`inbox.json` 与日志打
  `com.apple.metadata:com_apple_backup_excludeItem`;剩下进备份的正好是
  Android/鸿蒙白名单那一组。**新增落盘目录要记得加这一句**,否则它会悄悄进用户的 iCloud。
- 与手动备份的口径差异:系统备份按**整文件**复制,设置里会带上 device_id 与
  privacy_version(手动备份刻意不导出 device_id,恢复合并按设备取 max 不受影响)。
  两份 Android 规则文件必须同口径维护,只改一份就是给 API 分层埋雷(H84)。

它是「备份/恢复」而非实时同步;`downloads.json` 恢复后音频不在,列表不会自动出现。

### 局域网同步(1.0.8):复用备份 JSON,自己管传输

目标只有一句:**两台设备在同一 Wi-Fi 下,一键把订阅/收藏/印记/批注/历史/收听统计合并成并集**。
它不是"文件互传",双方跑完拿到的内容一致;也不经过任何服务器(约束一)。
**分区固定为六项**,不含 1.0.9 新增的直播电台(`stations`)—— 电台只走手动备份,理由见「直播电台」一节。

**传输层选 TCP,不选 WebSocket/HTTPS。** 四端都有 TCP socket 系统 API,而 WebSocket
在 Android/鸿蒙上通常要引库或自己写握手,多一个库就多一条"三方 SDK"审查面。
线格式自己定:**4 字节大端长度 + UTF-8 JSON**;握手帧明文,配对之后全部是密封信封
`{"n":<nonce b64>,"c":<密文+tag b64>}`。单帧上限 8 MiB,快照切 256 KiB 块,整份上限 64 MiB。
用长度前缀而不是换行:密文里任何字节都可能出现,包括 `0x0A`。

**发现是 mDNS/DNS-SD(`_reverb._tcp`)+ 手动地址,两条都必须有。**
访客 Wi-Fi、AP 隔离、企业网络经常让组播到不了对端;所以面板上永远显示本机地址,
并保留手动输入 `IP:端口`。发现成功只影响"顺不顺",不影响"能不能"。
服务名只放短 id(`Reverb-<8 hex>`),设备名放 TXT(`nm`)—— 服务名要参与主机名规则,
中文与空格都要转义;TXT 原样传 UTF-8 省事。

**Android 的发现是两条路并行**(2026-11-12,H265):系统 NSD + 自己发的 **QU 查询**。
后者从临时端口向 `224.0.0.251:5353` 发一条类字段带 `0x8000` 的 PTR 查询,应答方按
RFC 6762 单播回来 —— 不经过 AP 的组播转发,所以「组播只丢一个方向」的 AP 上也能用
(实测 H3C:NSD 永远为空,QU 3 秒内列出 Mac)。**面板打开期间另持一把 `WifiManager.MulticastLock`**
(`CHANGE_WIFI_MULTICAST_STATE`,normal 权限;2026-11-13 加,见 H276):有的设备(实测 Pixel 3)
上系统 NSD 没有关掉驱动的组播过滤,不持锁时 `mdnssd` 既不发查询也不收应答,
鸿蒙因此永远发现不了;锁是设备级,NSD 与 QU 一起受益,`stop()` 即释放。
QU 报表编解码是 `MdnsCodec`(只认 PTR/SRV/TXT/A 四类与 IPv4)。
两路结果在控制器里取并集、互不清空;系统 NSD 侧另有解析超时、队列去重与
`FAILURE_ALREADY_ACTIVE` 退避 —— 那个 API 没有取消接口,一次不回调会卡住全局解析槽位。

**四端跑的是同一份协议**(鸿蒙 2026-11-13 并入):`sync/LanSyncCrypto` / `LanSyncMerge` /
`SyncTombstones` 在和谐侧各有一份 ArkTS 实现,键派生用系统的 `cryptoFramework`(EC + ECDH +
HKDF + AES-GCM)。**HKDF 的 spec 有个坑:`algName` 只能写基名 `'HKDF'`**,写成 `'HKDF|SHA256'`
(与 `createKdf` 的参数同形)会在 `JsKdfGenerateSecret` 里报 `build context fail.`,症状像网络问题(见 H273)。

**密钥不依赖平台证书体系。** 每台设备一份安装级身份,但**身份里没有密钥**:只有 16 位十六进制
设备 id + 显示名 + 创建时间,存 `lan_sync.json`。P-256 密钥对在**每次配对的 `greet()` 里现生成**,
握手结束即丢弃;共享密钥经 HKDF-SHA256 派生会话密钥;
同时从共享密钥派生**六位配对码(SAS)**,两台设备并排显示、由人核对一致才继续。
所以**同一对设备每轮配对的 SAS 都不同**,会话密钥之间也没有关联(前向保密)。
1.0.8 早期版本曾把一对长期密钥当会话密钥用,导致 SAS 每轮相同 —— 原因、症状与验证见 H278。
没有 CA、没有 TOFU —— 局域网里任何设备都能冒充"附近的一台",六位码是唯一让人参与判断的一步。

**数据复用备份 v1 的六个分区**,不为同步另造格式:
`SUBSCRIPTIONS / FAVORITES / STAMPS / NOTES / HISTORY / LISTEN_STATS`。
两端各自 `BackupManager.build` 出快照、传过去、再 `BackupManager.apply` 合并;
返回**合并前后之差**作为"新增条数"。订阅按规范化后的 feed URL 去重
(Apple `collectionId` 与 RSS `feedUrl` 会指向同一档)。

**生命周期跟界面绑定**:打开面板才监听,关闭即停 socket;同一时刻只跑一个会话。
两端同时点对方时,后到的连接会被拒绝并提示重试 —— 比两端各跑两个会话、弹两次码清楚。
P0 不做锁屏/后台常驻。

**删除靠墓碑账本传播(2026-11-12 补)**:六段里可删的四样(订阅 / 收藏 / 印记 / 批注)
各在本地记一笔 `kind + id → deletedAt`,保留 90 天,文件 `sync_tombstones.json`
(Android `sync/SyncTombstones.kt`、Apple `Sync/LanSyncTombstones.swift`,同一份契约)。
快照多一个 `tombstones` 段;合并顺序固定为「先并墓碑 → 按墓碑删本地 → 过滤快照里的同 id 条目 → 常规 apply」,
否则删掉的条目会在同一次同步里被对端原样带回来。订阅的键用归一化 feedUrl(与去重同一判据)。
**取舍**:墓碑优先于对端快照 —— 订阅/收藏没有 `updatedAt`,"重新添加晚于删除"无法证明,
要彻底解决得给每条记录带 HLC(研究文档 §5)。历史与收听统计不参与:前者 LWW、后者按设备取 max。

**跨端范围**:Android 与 macOS/iOS 已落地;**鸿蒙 2026-11-13 并入并真机双向跑通**
(`harmony/entry/src/main/ets/sync/` 下四份 ArkTS 实现,协议与 Apple/Android 同一份契约,
见 H273 的 HKDF 坑)。iOS 与 macOS 共用 `macos/Sources/Reverb/Sync`
与 `UI/LanSyncView.swift`,iOS 工程对这批共享文件是显式引用(见 H260/H261)。

**同步之后的播放交接(2026-11-15,四端)**:不新开连接、不重配对 —— 复用刚才那条**已认证的 TCP**,
在同一把会话密钥下继续跑一小段「加时赛」。握手帧里多一个 `live: true`;老版本忽略它,同步完照旧断开,
新版本读到没有这个键就不进读循环,所以**不是协议版本变更**,也不存在「两端必须同版本」的硬门槛。

```
hello  {id,name,pub,nonce,live:true}
pb     {t,ep?,pos,dur,playing,rate,at}   // 1 Hz(仅在播放时)+ 暂停/跳转/换集立即补
ping   {t,t0}   pong {t,t0,t1,t2}        // 时钟同步,开通道先打 5 发(间隔 400ms),之后 5s 一发
take   {t}      taken {…同 pb 形状…} / {t:"taken",none:true}
```

- **状态帧 `pb` 里的 `ep` 去掉 `description`**:shownotes 是几十 KB 的常客,1 Hz 原样发等于每秒传一篇稿;
  接手只要 id / 标题 / 音频地址 / 封面。`at` 是发送者墙钟,只用于显示外推,不参与排序。
- **位置外推**:ping-pong 四时间戳算 `rtt = (t3−t0)−(t2−t1)` 与 `offset = ((t1−t0)+(t2−t3))/2`,
  取 5 个样本的**中位数**;少于两样本、或中位 rtt > 2 s 就标 `approximate`,界面写「约」;
  外推只在 `elapsed ∈ (−5 s, 60 s)` 内生效,避免对端时钟被改/休眠很久后画出离谱的位置。
- **交接的时序是固定的**:请求方点「在此设备继续」→ 只发 `take`,**不先播**;播放方收到后
  **先暂停**再回 `taken`(带暂停后的最终 pos/dur/rate/ep);请求方拿 `taken` 算
  `handoffPosition = pos + rtt/2 × rate`,上限 `dur − 1500 ms`,seek 后起播。
  用往返一半而不是时钟偏差,是因为这里只需要知道「这条消息在路上走了多久」,两台的墙钟差多少无关。
  这个顺序保证**两端不会同时出声**;`take` 有超时,超时后迟到的 `taken` 不会再把播放器拽走。
- **IO 与心跳分两条协程**:读循环阻塞在对端帧上,`take()` 只改一行状态、不碰 IO;
  `writeFrame` 加了互斥 —— 心跳与 `take` 可能同时写,两条帧的 `writeInt + write` 交错就是对端永远解不开的坏帧。
- **超时口径**:同步期 socket 读超时 30 s;进交接前必须 `soTimeout = 0`,否则对端暂停、长时间只发心跳,
  一条好连接会被判成「网络中断」。结束时靠关 socket 收尾,不靠超时。
- **边界**:只在「正在播放」时按 1 Hz 发;从不自动接管 / 自动播放;直播流不参与;
  关面板 = 断 socket(P0 不后台常驻)。产品口径见 `docs/research/2026-11-11-lan-sync.md` §6。

---

## 六、渠道隔离:一份 Android 包 + 三种工具链的做法

这是整个项目最需要架构层面处理的合规问题。目标不是永久规定商店包「必须没有目录」,
而是让每次产品决策都能在产物中验证。

**2026-10-18 的一次口径变化(见 H205)**:Android 的 `default` / `store` 两个 flavor 合并成
**唯一一份包**,大陆商店与 GitHub Releases 传同一个 `dist/reverb.apk`。于是这一节描述的机制
在 Android 侧从「两份 source set 各装什么」变成「一份包 + 三个可降级的编译期常量」。
鸿蒙仍是商店单渠道,macOS 仍自分发,那两端的隔离手法不变。

### Android:一份包 + 三个备用闸

```
app/src/main/     唯一的源码与资源:ASR 工厂(返回 SenseVoiceEngine,1.0.8 前是 WhisperEngine)、
                  libs/sherpa-onnx.jar + jniLibs/*.so、assets/sensevoice/ 模型与词表、
                  内置种子、AndroidManifest 里的 RECORD_AUDIO / REQUEST_INSTALL_PACKAGES、全套文案
app/src/{default,store}/   ← 已删除(H205)
```

隔离手段只剩一种,而且它的作用也跟着变了:

- **编译期常量 + R8**:`BuildConfig.CATALOG` / `BuildConfig.SPECTRUM` / `AsrFactory.HAS_ENGINE`
  三个 `const` 现在都是 `true`(= 功能全开)。它们不再是"渠道差异的实现",而是**合规回退时的
  一行降级闸**:某条口径要求收回目录、真实频谱或本机转写,把对应常量降到 `false`,R8 会折叠掉整支代码。
- **⚠️ 这条降级只删代码,不删文件**(硬规矩 3):两个 `.so`、239 MB 模型与词表、内置种子在 `src/main` 里,
  降到 `false` 之后**包里仍然有它们**。真要做到「包里没有」,得把文件本身移出构建树
  (`tools/build-asr.sh` 是把它们放进来的那一步)。合并前这件事是靠 store 的 source set 天然保证的,
  现在那层保护没了 —— 所以降级档必须按下面那套解包 grep 重验一遍。
- **文案侧**:合并前关于页与部分副标题在 `src/store/res` 里各有一套(资源**覆盖**,不是继承,见 H169);
  合并时把两边都带进 `src/main/res`,五语各从 353 键变成 367 键(1.0.8 换引擎后又加了三条许可,
  2026-11-11 现数是 402)。**改资源时数一下键数** ——
  覆盖语义下漏一个键不会报错,只会静默用另一套。

### HarmonyOS:没有 DCE,降级必须移出编译树

**ArkTS 没有 DCE。** `Features.CATALOG ? A : B` 的两支都会进包。
此前为纯 RSS 口径,目录实现整体移到 `harmony/shelved/`;H70 恢复目录时又把 `Sources.ets`
移回编译树并接回降级链。若合规要求再次降级,不能只把开关设为 `false`,必须重新把目录实现
移出编译树。这个工具链差异不因 Android 合并 flavor 而失效 —— **两端"降级"的代价完全不同,别互相类推。**

> 这是一条不能类推的经验:**"编译期开关能删代码"取决于工具链有没有 DCE。**
> 同样的写法在 Kotlin/R8 下成立,在 ArkTS 下不成立;而在**任何**一端,它都删不掉 `.so` 与 assets。

### 验收方式写死在流程里

```bash
# Android 唯一那份,当前期望(1.0.8 / H205):四项全非 0
unzip -l dist/reverb.apk | grep -icE 'lib/|assets/sensevoice/'         # 4(两个 .so + 模型 + 词表)
unzip -l dist/reverb.apk | grep -cE 'assets/seed_podcasts\.json'       # 1
unzip -p dist/reverb.apk classes.dex | LC_ALL=C grep -ao 'itunes.apple.com\|fyyd\|gpodder' | wc -l  # 13(4/5/4)
"$SDK/build-tools/<ver>/aapt2" dump permissions dist/reverb.apk | grep -c uses-permission  # 12(含 RECORD_AUDIO;1.0.8 新增 CHANGE_WIFI_MULTICAST_STATE)
# HarmonyOS 商店包:目录 URL 非 0;1.0.8 起本机转写产物也在(sherpa har 的 .so + rawfile 模型/词表),
# 真实频谱产物仍不存在
unzip -l dist/reverb.app 'resources/rawfile/sensevoice/*' | grep -cE 'model\.int8\.onnx|tokens\.txt'   # 2
unzip -l dist/reverb.app | grep -cE 'libs/arm64-v8a/lib(sherpa|onnxruntime)'                            # 非 0
```

> ⚠️ 1.0.8 之前这条写的是 `grep -icE 'lib/|whisper-model'` = 2、目录 URL = 14(那是**命中行数**)。
> 换引擎之后**两个模型文件的名字与个数都变了**(whisper 一个 `.bin` → 模型 + 词表两份),
> 而 dex 只有一份、R8 后的字符串布局也变了,所以期望值必须重算,不能照抄旧行。
> 上面这组是 2026-11-11 在那份 270,119,993 B 的发布包上现跑出来的;目录 URL 改用
> `grep -ao | wc -l` 按**出现次数**计(4 / 5 / 4),与"命中行数"不是同一算法。

合并那一轮为了证明「合并包 == 在架的 default 包」,用的判据是 `aapt2 dump resources` 两份各 6405 行、
`0x7f` 条目各 655 个、**整表 diff 为空**,zip 条目名各 173 个、diff 同样为空;并各注入一个负控制
(拿旧 store 包比 → 262 行差异)证明这两个「0」不是没扫成。

期望值随产品决策翻转,方法论不变:声明加回来也要验,声明删掉也要验;翻转时同步
`docs/FEATURES.md`。**中文字符串要用 `LC_ALL=C grep -a` 对原始字节搜**——
`resources.arsc` / `resources.index` 里的中文不是 ASCII,`strings` 看不见,曾因此差点得出错误结论。

---

## 七、隐私门控:同意之前一个组件都不装配

被个别渠道以「同意隐私政策前获取 SSID」判过一次不通过。根因不在自己的代码:
Android 的媒体播放库与后台任务库在判断网络类型时会调用系统接口,
该接口在 Wi-Fi 下返回的对象**顺带**携带 SSID。我们既不读也不存,
但**调用发生在同意之前**——合规看的是行为发生的时间点。

架构上的解法是把装配拆成两段:

```
boot()        本地读写:Prefs、各 store 从磁盘拉起、文案装配
              ——不联网、不读系统网络信息,可以在同意之前做
startGated()  播放层、系统媒体会话、周期更新任务、电台配置
              ——只能在用户同意之后调用
```

三端同一结构(Android `MainActivity.startGatedComponents`、
鸿蒙 `AppContainer.startGated` + `Index` 里的整树门控)。
**同意门本身不分渠道**,Android 那份唯一的包与鸿蒙都会出——这一点曾在文档里写错,
而它的直接后果是同意页正文必须把**麦克风权限、离线识别与应用内更新**如实说明。
合并 flavor 后 Android 侧这三件事在两个分发处**恒为存在**,正文不必再按版本分别措辞(见 H205)。

同意状态**存的是「已同意的政策版本号」而不是布尔**:政策有实质性变更时把版本号 +1,
所有用户会再看一次。

---

## 八、逐字稿:三端同形状、取字方式完全不同

> 完整取舍见 `TRANSCRIPT.md`,这里只讲架构位置与两个跨端的关键设计。

```
TranscriptStore   状态机 + 缓存(三端同一 JSON 格式,带 version)
  ├── 官方稿      RSS 的 podcast:transcript,支持 SRT / WebVTT / Podcast Index JSON
  └── 本机转写    macOS: SpeechAnalyzer | Android / 鸿蒙: sherpa-onnx + SenseVoiceSmall
TranscriptLines   断行与时间插值(所有来源共用同一份实现)
TranscriptSearch  全文搜索:命中的句子 + 每句内的高亮区间(一次算完,渲染只查表)
TranscriptExport  纯文本 / Markdown 两种导出(三端逐字节一致)
TranscriptPane    第三页:跟读高亮 + 自动滚动 + 点句跳转 + 搜索条 / 导出菜单
```

搜索与导出的分工是硬规矩 6 的直接应用:匹配**在查询变化时扫一遍**,结果是
「命中句的下标 + 每句内的字符区间」;渲染侧每行只查一次表,当前句每帧重建高亮时不再回看稿子。
全文搜索的语义、导出格式与三端一致性判据见 `TRANSCRIPT.md` 四。

### 设计一:缓存带版本号

`{ localeId, complete, version, segments[] }`。**时刻算法一变就 +1**,
旧稿自动作废重转。这条是被真实事故逼出来的:改完时间轴算法之后,
用户设备上已生成的稿仍按旧口径显示——界面无从分辨,于是"修了等于没修",
而用户也没有清缓存的入口自救。

### 设计二:时间轴的不变式在数据出口保证,不在渲染侧兜底

渲染判断"读到哪个词/哪句"用的是「从后往前找第一个 `startMs <= now`」。
这个写法**只在起点单调不减时才正确**——队尾只要混进一个异常小的值
(某个 token 没算出时刻、退化成 -1),它就永远满足条件,于是**高亮钉死不动**。

与其在渲染侧每帧兜底,不如在**数据出口处**一次性保证「时刻全部 ≥ 0、起点单调不减」:
Android 在 `SenseVoiceEngine.wordsFrom` 里做(1.0.8 前在 C++ 侧 `tidyWords`),
共享的 `TranscriptLines.monotonic` 再兜一层
(尤其覆盖发布方给的稿——别人生成的文件不能假定排好序)。

> **鸿蒙的渲染侧不真的做整表回溯**(2026-10-06 起):逐字稿页每一行问的是
> 「本行起点已过 **且** 下一行起点还没到」,与"从后往前找到的那个下标 == 本行"在单调前提下
> **逐行等价**(主机端 fuzz 过 1,000,000 组 (稿子, 时刻) 组合、0 处不一致)。原因不是性能偏好,
> 是语言限制:ArkUI 的 `@Builder` 里**不能声明局部变量**,拿不到 Android 那个
> "顶层算一次下标再往下传"的形状,而存成字段就要管失效。**整表回溯仍然在,只是留给
> `autoScroll` —— 它要的是下标本身。上面那条不变式依赖一字未变**(见 H137)。

### 章节表:与逐字稿同一种形状,但不进备份

```
RssParser          <podcast:chapters url type> 按 type 打分只留一条(JSON+chapters > JSON > 不要)
Episode            chaptersUrl / chaptersType —— 必须随 Episode 一起落盘,否则重启后入口消失
ChaptersFetcher    取一次 JSON(上限 1 MiB、带源凭据 UA、日志只记 endpoint);四端解析口径一致
ChapterStore       Idle → Loading → Done / Empty / Failed,缓存带 version + url 双判据
PlayerScreen/View  进度条上方一行当前章节;弹层列表点一条 seek(startMs)
```

只有两处与逐字稿不同,都是**故意**的:

1. **按需取,不预取。** 逐字稿是第三页,滑到就要显示;章表藏在一次点按后面,
   冷启动时没有人看得见那份列表,先请求一次只是白耗流量。
2. **不进备份。** 章表能从 RSS 再取一遍,与音频 / 逐字稿缓存同待遇;备份只带
   `chaptersUrl` 这个"哪里能取到"的地址。

**缓存形态按端不同,判据同一条**:

| 端 | 落点 | 形态 |
|---|---|---|
| Android | `filesDir/chapters/<hex16(集id)>.json` | 一集一个文件 |
| 鸿蒙 | `filesDir/chapters_cache.json` | 单文件,最近 80 集按使用淘汰;请求带代次,晚回来的旧结果不覆盖刚换的那一集 |
| macOS / iOS | `Application Support/Chapters/<sanitize(集id)>.json` | 一集一个文件;`version 1`;排除在 iCloud 备份外;读取是同步的(几 KB),命中即出 |

苹果两端的 `ChapterStore` 是共享层的一个 `@MainActor ObservableObject`;
`AppEnvironment` 把它的 `objectWillChange` 转发进自己的,所以观察 `env` 的视图
不需要额外注入就能跟着刷新。入口按需取:macOS 是 popover,iOS 是 sheet。
`PlayerView` 在切集时只调 `prepare(episodeId:)` 复位状态机(**不发请求**),
真正的 `load(episode:)` 发生在弹层第一次出现时。

**`Episode` 的新字段必须穿过每一份扁平快照。** 四端都不是"把 Episode 整个序列化":
搜索 / 历史 / 下载 / 收藏 / 待播 / 播放态 / 备份各有一份 DTO 逐字段拷贝,
`decodeIfPresent ?? ""` 让旧文件"读得进、不报错",漏列的新字段则永远回到默认值 ——
章节入口冷启动后消失就是这么来的(见 H259)。苹果这一处还连带把此前一直漏的
`transcriptUrl` / `transcriptType` 补上。

不变式同样在**数据出口**保证:`ChaptersFetcher.parseChapters` 负责排序、同秒去重、
负时刻夹 0 —— 渲染侧只做「从后往前找第一个 `startMs <= position`」,与逐字稿同一条前提。

> ⚠️ **验收边界**:Android(Pixel 3)、鸿蒙(Mate 60)、iOS(iPhone 17 模拟器)都实跑过
> 在线 / 缓存 / 空 / 失败四条("失败"指章表地址 404);**macOS 只过编译门与单测**,
> 界面运行验收固定在另一台机器(见 `ROADMAP.md` 三-A),别把它当"四端界面都跑过"。

---

## 九、本机识别的 native 面:Android 已无自写 C++,鸿蒙仍有一个

### Android:不再有自写的 JNI(1.0.8 起)

whisper 时代这里有一个约 100 行的 `reverb_asr.cpp`,换引擎时**整层删掉了** ——
sherpa-onnx 上游 AAR 自带 `classes.jar`(Kotlin API)与 arm64 的 `libsherpa-onnx-jni.so` + `libonnxruntime.so`,
我们只需要 `app/libs/sherpa-onnx.jar`(245,045 B)+ 两个 `.so`(22,249,560 / 4,609,320 B)。
收益不是"少写代码",而是**少一处崩溃时没有栈可看的地方**,也不用再维护 NDK 交叉编译。

分工因此变成:音频解码在 Kotlin(`PcmDecoder`)、分块也在 Kotlin(`SenseVoiceEngine`),
native 只做"吃 16k 单声道 float PCM、吐识别结果"。R8 这一侧有一条硬要求:

- **`-keep class com.k2fsa.sherpa.onnx.** { *; }`** —— JNI 按 `RegisterNatives` 查类名与方法名,
  混淆后会 `UnsatisfiedLinkError`。这条只在 release 暴露,debug 包完全不报;
  1.0.8 的签包验收就是靠"装 release、真转一集"发现的。

whisper 时代的两条教训仍然成立,只是不再对应本端代码:`NewStringUTF` 与多字节 token 的边界
(现在由上游 JNI 处理,但**词级时间戳的 token 仍可能不带空格**,组行时仍要自己拼)、
以及 native 日志必须接出来(库静默降级只有日志能看见)。历史细节见 `HISTORY.md` / H59 / H60。

### HarmonyOS:`reverb_pcm.cpp`(NAPI ↔ 系统编解码)

**ArkTS 层完全没有解封装/解码 API**(`AVPlayer` 拿不到 PCM,`AVTranscoder` 只能输出 AAC),
而识别引擎(1.0.8 起是 sherpa-onnx)只吃 16k 单声道 PCM——所以这一层不可省。
sherpa-onnx 本身以 **HarmonyOS har(1.13.3)** 引入,`.so` 由依赖带进包,
不需要自己交叉编译;引擎装在 `playback/asr/AsrWorker.ets` 的 `ThreadWorker` 里,
主线程只收片段与状态(为什么必须分开见 `TRANSCRIPT.md` 三)。

用 API 20 起的**同步**编解码接口(`OH_AudioCodec_QueryInputBuffer` 那一套),
于是整条链是一个普通循环,没有回调线程、没有条件变量。三个必须知道的点:

- **同步模式要显式打开**(`OH_MD_KEY_ENABLE_SYNC_MODE = 1`),"不注册回调即同步"是错的;
- **解码器配置要把轨道格式原样交过去**,自己拼一个只有采样率/声道数的最小格式会缺
  `aac_is_adts` 与 `CODEC_CONFIG`,于是每帧 `Invalid data found`;
- **任何 pump 循环都要有"连续 N 轮无进展就放弃"的闸**——否则取不到数据就空转刷日志,
  调用线程再也回不来。

接线上还有几个 NAPI 的坑(`napi_module` 在哪个头、`.so` 不能 `requireNapi`、
`file:` 依赖要跑 `ohpm install`),记在 `TROUBLESHOOTING.md` H61。

---

## 十、性能:两条从事故里提炼的规律

### 渲染路径里不做解析

播放页观察播放器,而播放中 **500ms 一次 tick 就重渲一遍**。
早先每次重渲都把几十 KB 的 shownotes HTML 重跑十道正则,
于是主线程每秒被占两次——轻则 CPU 长期高位,重则直接卡死。

修法是把解析移出渲染路径(记忆化,只在换集时重算)、按段懒排版、
按当前页门控高频动画(看不见的页上不跑动画与逐帧计算)。

**规律**:每秒会跑两次的代码,要按每秒两次来估成本。

### 不要用"程序化操作也会触发的信号"去识别用户操作

逐字稿的自动滚动曾用 `isScrollInProgress` 判断"用户在滚",
但 `animateScrollToItem` **自己也会**让它为真——于是自动滚动触发了针对自己的抑制,
净效果是每 4 秒才跳一下,看上去就是"高亮压根不跟着念"。

改成只认真正的手指动作(Android `DragInteraction`、鸿蒙 `onTouch`)。

**规律**:`isScrollInProgress`、`onValueChange` 这类信号分不清是谁干的,
要用只有人能产生的事件。

### 状态的**观察粒度**决定重渲范围(鸿蒙特有)

ArkUI V1 的 `@Observed` / `@ObjectLink` 是**对象级**观察:被观察对象的任何字段被赋值,
所有持有者都会重跑 `build()`,而且**不区分 private**。于是 `PlayerController.positionMs = t`
(AVPlayer 的 `timeUpdate` 约 100ms 一次)让播放中的整页每秒重建十次 ——
实测静置 10 秒 62 帧 jank,下拉刷新时最明显(H64)。

做法上分三层:

1. **高频量搬进普通对象**:`playback/PlaybackClock.ets` 承载播放位置、ticker 跳数、
   收听计数基线;`ListenStatsStore` 的未落盘累计量同理。嵌套的非观察对象不参与依赖收集。
   `positionMs` 保留成 getter —— 读法不变,但不建立依赖。
2. **需要连续值的界面各自轮询**,频率按自己的精度需求定:进度条 250ms、
   迷你条细线 1s(且按整数百分比去重)、逐字稿沿用 80ms 外推心跳。
3. **高频刷新下沉到最小组件**:进度条独立成 `view/SeekBar.ets`,
   于是进度更新不再重渲包含轮播三页 + 水墨画布 + shownotes 长文的整个播放页。

同一条规律也管着与系统的通信:AVSession 的播放状态原先跟着 500ms ticker 推,
改成「状态签名变了 or 实际位置与系统外推值差 >1.5s」才推 —— 系统本来就会按
`elapsedTime + (now − updateTime) × speed` 自己外推。

### 重解析必须离开 UI 线程 —— 而 ArkTS 没有协程

**"异步"只保证等待不阻塞,不保证计算不阻塞。** `Http` 的 await 是异步的,但
`XmlPullParser` 的逐 token JS 回调、每集一遍的 `htmlToText`、上千个对象的构造全是同步 JS:
一个 8.5 MB / 1026 集的订阅源实测解析 **1833ms**,一轮 15 源刷新约 **4.5 秒**占着 UI 线程(H65)。

Kotlin 那边一句 `withContext(Dispatchers.IO)` 就搬走了,ArkTS 只能用
`@Concurrent` + `taskpool`(`net/FeedTask.ets`)。两个刻意的决定:
**连网络一起搬进子线程**(8.5 MB 的字符串压根不出现在 UI 线程的堆上,跨线程只传 url 与结果),
以及**保留回落本线程的降级**(子线程不可用时宁可卡一下,不让刷新整个失效)。

配套的一处:去抖写盘要**连"生成数据"一起去抖**。`JsonFile.writeJsonDebouncedLazy`
传的是取值函数而不是值 —— 否则频道缓存每源一次 `put` 就把整份 600KB 重新序列化,
一轮刷新做 15 遍,而去抖只省下了写盘。

### 三端各自把重活放在哪(同一原则,三种机制)

| | 取源与解析 | 周期落盘(播放中每约 5 秒) | 逐字稿缓存 | 下载写盘 |
|---|---|---|---|---|
| Android | `withContext(Dispatchers.IO)` | `JsonWriter`:400ms 去抖 + IO 线程,收**取值函数** | `Dispatchers.Default` 协程 | `Dispatchers.IO` + `byteStream()` 流式 |
| macOS | `Task` / `URLSession` | `AppSupport.save`:去抖 + 后台串行队列 | `Task.detached` 编解码 | `URLSession.downloadTask`,系统托管 |
| HarmonyOS | `@Concurrent` + **taskpool**(`net/FeedTask.ets`) | `JsonFile.writeJsonDebouncedLazy` | taskpool(`store/TranscriptTask.ets`) | `requestInStream` 分片 + 异步写 |

三处共同的约定:**退出/切后台前必须同步补一次落盘**
(Android `MainActivity.onStop` → `JsonWriter.flush()`、macOS `willTerminate` →
`AppSupport.flushPending()`、鸿蒙 `EntryAbility.onBackground` → `JsonFile.flushPending()`)——
去抖的代价就是那一个窗口,不补就会丢用户刚听到的位置。

而**用户单次操作触发的小数据**(订阅、收藏、印记)三端**都仍是同步写**:
一次点按几毫秒看不出来,而同步写没有"进程被杀丢一次"的窗口 —— 那些是用户明确做出的动作。

### 滚动驱动的收束:判据在哪一层、几何在哪一层(1.0.5,两端同语义)

迷你播放条"向上滚就收进底栏那一行"这件事,层的划分是三端共用的,机制各不相同:

| | 收束判据挂在哪 | 怎么认"是用户在滚" | 两态之间的几何 |
|---|---|---|---|
| Android | 外壳 `Box` 上的 `NestedScrollConnection.onPostScroll`(**父级连接**,吃 `consumed.y`) | 只认 `source ∈ {Drag, Fling}`(硬规矩 9:程序化滚动不算意图),按**累计量** ±40dp 翻转、翻转后清零 | **一条** `animateFloatAsState` 的分数派生全部量(块高/球槽宽/内外缝/落点/栏透明度),多条曲线会读出"散架" |
| HarmonyOS | 页面自己的 `onDidScroll` → `Index.feedScroll(dy)`,累加完写 `@StorageLink(MORPH_KEY)`(`AppStorage` 的 `miniCollapsed`) | 同一档 ±40vp 累计量、同样翻转后清零;回调**每帧都跑**,里面只许加减法和一次布尔比较 | 不手写"分数 × 长度":`.animation({curve: morphSpring()})` 吃**两个字面量**,插值交给 ArkUI |

两端的**原始符号不一样**:鸿蒙的 `dy` 是"这一帧滚了多少"(往后翻为正),Android 的 `consumed.y`
**与手指方向反号**(向上划为负),所以 Android 在出口处换算一次。落到用户手上的语义是同一句:
**往后翻收束、往回滚展开**。

两条容易写成"看起来对、上机就废"的:

1. **落点那道 `lift` 必须在组件内部由同一条分数派生,不能在外壳按值取动画分数传进去。**
   后者会让外壳逐帧重排三张满屏列表 —— 渲染路径的成本按"每秒两次"估(硬规矩 6/7)。
2. **动画分数进任何有非负约束的量之前,先钳一次**(`f.coerceIn(0f, 1f)`,五处几何都读钳过的值)。
   0.86 是欠阻尼,落点过冲 ≈0.5% —— 观感上是零,约束检查上不是零。这条与第八节那条
   「时间轴的不变式在数据出口保证」是同一个口径:**一次在出口保证,不逐个量各补**。

判据本身还带两个反直觉的坑(现象、数字、取证全过程都在 `TROUBLESHOOTING` **H180 / H181**):
Compose 的 `consumed.y` **与手指方向反号**(向上划报负值),以及
`Modifier.align` **传不进 `AnimatedVisibility` 的内容槽**(被它自己那层容器吃掉,整块退化成顶对齐)。

---

## 十一、构建与产物

| | 命令 | 产物 |
|---|---|---|
| Android | `android/build-release.sh` | `dist/reverb.apk`(**1.0.8 起约 270 MB**,含 239 MB 模型;1.0.7 是约 65 MB)+ mapping —— **唯一那份**,同时交大陆应用市场与 GitHub Releases(合并 flavor 前还有 `--store` 出的 3.9 MB 那份,H205) |
| HarmonyOS | `harmony/build-release.sh` | `dist/reverb.app`(约 952 KB)+ 符号包 |
| macOS | `macos/package.sh` | dmg |

几条刻意的构建约定:

- **大产物不入版本管理**:SenseVoiceSmall int8 模型(239,233,841 B)、词表(315,894 B)与
  sherpa-onnx 的 `classes.jar` + 两个 `.so` 由 `android/tools/build-asr.sh` 一条命令备齐
  (下载 + sha256 校验,`.jar` 从上游 AAR 里解出);
  `build-release.sh` 在引擎启用时检查它们在不在,缺了直接报错退出。
  Gradle 另对 `.onnx` / `.bin` 开 `noCompress`,否则 `openFd` 拿不到长度、首次拷贝会变慢。
- **打包脚本自带校验**:校验产物的 `applicationId` 与签名者 DN(调试证书直接 exit 1)。
  合并 flavor 前它还要判"这个包是哪一个渠道"——两个包同名同包名,搞错会传错处;
  现在只有那一份包,这一层判据随 `--store` 一起退出脚本(`build-release.sh:46` 注释)。
- **鸿蒙默认清构建缓存**:hvigor 的资源编译任务会命中缓存——换过图标/字符串后照常
  `BUILD SUCCESSFUL`,但包里仍是旧资源(H39)。发布包一年打不了几次,宁可多等 10 秒。
- **开发期工具与产物分开**:比如 `android/tools/glass-shot.sh`(截图)与
  `play-button-check.sh`(播放键几何)只用于开发,不进任何 APK;ASR 的主机端探针
  随 whisper 一起在 1.0.8 删除了,选型期的实测方法与读数留在研究文档里。

---

## 十二、这套架构的已知边界

写清楚不适用的地方,比只讲优点有用:

- **没有跨设备实时同步**。零后端的直接代价;换机靠手动备份文件(合并)与
  1.0.2 起的系统级备份(白名单、用户自己的云),都是一次性恢复而非同步。
- **一堆小 JSON 不适合大数据量**。订阅上千、历史上万条时需要换成数据库。
- **鸿蒙端 11.8k 行里有一部分是"补偿代码"**——ArkTS 缺解码 API 要写 native、
  系统图标不够要写映射表。这部分不产生功能,只为对齐。
- **本机语音转写的成本是真实的**:自分发 Android 版 1 小时单集约 6.5 分钟满载计算;
  鸿蒙因系统能力不足暂时没有(见 `TRANSCRIPT.md`)。
- **macOS 没有后台更新检查**,靠手动刷新;也没有真实频谱(平台无等价能力)。
- **投播只覆盖系统给的口子**:Android 走 DLNA、Apple 走 AirPlay、鸿蒙走系统投播组件;
  不支持 Chromecast 等需要三方 SDK 的私有协议 —— 这是「不接三方 SDK」约束的直接结果。
- **在线电台目录依赖 `radio-browser.info`**:它不可用时只剩随包的 16 条精选与用户自己的账本;
  不内置全量目录,也不做目录缓存。
