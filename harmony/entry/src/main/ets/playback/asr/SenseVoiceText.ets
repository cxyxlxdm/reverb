import { TranscribedWord } from '../../model/Models';

/**
 * SenseVoice 的**纯文本逻辑**:语言映射、PCM 转换、token → 词单元、噪声过滤。
 *
 * 为什么单独一个文件、且不 import 任何 native 模块:
 * 这几条都是「同一段音频两端必须得到同一份稿」的不变式,值得单测覆盖,而单测跑在
 * 构建机上(**没有 sherpa 的 .so**)。把纯函数与引擎实现分开,是让 `hvigorw test`
 * 能真的验到它们的前提。
 *
 * 对应 Android 的 `playback/asr/AsrFactory.engineLanguage` + `SenseVoiceEngine`
 * 里的 `wordsFrom` / `keep`。两端的判定必须一致,改动要两边一起改。
 */
export class SenseVoiceText {
  static readonly SAMPLE_RATE: number = 16000;
  /**
   * 每块多少秒。SenseVoice 是**非自回归的 30 秒窗模型**:喂得更长不会多转出字,
   * 只是白占内存;26 秒留出余量,与 Android `PcmDecoder.CHUNK_SEC_RAMP` 同一个值。
   */
  static readonly CHUNK_SEC: number = 26;
  /**
   * 4 个线程。SenseVoice 的编码器是整段前向,4 线程在手机上已能跑到十几倍实时;
   * 再多只会抢核降频(与 Android 同一个经验值)。
   */
  static readonly THREADS: number = 4;

  /**
   * UI 语言 → SenseVoice 的 `language` 取值。空串 = 这个语言不在模型支持范围内。
   *
   * 支持范围是**模型能力**,不是可以随便扩的列表:zh / en / ja / ko / yue。
   * 法语、西语界面没有本机识别 —— 界面据此在点之前就说清原因。
   *
   * ⚠️ 繁体界面也走 `zh`,而 SenseVoice 输出**简体**(它没有输出繁体这个开关)。
   * 这是已知限制,记录在 docs/TRANSCRIPT.md,不要当 bug 重新查。
   */
  static engineLanguage(localeId: string): string {
    const dash = localeId.indexOf('-');
    const head = (dash > 0 ? localeId.substring(0, dash) : localeId).toLowerCase();
    if (head === 'zh') return 'zh';
    if (head === 'en') return 'en';
    if (head === 'ja') return 'ja';
    if (head === 'ko') return 'ko';
    if (head === 'yue') return 'yue';
    return '';
  }

  /// 本机识别能不能处理这个语言。界面在「生成」按钮出现之前就要用它。
  static supports(localeId: string): boolean {
    return SenseVoiceText.engineLanguage(localeId).length > 0;
  }

  /**
   * s16le 的 PCM 字节 → [-1, 1] 的 Float32(识别引擎吃的就是这一种)。
   *
   * 用 DataView 而不是把 buffer 直接当 Int16Array:字节长度可能是奇数(末块),
   * 而且 `byteOffset` 不保证偶数对齐 —— 直接构造会抛 RangeError。
   */
  static pcm16ToFloat(pcm: Uint8Array): Float32Array {
    const n = Math.floor(pcm.byteLength / 2);
    const out = new Float32Array(n);
    const view = new DataView(pcm.buffer, pcm.byteOffset, n * 2);
    for (let i = 0; i < n; i++) {
      out[i] = view.getInt16(i * 2, true) / 32768;
    }
    return out;
  }

  /**
   * 把 token 流变成带时刻的词单元(与 Android `SenseVoiceEngine.wordsFrom` 同一条)。
   *
   * sherpa-onnx 给的 `timestamps` 是**相对这一块**的秒数(浮点)。终点取**下一条的起点** ——
   * 比用 durations 更稳:模型给的 duration 在句尾可能超出块尾,而下一条起点天然单调。
   * 最后一条用块尾兜底。起点单调与 ≥0 这两条不变式在这里就成立
   * (渲染侧依赖它们,见 `TranscriptLines.monotonic` 的注释与硬规矩 10)。
   *
   * 文本首尾的空格要削掉:中文 token 没有空格,英文 token **自带前导空格**
   * (第一个除外,但模型有时也会给)。不削的话每行开头会多一个空格。
   */
  static wordsFrom(tokens: string[], timestamps: number[], offsetMs: number, chunkEndMs: number): TranscribedWord[] {
    if (tokens.length === 0 || timestamps.length !== tokens.length) return [];
    const out: TranscribedWord[] = [];
    for (let i = 0; i < tokens.length; i++) {
      const raw = tokens[i];
      if (raw.length === 0) continue;
      // 特殊标记(`<|zh|>`、`<|BGM|>` 这类)不是内容
      if (raw.length >= 3 && raw.startsWith('<|') && raw.endsWith('|>')) continue;
      const s = offsetMs + Math.round(timestamps[i] * 1000);
      const e = i + 1 < tokens.length
        ? offsetMs + Math.round(timestamps[i + 1] * 1000)
        : chunkEndMs;
      const text = out.length === 0 ? raw.trimStart() : raw;
      if (text.length === 0) continue;
      out.push({ text: text, startMs: Math.max(s, 0), endMs: Math.max(e, s) });
    }
    // 末尾那条把尾随空格也削掉,维持"words 拼接 == 行文本"且行尾干净
    if (out.length > 0) {
      const last = out[out.length - 1];
      const trimmed = last.text.trimEnd();
      if (trimmed.length === 0) out.pop();
      else out[out.length - 1] = { text: trimmed, startMs: last.startMs, endMs: last.endMs };
    }
    return out;
  }

  /**
   * 该不该留这一句。挡掉两类东西:
   * - **复读**:片头音乐/口号上模型可能把同一句吐几遍,连续相同就丢(跨块也管用);
   * - **音乐/掌声/字幕署名**:`[音乐]`、`(Music)`、`(字幕:J Chong)` 这类不是内容。
   *   SenseVoice 自己会把 BGM / 掌声放进 `event` 字段而不是文本,但片尾静音处仍可能
   *   串出一句括号署名 —— 这一道与 Android 同一条。
   */
  static keep(text: string, lastText: string): boolean {
    if (text.length === 0) return false;
    if (text === lastText) return false;
    if (text.length <= 24 && SenseVoiceText.MARKER.test(text)) return false;
    return true;
  }

  /// 整句被一对括号包住、且括号内不超过 20 字 = 标记,不是内容
  private static readonly MARKER: RegExp = new RegExp('^[\\[(（【][^\\])）】]{0,20}[\\])）】]$');
}
