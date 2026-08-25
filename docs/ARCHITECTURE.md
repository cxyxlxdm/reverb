# 余音 · Reverb 核心技术实现

> 三端(Android / macOS / HarmonyOS)的架构与关键实现,以及**为什么这样选**。
>
> 范围划分:功能全貌见 `PRODUCT.md` / `FEATURES.md`;逐字稿单独成篇见 `TRANSCRIPT.md`;
> 具体故障的现象-根因-修法见 `TROUBLESHOOTING.md`(67 条);做的顺序与返工见 `HISTORY.md`。
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
   连带好处是版权干净、成本为零;连带代价是「跨设备一致」只能靠备份文件解决(见第五节)。
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
- **睡眠定时最后 8 秒线性渐弱**,不是硬停。
- **开播淡入约 0.9 秒**,避免炸耳。
- **上一集/下一集由「队列上下文」决定**:用户队列优先,其次是进入播放时所在的列表顺序。

---

## 四、取源与解析

**取源策略是多层兜底**(仅自分发版有目录相关的层):
Apple iTunes Search / Charts → fyyd.de → gpodder.net → RSS 直连。
一处不通自动换下一处,最终一律回到发布方自己的 RSS。

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
downloads.json      stamps.json      listen_stats.json feed_cache.json
popular_cache.json  transcripts/<单集>.<语言>.json
```

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

---

## 六、渠道隔离:三种工具链,三种做法

这是整个项目最需要架构层面处理的合规问题。目标:大陆商店渠道**包里真的没有**
内容目录相关的代码与数据,可解包验证。

### Android:flavor + source set + R8

```
app/src/main/     共享代码
app/src/default/  自分发渠道:AsrFactory(返回 WhisperEngine)、jniLibs/*.so、assets/模型、
                  AndroidManifest 里的 RECORD_AUDIO、privacy_consent_* 的完整版文案
app/src/store/   商店渠道:AsrFactory(返回 null)、对应文案为空串或渠道正确的版本
```

两种机制配合:

- **编译期常量 + R8**:`BuildConfig.CATALOG` / `AsrFactory.HAS_ENGINE` 是 `const`,
  R8 折叠之后整套目录代码与字符串一并被删除;
- **source set**:R8 **删不掉 `.so` 与 assets**,native 库与模型是构建系统按 source set
  打进包的——所以商店渠道必须靠"那个 source set 里压根没有这些文件"来保证。

### HarmonyOS:必须把代码移出编译树

**ArkTS 没有 DCE。** `Features.CATALOG ? A : B` 的两支都会进包,
release hap 里照样能 grep 到 iTunes/fyyd/gpodder 的类名与 URL。
最终把那四路取源**整体移出编译树**(挪到 `harmony/shelved/`,留 `TODO(catalog)` 标记)。

> 这是一条不能类推的经验:**"编译期开关能删代码"取决于工具链有没有 DCE。**
> 同样的写法在 Kotlin/R8 下成立,在 ArkTS 下不成立。

### 验收方式写死在流程里

```bash
# 商店渠道:必须全为 0
unzip -l dist/reverb-store.apk | grep -icE 'lib/|whisper-model'
LC_ALL=C cat classes*.dex | grep -ac 'itunes.apple.com\|fyyd\|gpodder'
aapt2 dump permissions dist/reverb-store.apk | grep -c RECORD_AUDIO
# 自分发渠道:必须都有
unzip -l dist/reverb.apk | grep -cE 'whisper-model.bin|libreverb_asr.so'
```

**中文字符串要用 `LC_ALL=C grep -a` 对原始字节搜**——`resources.arsc` / `resources.index`
里的中文不是 ASCII,`strings` 看不见,曾因此差点得出错误结论。

---

## 七、隐私门控:同意之前一个组件都不装配

被有分发平台以「同意隐私政策前获取 SSID」判定不通过过一次。根因不在自己的代码:
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

- **没有跨设备实时同步**。零后端的直接代价,只能靠备份文件换机。
- **一堆小 JSON 不适合大数据量**。订阅上千、历史上万条时需要换成数据库。
- **鸿蒙端 11.8k 行里有一部分是"补偿代码"**——ArkTS 缺解码 API 要写 native、
  系统图标不够要写映射表。这部分不产生功能,只为对齐。
- **本机语音转写的成本是真实的**:自分发 Android 版 1 小时单集约 6.5 分钟满载计算;
  鸿蒙因系统能力不足暂时没有(见 `TRANSCRIPT.md`)。
- **macOS 没有后台更新检查**,靠手动刷新;也没有真实频谱(平台无等价能力)。
