# 离线 ASR 引擎换代：whisper base → SenseVoiceSmall（2026-11-11 决策）

> **状态：已拍板；Android 已实施并过真机验收（2026-11-11），鸿蒙待做。**
> 结论：Android 与鸿蒙换用 **sherpa-onnx + SenseVoiceSmall int8**；macOS / iOS 继续用系统
> `SpeechAnalyzer`（Apple 端本来就是系统能力，质量与包体都更优）。**不再保留 whisper.cpp**。
> Android 的实际读数见 §三、§五、§七（与拍板时的估算有出入，以实测为准）。

---

## 一、为什么要换

Android 现在随包内置 `ggml-base-q5_1`（57 MB）。base 是 whisper 家族里最小的一档，
中文播客上的错误集中在这几类（2026-11-11 用同一段 3 分钟真实单集实测）：

| whisper base 输出 | 正确内容 |
| --- | --- |
| 生动**造**咖啡 | 生动**早**咖啡 |
| 持续**的城市**新的产品形态 | 持续**的尝试**新的产品形态 |
| 资本的**价值** | 资本的**加持** |
| 品牌**异价** | 品牌**溢价** |
| 大幅**缩解** | 大幅**缩减** |
| **清律** / 住宿**行事** | **青旅** / 住宿**形式** |

同时它需要提示词压繁体、会把整段吐成一句再切、片头音乐会复读。这些清洗逻辑是为 base 的
缺陷写的；换引擎之后要逐条重验，不能假设它们还成立。

## 二、候选与实测

测试条件：本机（Apple Silicon）`sherpa-onnx 2.0.1` Python 包 + whisper.cpp 固定 commit
`233fe1fc` 的主机探针；同一段 3 分钟中文单集（16 kHz 单声道）；whisper 用 `zh` +
「以下是普通话的句子。」提示词、`no_context=true`、4 线程，与线上同参数。

| 引擎 | 模型体积 | 3 分钟耗时 | 时间戳 | 中文质量 |
| --- | --- | --- | --- | --- |
| whisper base-q5_1（现状） | 57 MB | 3.4 s | token 级 | 差，见上表 |
| **SenseVoiceSmall int8（选定）** | **239,233,841 B** | 4.6 s | **889 字 / 889 条** | 明显好；仍有同音字（「用生意」对「用声音」、「情旅」对「青旅」） |
| Paraformer-zh-small int8 | 81,828,675 B | 1.9 s | **0 条** | 明显更差（「我国」对「苹果」、「上生步」），淘汰 |

关键取舍：

- **Paraformer-small 淘汰**：体积只有三分之一、速度最快，但小模型既没有时间戳（`timestamps` 为空），
  文本也更差。用它等于换掉引擎却退步。
- **SenseVoice 的语言覆盖**：中、粤、英、日、韩；**没有法语 / 西班牙语**。1.0.8 起这两类语言
  不再提供本机转写，界面要如实说明（官方逐字稿不受影响）。
- **SenseVoice 输出标点**：`use_itn=1` 时带逗号句号；不开只有裸文本。实现里固定开启。
- **简繁**：SenseVoice 没有提示词机制，中文输出以简体为主。繁体界面需要一层简→繁转换，
  否则是相对 whisper 提示词方案的退步（见待办 3）。

## 三、体积核算（Android，已按实包核对）

拍板时按"自己写 JNI + 链 C API"估的是 250 MB；实际直接用了上游 AAR 的 Kotlin API，
**不需要 `libsherpa-onnx-c-api.so`、也没有自写胶水**，包里只有两份 `.so`。逐项实测：

| 项 | 实际值 / 变化 |
| --- | --- |
| 移除 whisper 模型 | −59,707,625 B |
| 移除 `libreverb_asr.so`（whisper + JNI） | −1,679,264 B |
| 加入 SenseVoice int8 模型 `assets/sensevoice/model.int8.onnx` | +239,233,841 B |
| 加入 `assets/sensevoice/tokens.txt` | +315,894 B |
| 加入 `libsherpa-onnx-jni.so`（arm64） | +4,609,320 B |
| 加入 `libonnxruntime.so`（arm64） | +22,249,560 B |
| 加入 `libs/sherpa-onnx.jar`（AAR 的 classes.jar） | +245,045 B |
| **1.0.7 → 1.0.8 release 实包** | **65,180,564 B → 270,119,993 B（+204,939,429 B，约 4.1 倍）** |
| debug 包（对照） | 287,971,492 B |

`unzip -l dist/reverb.apk | grep -E 'lib/|sensevoice'` 现读四条：两份 `.so`、模型、词表，
没有 c-api 那份。解包条目总数 184。

鸿蒙同理：`.app` 预计涨到约 240 MB 量级（首次安装与更新成本要写进商店说明与
`docs/LOCAL-ASSETS.md`）。模型不入版本管理，由 `build-asr.sh` 下载并按 sha256 校验。

## 四、许可证与对外表述

| 组件 | 许可证 | 义务 |
| --- | --- | --- |
| sherpa-onnx | Apache-2.0 | 保留版权与许可声明 |
| ONNX Runtime | MIT | 同上 |
| SenseVoiceSmall / FunASR | FunASR Model Open Source License 1.1 | **必须标注来源与模型名**，保留模型名 |

三者都是**本地推理库/权重**：不联网、不采集、音频不出设备。但"不接入任何第三方 SDK"这句
对外文案要改成能同时说清二者的写法（本机识别 = 随包内置的开源推理库 + 模型），
并同步：App 内关于页（五语）、`docs/PRIVACY.md`、`site/reverb/privacy.html`、同意页正文、
`docs/TRANSCRIPT.md`、`docs/FEATURES.md`、`docs/ARCHITECTURE.md`。

## 五、实施结果（与拍板方案不一致的地方都标出来）

1. **分块**：`PcmDecoder.CHUNK_SEC_RAMP = [26]` 固定一块，边界在 **26 s ± 3 s** 内找静音，
   最晚 29 s 切，仍在 30 s 窗以内；比拍板时的 28 s 更保守一档（给"静音点被推到目标点之后"
   留余量）。首块没有单独加长 —— 真机首块 3.8 s，首字延迟不是问题。
2. **时间戳**：走 AAR 的 **Kotlin API**（`OfflineRecognizerResult.tokens` / `.timestamps`），
   不是 C API。`timestamps` 是每个 token 相对**本块**的起点（秒），终点取下一条起点、
   最后一条取块尾；`<|zh|>` 这类特殊标记在 `wordsFrom` 里丢掉。词级时刻**不额外算 DTW**
   （那是 whisper 时代"逐字高亮多花 70% 时间"的来源），SenseVoice 一次前向就带出来。
3. **缓存**：`CACHE_VERSION = 3`；缓存文件按 `episodeId.localeId.json` 分键，
   内容含 `version` / `complete` / `segments(words)`。旧 v2 稿自动作废重转。
4. **模型落地**：AAR 的 `classes.jar` 解成 `app/libs/sherpa-onnx.jar`，两份 `.so` 放
   `jniLibs/arm64-v8a/`；模型与词表从 assets 首次拷到 `filesDir/sensevoice/`（按大小判完整），
   Gradle 对 `.bin` / `.onnx` 开 `noCompress`。R8 必须 `-keep class com.k2fsa.sherpa.onnx.**`
   —— JNI 用 `RegisterNatives` 按名字查找，混掉就是 release-only 的 `UnsatisfiedLinkError`。
5. **语言闸门**：`AsrFactory.engineLanguage` 只认 zh / en / ja / ko / yue；`supports()` 为 false
   时播放页直接显示"本机识别不支持这种语言"，**不摆按钮**（`TranscriptStore.State.UnsupportedLocale`）。
   zh-TW 界面走 `zh`，输出是**简体** —— 已知限制，写进 `docs/TRANSCRIPT.md`。
6. **鸿蒙：未做。** `Features.LOCAL_ASR` 仍是 false；接入路径与真机验收要求不变（见 §六）。

实测（Pixel 3 / Android 12，13:47 的中文单集，release 包）：
一共 32 块，单块识别 3.8–6.2 s，整集约 **3 分 15 秒**（**0.24× 实时**，约 4.2 倍速），
逐字稿 188 行；同一集在 debug 包里也是 188 行（引擎行为一致，差的是包体）。
按此推算 1 小时单集约 14 分钟 —— **这是推算，不是实测**。

## 六、没做 / 待办

1. **Android 真机实测：已做一半。** Pixel 3 上 13:47 单集的读数见 §五；
   **1 小时单集还没跑**（§五 里的 14 分钟是线性推算），发热只观察了"不快"，没有温度读数。
2. **iOS 17–25**：Apple 端只有 iOS 26 的 `SpeechAnalyzer`；旧系统仍没有本机转写。
   1.0.8 不动这条。
3. **简繁转换**：**没做，当前输出简体**。繁体界面下本机转写是简体字，官方稿不受影响；
   要补就是内置一张简→繁表或拍板"接受简体"。
4. **VAD**：没上 Silero。26 s + 静音搜索在真机上没有出现明显的切句损失，暂不加 2 MB。
5. **法语/西语**的替代方案：官方稿照旧；如果以后要补，需要另做一个可选模型包，
   不在 1.0.8 范围内。
6. **鸿蒙接入**：尚无 `sherpa-onnx` 的 ArkTS 侧实现；`Features.LOCAL_ASR` 保持 false，
   开启前必须过 Mate 60 真机质量与耗时验收（硬规矩 17 的同类要求）。

## 七、实测原文（摘录）

主机（M 系列 Mac）：

- SenseVoice 3 分钟中文：889 字，889 token，889 条时间戳；4.6 s。
- Paraformer-zh-small：843 字，0 条时间戳；1.9 s。
- whisper base：28 句 / 887 字；3.4 s（主机探针，`flash_attn=1`）。
- 语言自动检测：`<|zh|>` / `<|en|>` 正常；`use_itn=1` 时中文带标点。

Android 真机（Pixel 3，release 包，`adb logcat` 原样摘录）：

```
I/Reverb/SenseVoice: 首次拷贝模型 228 MB
I/Reverb/SenseVoice: 模型已加载 lang=zh threads=4
I/Reverb/PcmDecoder: 解码输出 44100Hz 2ch
I/Reverb/SenseVoice: 块 startMs=0 样本=414400 字=80 用时=3825ms
I/Reverb/SenseVoice: 块 startMs=25900 样本=403840 字=149 用时=4041ms
…
I/Reverb/SenseVoice: 块 startMs=819720 样本=126562 字=34 用时=1694ms
I/Reverb/SenseVoice: 转写结束 ok=true 已出 188 句
```

（`样本=414400` ÷ 16000 = 25.9 s，与"26 s ± 静音搜索"一致。）

来源（2026-11-11 抓取）：

- sherpa-onnx（Apache-2.0，HarmonyOS 有 `harmony-os/SherpaOnnxHar`）：
  <https://github.com/k2-fsa/sherpa-onnx>
- SenseVoiceSmall 模型与 FunASR 模型许可：
  <https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE>
- 预训练模型体积（SenseVoice int8 228 MB / Paraformer-small int8 78 MB）：
  <https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html>
