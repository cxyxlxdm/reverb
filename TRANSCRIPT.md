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
  按 2 分钟一块交出,峰值约 7.7 MB,顺带让界面能边转边出。块边界**往静音处挪**
  (前后 3 秒内找能量最低点)—— 切在词中间会让那个词两边都错;
- **`no_context = true`**。分块必须关掉跨块上下文,否则模型复读。代价是质量略降,
  收益是**快了近一倍**:同机同模型,应用内约 8 倍实时(1 小时约 7~8 分钟),
  命令行带上下文只有 4.0~4.6 倍;
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

### HarmonyOS —— 系统 ASR + 自己推时间轴(本轮未实施,方案已定)

用 Core Speech Kit(`@hms.ai.speechRecognizer`),它与 macOS 的 Speech 框架同一性质
(系统能力,不是三方 SDK),因此**不影响"不接三方 SDK"的对外表述**,也不涨包体积。

已在本地 SDK 里核实过的接口形状:

```ts
createEngine({ language, online: 1 /* 1=离线 */ })
  → startListening({ sessionId, audioInfo: { audioType, sampleRate, soundChannel, sampleBit } })
  → writeAudio(sessionId, Uint8Array)   // 自己按顺序喂 PCM
  → finish(sessionId)
onResult(sessionId, { isFinal, isLast, result: string })
```

**两个限制,和对应的做法**:

1. **结果里没有任何时间戳**。做法:因为 PCM 是我们自己按顺序喂进去的,
   "某句 `isFinal` 时已喂入多少字节"就是它的结束时刻(`已喂字节 ÷ 采样率`),
   起点取上一句的终点 ⇒ **句级时间轴**。逐词高亮做不了,退化成整句高亮 ——
   数据结构里 `words` 允许为 null 正是为此,三端共用同一份缓存格式;
2. **ArkTS 层没有解封装/解码 API**。整个 `@ohos.multimedia.*` 里没有 demuxer,
   grep 零命中;m4a/mp3 → 16k PCM 只能走 Native:`native_avsource.h` +
   `native_avdemuxer.h` + `native_avcodec_audiocodec.h`。**也就是说鸿蒙不管走哪条路,
   都得写一个 Native C++ 模块** —— 这一点直接影响下面那节的成本判断。

另外 `@hms.ai.AICaption` 名字最像但**不能用**:它是黑盒 UI 组件,`writeAudio` 进去、
系统自己把字幕画在面板上,**拿不到文本** —— 没法缓存、没法做我们自己的卡拉OK页、没法导出。
只能当"播放时叠一层实时字幕"的另一种玩法。

待真机确认(插上设备 20 行探针即可):`listLanguages` 的实际语言清单(API 5.1.0(18) 起才有,
早期版本只有 zh-CN)、离线模式单次音频的时长上限、目标机型上 HMS AI 服务是否在位。

---

## 三、将来鸿蒙要切到三方引擎,怎么做

会想切的理由通常是这三条里的一条:系统 ASR 只支持中文、拿不到词级时间戳、或者要和 Android
**逐字一致**(同一集在两端转出同样的文本)。

好消息:**大部分工作是共用的**。因为鸿蒙无论如何都要写 Native 解码模块,把引擎链进同一个
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
