# 逐字稿 / 语音转文字:三端实现与取舍

播放页横滑第三页显示这一集的文字,跟着播放进度高亮,点一句跳到那一刻;每单集 × 每语言
一份 JSON 缓存,命中即秒显。三端**功能形状一致、取字方式各不相同** —— 因为三端可用的系统能力不同。

本文档记的是**为什么这样分工**,以及**将来要改的时候从哪儿下手**。踩过的具体坑在
`TROUBLESHOOTING.md`(H46 / H54 / H55 / H56 / H57),不在这里重复。

---

## 一、两条取字的路

| | 来源 | 时间轴 | 代价 |
| --- | --- | --- | --- |
| **官方逐字稿** | RSS 的 `podcast:transcript`(Podcasting 2.0) | 发布方给的,准 | 一次 HTTP,一两秒 |
| **本机识别** | 设备上跑语音模型 | 模型给的,句级 | 满载算几分钟,耗电发热 |

**顺序永远是先官方稿、后本机识别。** 官方稿又准又快又不耗电,没有理由不优先。

一个必须知道的现实:**中文播客基本没有官方稿**。演示数据里 15 个中文 feed 逐一 grep,
`podcast:transcript` **0 命中**(英文播客有一些,尤其 Buzzsprout / Transistor 这类托管商会自动生成)。
所以对中文用户,真正管用的是本机识别。

---

## 二、三端分别怎么做

### macOS —— 系统框架,最省事

`Data/Transcriber.swift` 用 macOS 26 的 `SpeechAnalyzer` / `SpeechTranscriber`:

- 完全设备端,音频不出机器;语言模型由系统按需下载一次,之后离线;
- **有词级时间戳**(`audioTimeRange`)⇒ 能做逐词卡拉OK,是三端里唯一能做到的;
- 还给未定稿的实时尾巴(`volatileResults`),打字机效果;
- 门控 `@available(macOS 26, *)`,旧系统显示"需要 macOS 26";
- 缓存**带版本号**(`TranscriptFormat.version`,当前 3;Android / 鸿蒙是 4 —— 换引擎与
  分段尺子各升了一次。各自只在本机比对,不要求同号。旧文件没这个键 ⇒ 缺省按 v1 判、
  整份作废重转),以及词级时刻在**入库那一步**
  就夹成「≥0 且起点单调不减」(`TranscriptFormat.monotonic`,读缓存时再整体收敛一次)——
  渲染侧找当前句用的是 `lastIndex { $0.startMs <= now }`,**只在单调时才正确**(硬规矩 10)。
  这两条是 2026-10-06 才补齐的(此前桌面端两处都缺,见 `ROADMAP.md` 三-A2)

**macOS 这一端不做功能删减** —— 自分发桌面端,不受应用市场的合规口径约束。

> **macOS 也走同一条顺序**(2026-11-13 核正):下面这段警告描述的是 1.0.6 之前的状态,
> `88b4ec7 macOS M10`(2026-10-25)已补上整块功能 —— `Episode.transcriptUrl` / `transcriptType` 进模型,
> `RssParser` 认 `podcast:transcript`,`TranscriptStore.runAny` 先取官方稿、取不到才回退本机识别,
> 三种格式(Podcast Index JSON / WebVTT / SRT)与手机两端同一套规则。运行侧读数见 `ROADMAP.md` 三-A2 ⑧
> (1.0.6 真机进程里用本地 `http.server` 喂合成 feed,有稿集 4 句渲染、关掉语音转文字后仍取得到);
> 解析器单测 2026-11-13 补齐(`macos/Tests/ReverbTests/TranscriptFetcherTests.swift`,12 条)。
>
> ~~**上面第一节那条「顺序永远是先官方稿、后本机识别」在 macOS 这一端不成立**:
> 桌面端没有 `TranscriptFetcher` 的对应物,`Episode` 模型里连 `transcriptUrl` 字段都没有
> (`Data/Models.swift`,全仓 grep 零命中),所以发布方给了现成稿的英文集也要在 macOS 26 上
> 跑几分钟本机识别~~(历史记录,当时确实如此;留在这里是为了对上以前的文档引用)。

### Android —— 一份包,一条备用降级闸

| | `reverb.apk`(唯一那份) |
| --- | --- |
| 官方逐字稿 | 有 |
| 本机识别 | **sherpa-onnx + 内置 SenseVoiceSmall int8**(两个分发处都有) |
| 支持语言 | 中文 / 英语 / 日语 / 韩语 / 粤语;**法语、西语没有** |
| 播放页第三页 | 有稿或引擎支持当前界面语言时出现(跟设置开关) |
| APK 体积 | 270,119,993 B(1.0.8 release;模型本体 239,233,841 B) |

> **1.0.8 换了引擎**:whisper.cpp base 已整体移除,换成 sherpa-onnx + SenseVoiceSmall。
> 选择理由、体积核算与真机读数在 `docs/research/2026-11-11-offline-asr-engine.md`;
> 本节只写**现在的形状**与改的时候从哪儿下手。旧 whisper 版的实现细节(30/60/120 秒 ramp、
> DTW 与 `token_timestamps` 的对照、提示词压繁体)已经作废,历史留在 `HISTORY.md` 与
> `TROUBLESHOOTING.md`(H59 / H60 / H62),**不要按那些参数改今天的代码**。

**为什么 Android 不用系统 ASR**:因为不能依赖。实测一台 Android 16 的 OnePlus(装了 Google 应用):

```
pm query-services -a android.speech.RecognitionService   → No services found
settings get secure voice_recognition_service             → null
```

国内无 GMS 的 ROM 更不用指望。所以要么自带引擎,要么这个功能在大多数机器上不存在。

**2026-10-18 之前的写法是「两个渠道两种做法」** —— 商店渠道靠 `app/src/store/` 那套 source set
把引擎、模型、`.so` 与 `RECORD_AUDIO` 全部隔掉,判据是解包 grep 各归 0。合并 flavor 后这层隔离
**没有了**,同一份包含本机识别,交去大陆商店的也是这一份(H205)。当时那句用户拍板
「商店渠道没稿就不出第三页」随之失效:第三页现在始终可用。

**降级要动的是文件,不只是常量**。引擎侧现在的物理形状:

```
app/src/main/ …/asr/AsrEngine.kt          接口
app/src/main/ …/asr/PcmDecoder.kt         解码 + 26 s 分块(纯 Kotlin)
app/src/main/ …/asr/AsrFactory.kt         返回 SenseVoiceEngine,HAS_ENGINE = true
app/src/main/ …/asr/SenseVoiceEngine.kt   引擎实现(sherpa-onnx Kotlin API)
app/libs/sherpa-onnx.jar                  AAR 里的 classes.jar(245 045 B)        ← 不入库
app/src/main/jniLibs/arm64-v8a/           libonnxruntime.so(22 249 560 B)        ← 不入库
                                          libsherpa-onnx-jni.so(4 609 320 B)      ← 不入库
app/src/main/assets/sensevoice/           model.int8.onnx(239 233 841 B)          ← 不入库
                                          tokens.txt(315 894 B)                   ← 不入库
```

`AsrFactory.HAS_ENGINE` 仍是 `const val`,R8 会折叠引用它的代码分支 —— 但**它不改变打进包的文件**。
所以把 `HAS_ENGINE` 降到 `false` 只删得掉调用路径,那 228 MB 模型与两份 `.so` 还在包里
(硬规矩 3)。真要做到「包里没有」,只能把这些文件从 `src/main` 移出构建树
(像鸿蒙那样放进 `shelved/`),同时把 `RECORD_AUDIO` 从清单摘掉。
此外**`RECORD_AUDIO` 只属于真实频谱**(`BuildConfig.SPECTRUM`),与本机识别无关 ——
识别读的是本地音频文件,不碰麦克风。

**验收方式仍是解包 grep,不是点界面**(H46 / H54)。1.0.8 release 包的实测结果
(2026-11-11,**章节那一批重打后**的包,`unzip -l` 共 179 条):

```
lib/arm64-v8a/libonnxruntime.so / libsherpa-onnx-jni.so 在
assets/sensevoice/model.int8.onnx / tokens.txt 在
dex 里 com/k2fsa/sherpa/onnx 有命中(R8 keep 生效)
assets / lib 侧 whisper / whisper-model 0 命中(旧引擎的模型与 .so 都不在)
dex 里仍有 sherpa-onnx AAR 自带的 OfflineWhisperModelConfig 等类名 —— 那是上游包装类,
我们自己的 whisper 代码为 0;`-keep com.k2fsa.sherpa.onnx.**` 会连它们一起留下
=> 这份包**具备**本机识别,两个分发处装到的都是它
```

**产物不入版本管理**:jar / 两份 `.so` / 模型 / 词表由 `android/tools/build-asr.sh` 一条命令
备齐(下载 sherpa-onnx 2.0.1 AAR 与 hf-mirror 上的 SenseVoice int8 模型)。
`build-release.sh` 在引擎启用时会检查这五样在不在,缺了报错退出 —— 合并 flavor 后只有一份包、
`HAS_ENGINE` 恒为 `true`,所以**这台机器上要出 Android 包就得先跑 `build-asr.sh`**。

**几个实现上的关键决定**:

- **分块识别,不整段解码**。1 小时音频的 16k float 是 **230 MB**,手机上不可接受。
  分块之后峰值只有几 MB,顺带让界面能边转边出。块边界**往静音处挪**
  (前后 3 秒内找能量最低点)—— 切在词中间会让那个词两边都错;
- **块长固定 26 秒**(`PcmDecoder.CHUNK_SEC_RAMP = [26]`),不是 whisper 时代的
  30 → 60 → 120。原因是模型换了:SenseVoice 是**定长 30 秒窗、非自回归**,
  喂更长不会多转出字;26 + 静音搜索 3 秒 = 最晚 29 秒,仍在窗内。
  **不要再按"块越大上下文越完整"去放大** —— 那条只对 whisper 成立;
- **逐字时刻是模型自带的**,`OfflineRecognizerResult.timestamps` 给每个 token 的块内起点,
  终点取下一条起点、最后一条取块尾。**没有 DTW,也没有额外计算** ——
  「逐字高亮」只决定缓存里存不存 `words`,`wordTimestamps=false` 时仍是同一套 token 切行,
  只是不写词表;
- **组行与官方稿共用 `TranscriptLines.mergeWords`**。SenseVoice 的 token 就是汉字 /
  英文子词,按 token 时刻切出来的行边界比按字数插值准;官方稿那条路走同一个 util;
- **时间轴的不变式在数据出口处保证,不在渲染侧兜底**。渲染判断"读到哪个词/哪句"用的是
  `indexOfLast { it.startMs <= nowMs }`,这个写法**只在起点单调不减时才正确**:
  队尾混进一个异常小的值,它就永远满足条件,高亮**钉死在那一条再也不动**。
  `SenseVoiceEngine.wordsFrom` 用"下一条起点"天然单调,`TranscriptLines.mergeWords`
  再收敛一次(硬规矩 10);
- **只出 arm64-v8a**。armeabi-v7a 的机器跑不动这个模型,给了也是让人干等;
- **不新增前台服务、不新增权限**。转写沿用播放已有的 mediaPlayback 前台服务保命 ——
  在放音时切后台照常跑;停止播放又切后台则可能被回收,界面上如实说明,不假装能后台跑完;
- **模型输出仍要过一道清洗**(真实数据里撞出来的):
  1. 连续相同句丢掉 —— 片头音乐处会复读;
  2. 括号类标记整句丢掉 —— 片尾静音处会**幻觉**出 `(字幕:J Chong)` 这种字幕组署名;
  3. **繁体界面输出简体**。这条与 whisper 时代相反:whisper 靠提示词压简体/繁体,
     SenseVoice 没有提示词,输出固定简体。繁体界面下本机转写是简体字,
     **官方稿不受影响**。已知限制,不是 bug;
  4. **一次前向带标点**(`useInverseTextNormalization = true`),不需要再按提示词切句;
     仍按 token 时刻组行,保证跟读粒度。
- **「跟随系统」不能原样传给引擎**。要解析成真实语言(`zh-CN` / `en-US` …):
  传空串等于让引擎自己猜;而且缓存 key 会退化成 `auto`,换了系统语言还命中同一份旧稿。
- **语言闸门在入口处**:`AsrFactory.supports(locale)` 为 false 时(法语、西语),
  播放页第三页只显示"本机识别不支持这种语言,且这一集没有官方稿",**不摆生成按钮**。
  这条状态是 `TranscriptStore.State.UnsupportedLocale`,与"包里没有引擎"(`NoEngine`)分开。
- **缓存带版本号**:`TranscriptStore.CACHE_VERSION = 7`(3 是换引擎,4 是分段尺子 18/38,
  5~7 是第二轮的三种残余形状 —— 先判后加 / 整条上限收到一行 / `fitOneLine`,见第五节)。
  换了引擎,文本、标点、断行与时刻**全部不同**,v2 旧稿一律作废重转 —— 否则"换了更准的引擎等于没换"(硬规矩 11)。

### HarmonyOS —— 官方稿 + 系统 ASR(**1.0.8 已弃用,留作历史**)

> ⚠️ **下面这一节描述的是 1.0.7 及以前的做法,1.0.8 已整体换成 sherpa-onnx + SenseVoice
> (见第三节)。留着是为了记住"系统能力形状对得上、适用场景对不上"这条教训,
> **不要按这里的窗长与参数复活 `SpeechTranscriber`**;它的代码仍在
> `playback/SpeechTranscriber.ets`(仍在编译树里),但 `AppContainer` 不再装配它,只作对照。

1.0.7 的两条路与 Android 同一形状:发布方给了稿就用稿,没有就用**系统的离线语音识别**
(Core Speech Kit,`@hms.ai.speechRecognizer`)。它与 macOS 的 Speech 框架同一性质
(系统能力,不是三方 SDK),因此**不影响"不接三方 SDK"的对外表述**,也几乎不涨包体积
(整包 952 KB,其中 native 解码模块 56 KB)。

落点:

| 文件 | 作用 |
| --- | --- |
| `store/TranscriptStore.ets` | 状态机 + 缓存(格式与另两端完全一致,含 `version` 字段) |
| `net/TranscriptFetcher.ets` | 官方稿:SRT / WebVTT / Podcast Index JSON |
| `util/TranscriptLines.ets` | 断行与时间插值(Android `TranscriptLines.kt` 的逐条移植) |
| `playback/SpeechTranscriber.ets` | 系统 ASR:分窗、喂帧、推时间轴 |
| `playback/PcmReader.ets` + `cpp/reverb_pcm.cpp` | 解码成 16k 单声道 PCM(**必须 native**) |
| `view/TranscriptPane.ets` | 第三页:跟读高亮 + 自动滚动 + 点句跳转 |

**三个限制,和对应的做法**:

1. **结果里没有任何时间戳**。`SpeechRecognitionResult` 只有 `{isFinal, isLast, result}`。
   做法:把音频切成 **20 秒的窗**,一窗一个识别会话 —— 窗的起止时刻是我们自己算的
   (喂了多少 PCM ⇒ 多少毫秒,精确),窗内的几句话再按**字数占比**插值。
   于是误差被压在窗内的语速波动上,一两秒量级。

   **为什么不用"某句 isFinal 时已喂入多少字节"来定位**(那是本文档早先设想的做法):
   识别是流式的,结果比音频滞后且滞后量不固定;而我们是尽可能快地喂、不是按实时速度喂,
   那样所有结果都会挤在末尾到达,位置信息等于零。窗 + 字数插值不依赖回调时机,是唯一稳的做法。

2. **没有词级时间 ⇒ 本机识别的稿只能整句高亮**。设置里的「逐字高亮」在本端只对
   **发布方的 JSON 逐字稿**有效(那种稿一词一条),副标题已如实说明。
   数据结构里 `words` 允许为空正是为此,三端共用同一份缓存格式。

3. **ArkTS 层没有解封装/解码 API**。`@ohos.multimedia.*` 里没有 demuxer(grep 零命中),
   AVPlayer 拿不到 PCM,AVTranscoder 只能输出 AAC。所以 m4a/mp3 → 16k PCM **只能走 Native**:
   `native_avsource.h` + `native_avdemuxer.h` + `native_avcodec_audiocodec.h`。

   好消息是不必写回调式代码:**API 20 起有同步接口**(`OH_AudioCodec_QueryInputBuffer` /
   `QueryOutputBuffer` / `GetInputBuffer` / `GetOutputBuffer`),**不注册回调即为同步模式**,
   于是整条链是一个普通循环 —— 没有回调线程、没有条件变量。音频解码这种地方每多一个线程
   就多一处没有栈可看的崩溃。

   两个接线上的坑,都撞过:`napi_module` 在 `napi/native_api.h` 里(不在 `js_native_api.h`);
   hilog 自己先 `#define LOG_TAG NULL`,要 `#undef` 再定义。另外 .so 不能 `requireNapi`,
   必须在 `cpp/types/libreverb_pcm/` 建一个类型包、在 `entry/oh-package.json5` 里
   `file:` 依赖它,然后 `import pcm from 'libreverb_pcm.so'`,并且**要跑一次 `ohpm install`**
   才会在 `oh_modules` 里建好软链 —— 没跑之前类型解析成 `any`,报 `arkts-no-any-unknown`。

另外 `@hms.ai.AICaption` 名字最像但**不能用**:它是黑盒 UI 组件,`writeAudio` 进去、
系统自己把字幕画在面板上,**拿不到文本** —— 没法缓存、没法做我们自己的跟读页、没法导出。
只能当"播放时叠一层实时字幕"的另一种玩法。

**真机实测结论(BRA-AL00 / HarmonyOS 6.1.0.135 / API 24):接线全部跑通,但识别质量不够用。**

接线上的四个坑与修法记在 TROUBLESHOOTING H62(同步模式要显式开、解码器要用轨道格式、
监听器只能绑一次且必须等 onStart)。修完之后**能出字、不再崩**,但:

| 档位 | 10 分钟中文单集的产出 |
| --- | --- |
| 默认(短语音)档 | **14 行**,多是「。」「能力。」「有八。」这类碎片 |
| 试传 `recognizerMode: 'long'` | **0 行**(取值口径猜错,已回退) |

原因是 Core Speech Kit 的离线档是给**短语音输入/命令词**设计的:一次会话的 VAD 检测到
句末静音就收工,只认第一句,后面的音频白喂。**接口形状对得上,适用场景对不上。**

**1.0.7 据此定型:本端只走官方逐字稿。** 由 `Features.LOCAL_ASR = false` 一处开关控制,连带三件事
(1.0.8 换引擎后这个开关已翻成 `true`,三条随之解除,见第三节):

- 播放页第三页**仅当该集有官方稿时才出现**(`LOCAL_ASR = false` ⇒ 没有可转的本机识别,不摆空页;
  Android 合并 flavor 前那家商店渠道同此规则,现在那份包有引擎、已不再适用);
- 设置里不显示「逐字稿」总开关 —— 没有可开关的本机识别,摆一个开了也不变的开关只会让人困惑;
- 「逐字高亮」**保留**:官方的 JSON 稿一词一条、自带词级时间,那个效果是真的。

系统识别的代码没有删,`LOCAL_ASR` 改回 true 即可复活,但**不要在换掉引擎之前打开它** ——
质量见上表。1.0.8 起 Android 与鸿蒙都已换成 sherpa-onnx + SenseVoiceSmall
(Android 见上一节,鸿蒙见下一节),`LOCAL_ASR` 为 `true`。

**仍待确认**:
`listLanguages` 的实际语言清单(API 5.1.0(18) 起才有,早期版本只有 zh-CN)、
离线模式单次会话的音频时长上限(代码里按 20 秒取安全值,并对 `1002200003` 做了提前收尾)、
目标机型上 HMS AI 服务是否在位(不在位时 `available()` 返回 false,界面如实显示"用不了")。

---

## 三、鸿蒙已切到 sherpa-onnx(1.0.8 已实施)

**引擎与 Android 同一套:sherpa-onnx 1.13.3(HarmonyOS har,Apache-2.0)+ SenseVoiceSmall int8**。
2026-11-11 拍板并当天落地、真机验完;选择理由与体积核算见
`docs/research/2026-11-11-offline-asr-engine.md`。不再是"whisper 还是 sherpa"的开放题。

落地形状(Native 解码链没动,换的只是"谁来识别"):

| 文件 | 作用 |
| --- | --- |
| `playback/asr/SenseVoiceTranscriber.ets` | 满足 `SpeechTranscriberLike`:取本地/下载音频 → 起 worker → 转发片段 |
| `playback/asr/AsrWorker.ets` | `ThreadWorker`:持有 `OfflineRecognizer` 与 `PcmReader`,26 秒一块解码 |
| `playback/asr/SenseVoiceText.ets` | 纯函数:语言映射、PCM 转换、token 时刻 → 词单元、重复行/标记清洗 |
| `store/TranscriptStore.ets` | 状态机与缓存格式原样复用(只补了"换集不取消"的注释;`CACHE_VERSION` 跟着换引擎升到 3、分段尺子升到 4,见下) |
| `tools/build-asr.sh` | 备齐模型与词表(sha256 校验);`.gitignore` 遮住,release 脚本前置检查 |
| `entry/src/main/resources/rawfile/sensevoice/` | 模型 239,233,841 B + 词表 315,894 B,首次使用拷到私有目录 |

**为什么识别放在 `ThreadWorker` 里**:ArkTS 没有协程,而一块 26 秒音频的推理要
1.4–2.2 秒 —— 放在主线程就是持续掉帧。worker 用 `workerPort.postMessage` 把
片段 / 结束 / 错误发回来,取消也走消息;主线程只保留代次(`TranscriptStore.generation`),
旧任务的回包按代次丢弃。引擎在 worker 里只构造一次,换语言才重建(实测 2.6 秒)。

**与 Android 逐条对齐的口径**:
- 分块 26 秒、`keep()` 的重复行/方括号标记过滤、`TranscriptLines.mergeWords(words, false)`;
- 词时间轴 = 下一个 token 的起点,最后一个 token 用块尾,块起点累加;
- 语言映射 zh / en / ja / ko / yue;**法语、西语界面返回不支持**,第三页如实说明,不摆必然失败的重试;
- 不补标点(Android 也只开 `useInverseTextNormalization`);
- 繁体界面输出仍是简体 —— SenseVoice 不认提示词,与 Android 同一条已知限制。

**真机读数(Mate 60 / HarmonyOS 7.0.0.109 / 串号 9CN0224A08003297)**:
- 未下载的集先下音频:108,296,876 B 走 `requestInStream` 流式落盘
  (内存形态在 70 MB 就失败,见 H264);
- 首次拷贝模型 228 MB(约 2 秒,之后按字节数判断直接跳过);词表 315,894 字节;
- 每 26 秒块 1.4–2.2 秒,约 12–18 倍实时;素材集 1:51:22 两次实跑 **555,758 / 547,462 ms**
  (~9 分钟),各出 **1,201 句**,`ok=true`,结束后音频缓存自动删掉;
- 落盘后冷启动再打开第三页:**秒显**,日志里 0 条「模型已加载」—— 命中缓存就不碰引擎;文件 1,547,322 B、
  `version: 3`、`complete: true`;
- 45 条单测全绿(新增 7 条覆盖语言映射 / PCM 转换 / 时间轴 / 清洗)。

**缓存版本必须 +1(1.0.8,硬规矩 11)**:`TranscriptStore.CACHE_VERSION` 由 2 升到 3。
v2 是 Core Speech Kit 时代写下的 —— 只有文本、时间轴靠"已经喂进去多少音频"按字数插值,
而 SenseVoice 给的是**词级真实时刻**,两种口径混在一份稿里会出现前半段一套算法、后半段另一套;
再加上旧稿的语言集合也不同(那时候法语、西语也能出稿)。所以读到 `version < 3` 的稿**直接删掉重转**
(子线程与主线程两条读路径都删,与 Android 同一判据)。
真机判据:换包后打开素材集,第三页停在「生成逐字稿」而不是秒显旧稿,
设备上那份 1,547,322 B 的 v2 缓存文件当场消失。

再升到 **4**(2026-11-13,分段尺子 24/42 → 18/38,见第五节):缓存里存的是**已经切好的句子**,
尺子变了旧稿不会自己重切,界面上照旧是"一行铺满 + 一个字" —— 换了尺子等于没换。
三端这一轮都升(Android 3→4、鸿蒙 3→4、macOS/iOS 2→3),与引擎那次不同:那次桌面端没换引擎所以不升,
**这次改的是三端共用的分段口径**。真机判据同上:换包后第三页回到「生成逐字稿」,原来那份 v3 缓存消失。

**已知边界(1.0.8 有意接受)**:
- 换播放中的单集**不会**取消在途转写 —— 与 Android 同一条有意行为:转写是用户点过的一次
  请求,关掉播放页/切去听别的正是"后台跑完、下次秒显"。逐字稿页切到另一集才取消(`prepare`);
- 繁体界面简体输出(见上);
- 锁屏后台不保证 worker 继续(系统可能冻结进程)。转写不是播放,这一条不在 1.0.8 验收范围。

**将来要"某版本不带引擎"怎么做**:鸿蒙**没有 DCE**(H54),把 `Features.LOCAL_ASR` 改成
false 只停调用路径,模型与 `.so` 照样进包。真要做到"包里没有",必须把
`rawfile/sensevoice/` 与 har 依赖移出构建树(见 `harmony/shelved/` 的做法)。

### 隐私文本(已随 1.0.8 改)

隐私同意正文不再用「不接入任何第三方 SDK」这句会被理解为"包里没有任何外部代码"的话,
而是直接说清"内置开源组件 sherpa-onnx 与随包的 SenseVoiceSmall 模型,全程在本机完成,
音频不上传、不出设备",并列出支持的语言。**五语都已同步,鸿蒙这套也写了同样的组件名与许可证**
(与 Android 逐字对齐)。官网隐私政策页与 `docs/PRIVACY.md` 已同步。

---

## 四、稿子拿到之后:搜索与导出(1.0.8,三端)

两件事都**不改变取字链路**,只在已有的 `segments` 上做 —— 所以三端可以共用同一套判据,
也最容易被"各写一套"悄悄弄歪。三端的实现按端一个文件,但**输出与语义要约好**:

**搜索(`TranscriptSearch`)**:返回的是**命中的句子**,不是命中的次数;
每句里再给若干**区间**用于贴底色,区间用**字符下标**而不是 UTF-16 偏移 —— 渲染侧按
Character 切片,含 emoji 的句子拿 UTF-16 下标去切会错位。大小写折叠交给系统 API
(Apple 用 `NSString` 的 `.caseInsensitive`、Android 用 `indexOf(…, ignoreCase)`、
鸿蒙用 `toLocaleLowerCase`),不自己 `lowercased()` 再回原文取下标:某些语言的折叠会改变长度
(土耳其语 İ 一类),折叠后的下标切原文必然错位。**区间一次算完**,渲染侧每行查表;
当前句的逐字高亮每帧重建,那一步里再扫稿就是硬规矩 6 的正犯。

**导航**:上一处 / 下一处**循环**,并在跳的同时 `seek` 到该句起点 —— 这是"搜索"在播客里
与在文档里最大的不同:用户找一句话,通常是想**从那里开始听**。
搜索态下**暂停跟读自动滚动**:否则播放驱动的高频排版会把用户滚动到的位置拽回去
(与硬规矩 9 同一件事,别用 `isScrollInProgress` 去猜谁在滚)。

**导出(`TranscriptExport`)**:两种格式,**三端逐字节一致** —— 同一个用户在两台设备上导同一集,
拿到的文件应该能互相 diff,而不是两种排版。纯文本是「集名 / 频道名 / 空行 / `[M:SS] 内容`」,
Markdown 是「`# 集名` / `_频道_` / `- [M:SS] 内容`」。时间戳位数按**整篇时长**统一:
一小时以内 `12:03`,超过才写 `1:12:03` —— 逐句各判一次会让同一份文件里两种形状混排。
文件写进缓存目录后走系统分享,分享标题与「另存为」默认名都是**集名**
(鸿蒙这里踩过一次:传了按钮文案,见 H263)。

单测落点(三端同一批判据):搜索的大小写 / 多命中 / 空查询 / emoji 下标 / 循环导航;
导出的两种格式 / 时间戳位数分界 / 空标题与空频道 / 逐字节快照。
本轮验收:Android 与鸿蒙各在真机上跑过一组
(搜索、循环跳、无匹配、两格式导出并核对字节、分享标题);macOS / iOS 只到单测与编译门,
**界面没有实跑**(运行验收固定在另一台机器 / 本轮未做)。

---

## 五、分段尺子:一条必须画得进一行(2026-11-13 重定)

三端共用一把尺子:`CJK_CHARS = 18` / `WEST_CHARS = 38`(`TranscriptLines` 三份实现里的同名常量)。
它同时管三件事 —— `mergeWords` 攒够就 flush、`split` 把长 cue 切开、`glueOrphans` 允许并回多少字。
所以**改它等于改三端的断行结果**,三端的缓存版本要一起升(见第三节末)。
2026-11-13 这一轮连升两版:Android / 鸿蒙 **7**、macOS / iOS **6**(各端只在自己口径变了时 +1,
编号不要求同号 —— 缓存只在本机读,理由见 `TranscriptFormat` 头注)。

**旧值是 24 / 42,而且从没在真机上量过**,注释只写"按手机屏宽估的"。症状是用户看到的那句:
**一行铺满、下一行就一个字**。原因是 24 这个数字恰好比真实容量多一点点:

| 端 | 正文宽度 | 字号 | 一行放得下 |
| --- | --- | --- | --- |
| Mate 60(374.2 vp,左右各 24 ⇒ 326 vp) | 326 vp | 14 vp(旧) | **23 个汉字** |
| Mate 60(本轮把字号对齐到 16 vp) | 326 vp | 16 vp | 20 个汉字 |
| Android(Pixel 3,`bodyLarge` 16sp + 0.5sp 字距、正文 344 dp) | 344 dp | 16 sp | 20 个汉字 |

`mergeWords` 的 flush 条件是 `len >= target`,于是 SenseVoice 那 1,201 句里 **946 句恰好 24 字**
(其余 5–23 字)—— 每句都多出 1 个字落到第二行,断点还落在词中间。

**为什么不用"运行时量出宽度再切"**:同一集在两端必须是同样多行(H150 的跨端对齐判据),
按每台机器的实际排版宽度算,换台设备行数就变。固定尺子取的是"最窄那台机器也放得下":
18 对应 360 dp 小屏(正文 312 dp ÷ 每字 16.5 dp ⇒ 18 个)。**目标字数要比最窄容量再小两格**,
等于容量就是"每次刚好溢出"。系统字号放大到 1.1 倍以上仍可能挤出一两个字 —— 已知边界。

**并句也必须有一行上限**。`glueOrphans` 原先只看"碎片本身不足 12 字",没有上限:
18 字的行并一个 11 字的尾巴就是 29 字,换行后第二行只剩一两个字 —— 与用户报的是同一个形状。
现在判据按**合并之后**的整行算:`merged.length <= targetChars(merged) + GLUE_OVERHANG`,其中
`GLUE_OVERHANG = 2`;超了就让它自己成行(一条 5–17 字的短句读着正常,挤出来的孤字不正常)。
**上限不能按上一行自己算** —— 上一行常是「4分之1。」这种五六个字的短条,单看它会被判成西文 38 字,
上限变成 40,21 字的长行就是这么并出来的(2026-11-13 抓到的第二种形状,见 H281)。

**行宽按"这一行开头一小段"锁,不按首条;`split` 不许越一行**。这两条与上面那条是同一轮补的:

- `mergeWords` 原在 `buf` 为空时用 `targetChars(首条)` 定行宽。首条是「4分之1。」时只有 2 个汉字、
  5 个字符 ⇒ 判成西文 38,后面接上汉字就把同一行撑到 25 字。现在用 `headWindow` 攒够
  `CJK_CHARS` 个字符再判;**逐条重判也不行** —— 中文句里夹一个英文词会让行宽一会儿 18 一会儿 38。
- `targetChars` 补了第二条判据:**有汉字且按字宽折算**(`cjk * 2 + 其余`)超过一行西文容量,
  也按中文行宽走。只看"汉字是否过半"会漏掉「元今年 open a i 一度在部分收入指标上落后于
  anropic 彭」这种 47% 的混排。`cjk > 0` 这个前提不能省:否则 40 个字符的英文 cue 会被折算成
  "宽",又按 18 字硬切。
- `mergeWords` 的 flush 改成**先判后加**(`len + 下一条 + 可能的前导空格 > target` 就先断)——
  旧写法"加完再判",而一个条目可能是 2~3 个字,每行实际能到 `target + 3`。
- `split` 的提前返回收到"放得进一行",切分窗口就是一行 —— 旧版放宽到 1.5 倍行宽,27 字的 cue 会
  整条进稿。行宽这把尺子的用途就是"每一条都画得进一行",宁可硬切。
- **最后一道闸 `fitOneLine`:flush 完按整行重判一次**。前面两道都只能拿到"一行开头"的信息 ——
  引擎一次吐出整句、或一行开头是一长串英文时,`headWindow` 那 18 个字符会被英文占满,
  整行汉字占多数的稿也会被判成西文 38 字。2026-11-13 鸿蒙装机实测:
  「亿美元今年 open a i 一度在部分收入指标上落后于 anropic 彭」整条 38 字,上屏折两行、
  第二行只有 6 个字。现在每一行超过"它自己的行宽 + `GLUE_OVERHANG`"就切开;切出来的碎片
  不带词级时间 —— 那一行退化为行级高亮,好过折出第二行。

**鸿蒙的字号这一轮也对齐了**:逐字稿正文原先用 `TypeScale.body`(14),而 Android / iOS 都是 16 号,
于是同一把尺子在本端一行少放好几个字。现在三端都是 16(鸿蒙 `bodyLarge`,行高 24 ⇒ 1.5 倍)。

**单测(三端同一批判据)**:尺子是 18/38;24 个单字词切出来每条都 ≤ 20 字(18 + 溢出 2);
18 字行 + 11 字尾巴仍保持两条(不许并成 29 字);超一行的整条必被切开;中英混排按字宽折算选中文行宽;
**首条是混排数字**(「4分之1。」)时行宽仍按中文。后三条是第二轮补的 —— 其中"首条混排"那条
第一版是红的(Swift 报 `("21") is greater than ("18")`),说明它抓得到这个形状。
落点:`TranscriptLinesTest.kt` / `TranscriptLines.test.ets` / `TranscriptLinesTests.swift`
(2026-11-13 第二轮补完后计数:Android 89 条、鸿蒙 54 条、Swift 81 条,0 失败)。

**真机验收(Mate 60,2026-11-13,素材集 1:29:29)**:换包后第三页回到「生成逐字稿」,
日志 `[Transcript] 缓存是旧口径,已丢弃,需重转`;重新转写 **413,000 ms 出 1,753 句**
(旧尺子同一集是 1,201 句 —— 尺子小了,句子自然多),落盘 **1,662,348 B / `version: 4` / `complete: true`。
逐条数一遍:**1,552 句恰好 18 字**,超过 20 字的只有 6 句(最长 38 —— 都是行首夹了一个
英文词、于是按西文 38 锁宽的那几条;它们会换两行,但第二行有十来个字,不再是孤字),
`join(words) == text` 与起点单调两条不变式各 0 违例。截图上每段就是一行(开头与滚动到中段各取一张);
冷启动再进第三页秒显,日志 0 条「模型已加载」。

**第二轮真机验收(2026-11-13,同一轮补完上面三条规则 + `fitOneLine` 之后)**:

- **Android(1080×2160,清缓存后重转 10:25 那集,日志 `转写结束 ok=true 已出 211 句`)**:
  逐行像素带量到**段内间距 36~37 px、段落间距 80~81 px**,每 3 行一段;
  所有行都是单行高度(40~42 px),没有折行、没有以标点起头的行。
  修之前同一集里能直接把「4分之1。 另外,面对签约运动员姆巴佩引发的争议,」这 21 字看成两行。
  (同一判据在 v6 那版上量到 34~36 / 78~79,结论不变,数值差来自正文行高与截图时进度线位置。)
- **鸿蒙 Mate 60**:缓存版本 7 让 v6 的旧稿作废(第三页回到「生成逐字稿」),重转后逐段 3 行、
  每行单行高度。缓存文件直接读数:185 句 / `version: 7` / **最长 20 字**(4 条,都是 18 字正文 +
  2 字并句余量)、18 字 146 条;被 `headWindow` 当西文锁成 38 字的那两行已拆成 14+9 与 17+18。
- **未验**:Apple 两端这一轮只跑了单测,没有真机截图 —— macOS 的运行验收固定在另一台机器。
