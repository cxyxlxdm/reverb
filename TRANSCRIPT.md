# 逐字稿 / 语音转文字:三端实现与取舍

播放页横滑第三页显示这一集的文字,跟着播放进度高亮,点一句跳到那一刻;每单集 × 每语言
一份 JSON 缓存,命中即秒显。三端**功能形状一致、取字方式各不相同** —— 因为可用的系统能力
和渠道的合规口径不同。

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
- 门控 `@available(macOS 26, *)`,旧系统显示"需要 macOS 26"。

**功能不做渠道删减** —— macOS 是自分发,不受大陆商店的合规口径约束。

### Android —— 两个渠道两种做法

| | 默认渠道 `default`(自分发) | 大陆商店渠道 `store` |
| --- | --- | --- |
| 官方逐字稿 | 有 | 有 |
| 本机识别 | **whisper.cpp + 内置模型** | **完全不含** |
| 播放页第三页 | 始终可用(跟设置开关) | **仅当该集有官方稿** |
| APK 体积 | 约 62 MB | 约 3.8 MB |

**为什么 Android 不用系统 ASR**:因为不能依赖。实测一台 Android 16 的 OnePlus(装了 Google 应用):

```
pm query-services -a android.speech.RecognitionService   → No services found
settings get secure voice_recognition_service             → null
```

国内无 GMS 的 ROM 更不用指望。所以要么自带引擎,要么这个功能在大多数机器上不存在。

**为什么大陆商店渠道不带引擎**:合规口径下,内置一个几十 MB 的语音识别模型是无谓的风险面;
而这个渠道本来就有官方稿那条路。用户拍板:**没稿就不出第三页**,不摆一个空页。

**隔离靠 source set,不是运行时开关**。这一点是硬性的:R8 能折叠常量、删掉 Kotlin 代码,
但**删不掉 `.so` 与 assets** —— native 库和模型是构建系统按 source set 打进包的。所以:

```
app/src/main/    …/asr/AsrEngine.kt      只有接口
app/src/main/    …/asr/PcmDecoder.kt     解码(与渠道无关,纯 Kotlin)
app/src/default/ …/asr/AsrFactory.kt     返回 WhisperEngine,HAS_ENGINE = true
app/src/default/ …/asr/WhisperEngine.kt  引擎实现
app/src/default/jniLibs/arm64-v8a/       libreverb_asr.so   ← 不入库
app/src/default/assets/whisper-model.bin ggml-base-q5_1     ← 不入库
app/src/store/  …/asr/AsrFactory.kt     返回 null,HAS_ENGINE = false
```

`AsrFactory.HAS_ENGINE` 是 per-flavor 的 `const val`,**不需要额外的 buildConfigField** ——
R8 折叠效果一样,而且只有一处真相。

**验收方式是解包 grep,不是点界面**(H46 / H54)。当前结果:

```
商店渠道:dex 里 whisper / reverb_asr / ggml 各 0 次;无 lib/ 目录;assets 无模型
默认渠道:dex 有;lib/arm64-v8a/libreverb_asr.so 有;assets 有 57 MB 模型
```

**产物不入版本管理**:`.so`(1.6 MB)与模型(57 MB)由 `android/tools/build-asr.sh` 一条命令
重建(固定 whisper.cpp commit + 校验模型 sha256)。`build-release.sh` 在引擎启用时会检查它们
在不在,缺了报错退出;引擎关着时不检查,于是任何机器都能直接构建默认渠道。

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

  设置项叫「逐字高亮」,**两个渠道都有,但副标题不同**(`src/default|store/res/values-*`):
  完整版说明"不额外增加转写耗时";大陆商店渠道没有识别引擎,那边这个开关只影响
  **发布方逐字稿**的渲染,所以副标题说明"需要发布方提供的逐字稿,没有稿的单集用不了"。

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

**仍待真机确认**(本轮只做到编译与解包验收,手上没有鸿蒙设备可测):
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
(不联网、不采集、音频不出设备),严格说不是 SDK,但这是对外披露文案,而且**两渠道共用一份**。
Android 默认渠道带引擎发版前就要定;鸿蒙若也切到三方引擎,同一段文案要再过一遍。
官网隐私政策页需同步。
