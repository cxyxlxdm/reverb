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
- 缓存**带版本号**(`TranscriptFormat.version = 2`,与 Android `TranscriptStore.CACHE_VERSION` /
  鸿蒙同值同义;旧文件没这个键 ⇒ 缺省按 v1 判、整份作废重转),以及词级时刻在**入库那一步**
  就夹成「≥0 且起点单调不减」(`TranscriptFormat.monotonic`,读缓存时再整体收敛一次)——
  渲染侧找当前句用的是 `lastIndex { $0.startMs <= now }`,**只在单调时才正确**(硬规矩 10)。
  这两条是 2026-10-06 才补齐的(此前桌面端两处都缺,见 `ROADMAP.md` 三-A2)

**macOS 这一端不做功能删减** —— 自分发桌面端,不受应用市场的合规口径约束。

> ⚠️ **上面第一节那条「顺序永远是先官方稿、后本机识别」在 macOS 这一端不成立**:
> 桌面端没有 `TranscriptFetcher` 的对应物,`Episode` 模型里连 `transcriptUrl` 字段都没有
> (`Data/Models.swift`,全仓 grep 零命中),所以**发布方给了现成稿的英文集也要在 macOS 26 上
> 跑几分钟本机识别**(发热耗电,而官方稿又准又快)。这是缺口不是取舍,记录与判据见
> `ROADMAP.md` 三-A2;补上之前,本节那条顺序只对 Android 与鸿蒙成立。

### Android —— 一份包,一条备用降级闸

| | `reverb.apk`(唯一那份) |
| --- | --- |
| 官方逐字稿 | 有 |
| 本机识别 | **whisper.cpp + 内置模型**(两个分发处都有) |
| 播放页第三页 | 始终可用(跟设置开关) |
| APK 体积 | 65,028,676 B(2026-10-18 那份;模型本体 59,707,625 B) |

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
app/src/main/ …/asr/AsrEngine.kt      接口
app/src/main/ …/asr/PcmDecoder.kt     解码(纯 Kotlin)
app/src/main/ …/asr/AsrFactory.kt     返回 WhisperEngine,HAS_ENGINE = true(:27)
app/src/main/ …/asr/WhisperEngine.kt  引擎实现
app/src/main/jniLibs/arm64-v8a/       libreverb_asr.so(1 679 264 B)  ← 不入库
app/src/main/assets/whisper-model.bin ggml-base-q5_1(59 707 625 B)   ← 不入库
```

`AsrFactory.HAS_ENGINE` 仍是 `const val`,R8 会折叠引用它的代码分支 —— 但**它不改变打进包的文件**。
所以把 `HAS_ENGINE` 降到 `false` 只删得掉调用路径,那 57 MB 模型与 `.so` 还在包里
(硬规矩 3)。真要做到「包里没有」,只能把这些文件从 `src/main` 移出构建树
(像鸿蒙那样放进 `shelved/`),同时把 `RECORD_AUDIO` 从清单摘掉。

**验收方式仍是解包 grep,不是点界面**(H46 / H54)。当前这份包的实测结果:

```
dex 里 whisper / reverb_asr / ggml 各有命中;lib/arm64-v8a/libreverb_asr.so 在;assets 有 57 MB 模型
=> 这份包**具备**本机识别,两个分发处装到的都是它
```

**产物不入版本管理**:`.so`(1.6 MB)与模型(57 MB)由 `android/tools/build-asr.sh` 一条命令
重建(固定 whisper.cpp commit + 校验模型 sha256)。`build-release.sh` 在引擎启用时会检查它们
在不在,缺了报错退出 —— 合并 flavor 后只有一份包、`HAS_ENGINE` 恒为 `true`,
所以**这台机器上要出 Android 包就得先跑 `build-asr.sh`**(以前那套「商店包不需要备产物」的余地没了)。

**几个实现上的关键决定**:

- **分块识别,不整段解码**。1 小时音频的 16k float 是 **230 MB**,手机上不可接受。
  最大 2 分钟一块交出,峰值约 7.7 MB,顺带让界面能边转边出。块边界**往静音处挪**
  (前后 3 秒内找能量最低点)—— 切在词中间会让那个词两边都错;
- **块长逐块放大:30 → 60 → 120 秒**。一律 120 秒的话,第一句要等整个首块算完才出现,
  真机上是二十多秒的空白 —— 用户报过"点了生成要等很久才出字"。首块缩到 30 秒,
  首字 5~6 秒就出来。**下限就是 30 秒**:whisper 内部一律按 30 秒窗处理,喂 10 秒和喂 30 秒
  的编码器开销几乎一样,再小只是浪费。之后放大回 120 秒是为质量 —— 一次 `whisper_full`
  内部的多个 30 秒窗之间带上下文,块越大跨窗上下文越完整;
- **`no_context = true`**。分块必须关掉跨块上下文,否则模型复读。代价是质量略降、
  收益是快不少;也因此**不能拿命令行的倍率对照本应用**,两者不是同一个配置;
- **词级时刻用 whisper 自带的 `token_timestamps`,不用 DTW**。这一条走过弯路,结论是量出来的
  (工具见 `android/tools/asr-probe/`,那是个主机端探针,能把每个 token 的时刻打出来):

  | | 准不准 | 快不快 |
  | --- | --- | --- |
  | DTW(`t_dtw`) | 整体**偏晚 0.4~0.9 秒**,与 `t0` 平均差 378 ms | 0.92 s/32.6 s 音频 |
  | `token_timestamps`(`t0/t1`) | 音频主体上准到 **±150 ms** | 0.67 s,**快 43%** |

  准确性用**切片法**定的真相:把音频截到 0→1.0 秒、0→1.3 秒分别识别,看第几个字还在里面。
  实测第 6 个字实际在 1.1 秒左右,DTW 说 1.96 秒,`t0` 说 1.25 秒。中段再挑三个锚点
  (9.0 / 13.69 / 21.44 秒)从该处起截 2.2 秒,识别出来的头几个字与 `t0` 完全对上。

  DTW 还有个**一格错位**:whisper.cpp 里那段 `if (v != last_v)` 把"token k+1 开口的时刻"
  写进了 token k(`tok_i` 比 `v` 慢一步),所以原样当起点用等于整体晚一格,末尾那个 token
  还永远拿不到值(留在 -1)。

  换过来之后有三个连带好处:**flash attention 可以常开**(DTW 与它不兼容,见 H59),
  于是逐字高亮**不再有额外耗时**;`token_timestamps` 是 per-call 参数,不在
  `whisper_context_params` 里,所以用户拨这个开关**不必重建 whisper 上下文**;
  也不再需要让 `dtw_aheads_preset` 跟着模型档位走(换模型少一处要同步改的地方)。

  **已知偏差**:给了 `initial_prompt`(中文简体提示词)时,每块**头 4~5 秒**的 token 时刻
  会被压缩偏早(实测第 6 个字 0.75 秒 vs 实际 1.1 秒),之后与无提示词的结果重合。
  只影响词级高亮的位置,句级时间轴不受影响,故接受 —— 提示词是简体输出的唯一保障,不能撤。

  设置项叫「逐字高亮」,合并 flavor 后**只有一份副标题**(以前 `src/default|store/res/values-*`
  各一份、说辞不同,是 H169 那类漂移的物理来源)。当前这份说明"不额外增加转写耗时",因为包里就有引擎;
  **这句和 `HAS_ENGINE` 是绑在一起的** —— 若把降级档启用(没有引擎),这个开关只影响**发布方逐字稿**
  的渲染,副标题必须跟着改成"需要发布方提供的逐字稿,没有稿的单集用不了",否则文案在说谎。

  缓存 key **不含**这个开关 —— 关着转完再打开,那份缓存里没有词级时间,只能整句高亮,
  想要就得重转。这是有意的取舍:把开关塞进 key 会让同一集存两份稿。
  但缓存**带版本号**(`TranscriptStore.CACHE_VERSION`):时刻算法一变就 +1,
  旧稿自动作废重转 —— 否则用户手机上已生成的稿会按旧时间轴继续显示,"修了等于没修";
- **时间轴的不变式在数据出口处保证,不在渲染侧兜底**。渲染判断"读到哪个词/哪句"用的是
  `indexOfLast { it.startMs <= nowMs }`,这个写法**只在起点单调不减时才正确**:
  队尾混进一个异常小的值(某个 token 没算出时刻、退化成 -1),它就永远满足条件,
  于是高亮**钉死在那一条再也不动**。所以 C++ 侧 `tidyWords` 出口保证"全部 ≥ 0、起点单调";
- **只出 arm64-v8a**。armeabi-v7a 的机器跑不动这个模型,给了也是让人干等;
- **不新增前台服务、不新增权限**。转写沿用播放已有的 mediaPlayback 前台服务保命 ——
  在放音时切后台照常跑;停止播放又切后台则可能被回收,界面上如实说明,不假装能后台跑完;
- **模型输出必须过一道清洗**,四条都是真实数据里撞出来的:
  1. 连续相同句丢掉 —— 片头音乐处会复读(实测「原来是这样」连出 6 次);
  2. 括号类标记整句丢掉 —— 片尾静音处会**幻觉**出 `(字幕:J Chong)` 这种字幕组署名;
  3. **中文要给简体提示词**。whisper 转中文默认偏向**繁体**,简体界面下出来整屏
     「原來是怎樣」「我們假設」,对简体用户就是坏的。给一句
     `以下是普通话的句子。` 即可带过去(繁体界面反过来给繁体提示);
  4. **一句还要再切**。给了带标点的提示词之后,whisper 会把一整段当成一句吐出来
     (实测 3 分钟音频只有 21 句,一句两三百字),跟读粒度就没了。切分与官方稿
     **共用同一套规则**(`util/TranscriptLines.kt`:中文一行 24 字、西文 42,
     时间按字符占比插值),切完 42 句。
- **「跟随系统」不能原样传给引擎**。要解析成真实语言(`zh-CN` / `en-US` …):
  传空串等于让引擎自己猜,而中文猜出来往往是繁体;而且缓存 key 会退化成 `auto`,
  换了系统语言还命中同一份旧稿。

### HarmonyOS —— 官方稿 + 系统 ASR(**已实施**)

两条路都做了,与 Android 同一形状:发布方给了稿就用稿,没有就用**系统的离线语音识别**
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

**已据此定型:本端只走官方逐字稿。** 由 `Features.LOCAL_ASR = false` 一处开关控制,连带三件事:

- 播放页第三页**仅当该集有官方稿时才出现**(`LOCAL_ASR = false` ⇒ 没有可转的本机识别,不摆空页;
  Android 合并 flavor 前那家商店渠道同此规则,现在那份包有引擎、已不再适用);
- 设置里不显示「逐字稿」总开关 —— 没有可开关的本机识别,摆一个开了也不变的开关只会让人困惑;
- 「逐字高亮」**保留**:官方的 JSON 稿一词一条、自带词级时间,那个效果是真的。

系统识别的代码没有删,`LOCAL_ASR` 改回 true 即可复活,但**不要在换掉引擎之前打开它** ——
质量见上表。要拿到 Android 那种质量,把 whisper.cpp 链进已经建好的 native 模块
(见下一节的迁移路径;现在成本比原先估的低 —— 模块、类型包、解码链都在位且真机验过)。

**仍待确认**:
`listLanguages` 的实际语言清单(API 5.1.0(18) 起才有,早期版本只有 zh-CN)、
离线模式单次会话的音频时长上限(代码里按 20 秒取安全值,并对 `1002200003` 做了提前收尾)、
目标机型上 HMS AI 服务是否在位(不在位时 `available()` 返回 false,界面如实显示"用不了")。

---

## 三、将来鸿蒙要切到三方引擎,怎么做

会想切的理由通常是这三条里的一条:系统 ASR 只支持中文、拿不到词级时间戳、或者要和 Android
**逐字一致**(同一集在两端转出同样的文本)。

好消息:**大部分工作已经在了**。鸿蒙的 Native 解码模块(`cpp/reverb_pcm.cpp`)已经落地并跑通
构建,换引擎只是在同一个模块里多链一个库、把 `SpeechTranscriber` 换成满足
`SpeechTranscriberLike` 的另一份实现 —— `TranscriptStore` 一行都不用改。把引擎链进同一个
模块的边际成本不高;而 Android 侧的 JNI 胶水(`android/asr-native/reverb_asr.cpp`,约 100 行)
是**纯 whisper.cpp 调用,不含任何 Android 专有 API**,换到鸿蒙的 NAPI 只需换胶水层。

### 步骤

1. **决定引擎**。两个候选:
   - **whisper.cpp**(与 Android 同一个)—— 好处是两端文本与时间戳完全一致、一个多语言模型
     覆盖全部界面语言、模型文件可以复用同一份;
   - **sherpa-onnx**(k2-fsa,Apache-2.0)—— 中文更准更快、原生给 token 级时间戳,
     但每语言一套模型,内置多套体积不可接受;而且要确认它当下的 HarmonyOS 产物形态。

   若目标是"两端一致",选 whisper.cpp;若目标是"中文效果最好",选 sherpa-onnx 并接受
   只内置 zh + en。

2. **建 Native 模块**。鸿蒙的 native 走 `entry/src/main/cpp/` + `CMakeLists.txt`
   (由 hvigor 构建,与 Android 那边"绕开 AGP、预编译 .so"的做法不同 —— 鸿蒙这边不需要
   按渠道隔离,因为**鸿蒙只有一个渠道**,可以让 hvigor 正常编译)。模块里放三样:
   - 解码:`OH_AVSource` + `OH_AVDemuxer` + `OH_AudioCodec` 解到 16k 单声道 PCM;
   - 引擎:whisper.cpp(或 sherpa-onnx)静态链进来;
   - NAPI 导出:接口照 `AsrEngine` 的形状来 —— `init(modelPath)` / `transcribe(pcm, lang)` /
     `segmentCount/Text/StartMs/EndMs` / `free`。**分块与清洗逻辑放 ArkTS 侧**,
     与 Android 的 `WhisperEngine` 一一对应,别在 C++ 里重写一遍。

3. **模型怎么进包**。鸿蒙的 `resources/rawfile/` 与 Android 的 assets 等价,
   首次使用同样要拷到应用私有目录(引擎要真实路径)。57 MB 会让 `.app` 从 464 KB 涨到 60 MB 上下
   —— 应用市场没有硬性体积门槛,但要留意首次安装体验。
   **不入版本管理**,照 Android 的做法写一个 `harmony/tools/build-asr.sh`。

4. **把 `Features.CATALOG` 那条教训用上**:鸿蒙**没有 DCE**,常量为 false 也照样把代码和
   字符串编进 `modules.abc`(H54)。所以如果哪天要做"某个版本不带引擎",**必须把文件移出
   编译树**(参见 `harmony/shelved/` 的做法),不能靠常量门控。

5. **复用现成的东西**,别重写:
   - 缓存格式与状态机:`TranscriptStore`(三端同一份 JSON 形状);
   - 界面:播放页第三页、当前句高亮、逐帧外推、自动滚动都在 Android 的
     `ui/screens/TranscriptPane.kt` 里有对照实现;
   - 官方稿解析:`data/remote/TranscriptFetcher.kt`(SRT / VTT / Podcast Index JSON,
     含长 cue 切分与碎片行合并,这些规则都是拿真实稿调出来的,直接照搬)。

6. **验收照 Android 的清单做一遍**:真机上量速度(**用长音频,短切片会高估**,H55)、
   飞行模式下已下载单集能转(证明零联网)、切集即取消、缓存命中秒显。

### 一件要先定的事

隐私同意正文现在写着「不接入任何第三方 SDK」。自带 whisper/sherpa 是**本地库**
(不联网、不采集、音频不出设备),严格说不是 SDK,但这是对外披露文案,而 Android **只有一份包**,
这一句在两个分发处都会被读到(H205)—— 以前「只有自分发那份带引擎,所以只有那份要披露」的余地没了。
鸿蒙若也切到三方引擎,同一段文案要再过一遍。官网隐私政策页需同步。
