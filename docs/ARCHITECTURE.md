# 余音 · Reverb 核心技术实现

> 三端(Android / macOS / HarmonyOS)的架构与关键实现,以及**为什么这样选**。
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

三端同一套分层,自下而上:

```
model      数据模型(三端字段逐一对齐,便于缓存/备份格式互通)
net        HTTP + RSS 解析 + 取源策略
store      本地持久化(每个域一个 store,JSON 落盘)
playback   播放门面 + 系统媒体会话 + 下载
view/ui    界面
```

**依赖装配用手写容器,不引 DI 框架**:Android `AppContainer`、鸿蒙 `AppContainer`、
macOS `AppEnvironment`,都是全局单例,界面直接取用。理由很实际——这个规模的应用
引入 DI 框架带来的样板代码多于它省下的,而且手写容器让「哪些组件在什么时候装配」
一眼可见,这一点在做隐私门控时是刚需(第六节)。

**播放层是树外单例**。三端都把播放器放在界面树之外,所以界面重建(比如切换语言导致整树重建)
不会打断播放。

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
  三端都**未实跳验证过片尾 8 秒内那一条**(见 ROADMAP)。
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

**取源策略是多层兜底**(当前三个端与两个渠道都有在线目录层):
Apple iTunes Search / Charts → fyyd.de → gpodder.net → RSS 直连。
一处不通自动换下一处,最终一律回到发布方自己的 RSS。大陆商店 Android / 鸿蒙仍不打包
内置 `seed_podcasts.json`,所以首次无网且无缓存时没有精选快照回退。

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

---

## 五、持久化与备份

### 每个域一个 store,JSON 落盘

Android 的文件清单(**鸿蒙完全同名**;macOS 除热榜缓存与随包种子清单的存放方式略有不同,
其余同名):

```
subscriptions.json  favorites.json   history.json      inbox.json
downloads.json      stamps.json      notes.json        listen_stats.json
feed_cache.json     popular_cache.json  playback_state.json
transcripts/<单集>.<语言>.json
```

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
  也不在鸿蒙的 `backup_config.json` 白名单里,同样不占手动备份的分区(那 8 项的顺序是三端互通契约)。
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

手动备份(合并语义)之外,两端还向操作系统声明了一份**文件级白名单**,
由系统把数据备份到用户自己的云(Google/厂商云、厂商云)或换机直连——
应用没有参与上传的代码路径:

- Android:`allowBackup="true"` + `backup_rules.xml`(API≤30)+
  `data_extraction_rules.xml`(API31+,`cloud-backup` 与 `device-transfer` 两节)。
  **只写 include** —— 未列出的一律不进备份,音频、逐字稿、缓存、日志与
  57 MB 语音模型被隐式排除(单应用云备份 25 MB 配额)。
- 鸿蒙:`module.json5` 声明 `type:"backup"` 扩展 +
  `resources/base/profile/backup_config.json` 白名单。注意路径是**虚拟沙箱**
  `/data/storage/el2/base/haps/entry/...`,且鸿蒙偏好文件**无 .xml 后缀**。
- 与手动备份的口径差异:系统备份按**整文件**复制,设置里会带上 device_id 与
  privacy_version(手动备份刻意不导出 device_id,恢复合并按设备取 max 不受影响)。
  两份 Android 规则文件必须同口径维护,只改一份就是给 API 分层埋雷(H84)。

它是「备份/恢复」而非实时同步;`downloads.json` 恢复后音频不在,列表不会自动出现。

---

## 六、渠道隔离:三种工具链,三种做法

这是整个项目最需要架构层面处理的合规问题。目标不是永久规定商店包「必须没有目录」,
而是让每次产品决策都能在产物中验证。H70 后商店渠道恢复 `CATALOG`,但仍关闭
`SPECTRUM` / `LOCAL_ASR`,并且不打包内置种子。

### Android:flavor + source set + R8

```
app/src/main/     共享代码与两个渠道共用的目录隐私说明
app/src/default/  自分发渠道:AsrFactory(返回 WhisperEngine)、jniLibs/*.so、assets/模型、
                  AndroidManifest 里的 RECORD_AUDIO、ASR / 麦克风相关文案
app/src/store/    商店渠道:AsrFactory(返回 null)、无 native / 模型 / RECORD_AUDIO、
                  无本机转写与真实频谱的渠道文案
```

两种机制配合:

- **编译期常量 + R8**:`BuildConfig.CATALOG` / `AsrFactory.HAS_ENGINE` 是 `const`,
  R8 能折叠关闭的代码分支。当前商店渠道的 `CATALOG` 已开启;若合规要求回退,再关闭并验包;
- **source set**:R8 **删不掉 `.so` 与 assets**,native 库、模型和种子是构建系统按 source set
  打进包的——所以商店渠道仍靠「那个 source set 里压根没有这些文件」保证不含 ASR 与内置精选。

### HarmonyOS:没有 DCE,降级必须移出编译树

**ArkTS 没有 DCE。** `Features.CATALOG ? A : B` 的两支都会进包。
此前为纯 RSS 口径,目录实现整体移到 `harmony/shelved/`;H70 恢复目录时又把 `Sources.ets`
移回编译树并接回降级链。若合规要求再次降级,不能只把开关设为 `false`,必须重新把目录实现
移出编译树。这个工具链差异不因当前恢复目录而失效。

> 这是一条不能类推的经验:**"编译期开关能删代码"取决于工具链有没有 DCE。**
> 同样的写法在 Kotlin/R8 下成立,在 ArkTS 下不成立。

### 验收方式写死在流程里

```bash
# Android 商店渠道当前期望(H70):目录 URL 非 0;native / 模型 / 录音权限仍为 0
unzip -l dist/reverb-store.apk | grep -icE 'lib/|whisper-model'              # 0
LC_ALL=C cat classes*.dex | grep -ac 'itunes.apple.com\|fyyd\|gpodder'       # 非 0
aapt2 dump permissions dist/reverb-store.apk | grep -c RECORD_AUDIO         # 0
# HarmonyOS 商店包:目录 URL 同样非 0,本机转写与真实频谱产物仍不存在
# 自分发渠道:whisper 模型与 native 库必须都有
unzip -l dist/reverb.apk | grep -cE 'whisper-model.bin|libreverb_asr.so'
```

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
**同意门本身不分渠道**,两个渠道都会出——这一点曾在文档里写错,
而它的直接后果是同意页正文必须把**自分发版独有的麦克风权限**如实说明。

同意状态**存的是「已同意的政策版本号」而不是布尔**:政策有实质性变更时把版本号 +1,
所有用户会再看一次。

---

## 八、逐字稿:三端同形状、取字方式完全不同

> 完整取舍见 `TRANSCRIPT.md`,这里只讲架构位置与两个跨端的关键设计。

```
TranscriptStore   状态机 + 缓存(三端同一 JSON 格式,带 version)
  ├── 官方稿      RSS 的 podcast:transcript,支持 SRT / WebVTT / Podcast Index JSON
  └── 本机转写    macOS: SpeechAnalyzer | Android 自分发: whisper.cpp | 鸿蒙: 关闭
TranscriptLines   断行与时间插值(所有来源共用同一份实现)
TranscriptPane    第三页:跟读高亮 + 自动滚动 + 点句跳转
```

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
Android 在 C++ 侧 `tidyWords` 做,共享的 `TranscriptLines.monotonic` 再兜一层
(尤其覆盖发布方给的稿——别人生成的文件不能假定排好序)。

> **鸿蒙的渲染侧不真的做整表回溯**(2026-10-06 起):逐字稿页每一行问的是
> 「本行起点已过 **且** 下一行起点还没到」,与"从后往前找到的那个下标 == 本行"在单调前提下
> **逐行等价**(主机端 fuzz 过 1,000,000 组 (稿子, 时刻) 组合、0 处不一致)。原因不是性能偏好,
> 是语言限制:ArkUI 的 `@Builder` 里**不能声明局部变量**,拿不到 Android 那个
> "顶层算一次下标再往下传"的形状,而存成字段就要管失效。**整表回溯仍然在,只是留给
> `autoScroll` —— 它要的是下标本身。上面那条不变式依赖一字未变**(见 H137)。

---

## 九、两个 native 模块,以及为什么必须有

### Android:`reverb_asr.cpp`(JNI ↔ whisper.cpp)

只做三件事:读模型、对一段 16k 单声道 float PCM 跑识别、把结果读出去。
不做解码(在 Kotlin 侧 `PcmDecoder`)、不做分块(在 `WhisperEngine`)——
**这一层越薄越好,C++ 每多一行,崩溃就多一处没有栈可看的地方。**

两个真机教出来的点:

- **`NewStringUTF` 会因非法 Modified UTF-8 直接 abort 整个进程**。
  whisper 是字节级 BPE,**一个汉字可能被劈在两个 token 里**,半个字符交给 JNI 就崩。
  所以拼接与 UTF-8 校验全在 C++ 侧做完,交出去的每条都已验证。
- **库的日志必须接出来**。whisper 默认写 stderr,在 Android 上等于扔掉;
  接到 logcat 之后,"参数被静默降级"这类问题才看得见。

### HarmonyOS:`reverb_pcm.cpp`(NAPI ↔ 系统编解码)

**ArkTS 层完全没有解封装/解码 API**(`AVPlayer` 拿不到 PCM,`AVTranscoder` 只能输出 AAC),
而系统语音识别只吃裸 PCM——所以这一层不可省。

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

---

## 十一、构建与产物

| | 命令 | 产物 |
|---|---|---|
| Android | `android/build-release.sh [--store]` | `dist/reverb.apk`(约 64 MB,含模型)/ `dist/reverb-store.apk`(约 3.9 MB)+ mapping |
| HarmonyOS | `harmony/build-release.sh` | `dist/reverb.app`(约 952 KB)+ 符号包 |
| macOS | `macos/package.sh` | dmg |

几条刻意的构建约定:

- **大产物不入版本管理**:whisper 的 `.so`(1.6 MB)与模型(57 MB)由
  `android/tools/build-asr.sh` 一条命令重建(固定 whisper.cpp commit + 校验模型 sha256);
  `build-release.sh` 在引擎启用时检查它们在不在,缺了直接报错退出。
- **打包脚本自带校验**:校验产物的 applicationId 与渠道一致(两个渠道的包长得一模一样,
  搞错会传错包)、校验签名不含 debug key。
- **鸿蒙默认清构建缓存**:hvigor 的资源编译任务会命中缓存——换过图标/字符串后照常
  `BUILD SUCCESSFUL`,但包里仍是旧资源(H39)。发布包一年打不了几次,宁可多等 10 秒。
- **开发期工具与产物分开**:比如 `android/tools/asr-probe/`(主机端探针,把每个 token 的
  时刻打出来)只用于开发,不进任何 APK。

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
