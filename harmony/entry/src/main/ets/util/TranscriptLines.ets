import { TranscribedSegment, TranscribedWord } from '../model/Models';

/**
 * 把逐字稿整理成**屏幕上一行左右**的句子。对应 Android `util/TranscriptLines.kt`,规则逐条对齐。
 *
 * 两条来源都要用它,所以抽在这里:
 * - 官方稿(`net/TranscriptFetcher`):VTT 的 cue 可以长到几百字,JSON 稿则是一词一条;
 * - 系统语音识别(`playback/SpeechTranscriber`):一次 `onResult` 可能是一大段话。
 *
 * 为什么必须切:跟读高亮的粒度就是句子的粒度。一段三百字的文本会整段高亮二十多秒,
 * 跟读效果等于没有,还得在屏幕上滚半天才看到当前位置。
 *
 * 时间轴按**字符占比**线性插值。一句话内部语速大体均匀,这个近似的误差远小于"整段一起亮"。
 */
export class TranscriptLines {

  /// 中文一行 24 字、西文 42 字符 —— 都是按手机屏宽估的
  static readonly CJK_CHARS: number = 24;
  static readonly WEST_CHARS: number = 42;
  /// 细碎条目之间静音超过这个值就断句 —— 通常是换气或换人说话
  static readonly MAX_GAP_MS: number = 900;
  static readonly ORPHAN_CHARS: number = 12;
  static readonly GLUE_GAP_MS: number = 400;

  /// 句末标点(中西都收)。合并细碎条目与切分长句都按它断。
  private static readonly SENTENCE_END: string = '。！？；.!?;…';

  private static isSentenceEnd(ch: string): boolean {
    return TranscriptLines.SENTENCE_END.indexOf(ch) >= 0;
  }

  /**
   * 一行的目标字数。**中文与西文不是一个数** —— 汉字宽得多,42 个汉字在手机上要占三行。
   * 按内容里 CJK 的比例选:多数是汉字就用 24,否则 42。
   */
  static targetChars(text: string): number {
    if (text.length === 0) return TranscriptLines.WEST_CHARS;
    let cjk = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if ((c >= 0x3400 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF)) cjk++;
    }
    return cjk * 2 >= text.length ? TranscriptLines.CJK_CHARS : TranscriptLines.WEST_CHARS;
  }

  /// 以 ASCII 起头 ⇒ 拼接时前面要加空格(中文之间不加)。
  static isAsciiHead(s: string): boolean {
    return s.length > 0 && s.charCodeAt(0) < 128;
  }

  /**
   * 一句太长就切开,时间按字符占比分摊。短句原样返回。
   */
  static split(text: string, startMs: number, endMs: number): TranscribedSegment[] {
    const target = TranscriptLines.targetChars(text);
    if (text.length <= Math.floor(target * 3 / 2)) {
      return [{ text: text, startMs: startMs, endMs: endMs, words: [] } as TranscribedSegment];
    }
    const chunks: string[] = [];
    let rest = text;
    while (rest.length > target) {
      // 优先在目标长度附近的句末标点断;找不到就退到最后一个空格;都没有(中文长句)就硬切
      const window = rest.substring(0, target + Math.floor(target / 4));
      let cut = -1;
      for (let i = window.length - 1; i >= 0; i--) {
        if (TranscriptLines.isSentenceEnd(window.charAt(i))) { cut = i; break; }
      }
      if (cut < Math.floor(target / 2)) cut = -1;
      if (cut <= 0) {
        const sp = window.lastIndexOf(' ');
        cut = sp >= Math.floor(target / 2) ? sp : target - 1;
      }
      chunks.push(rest.substring(0, cut + 1).trim());
      rest = rest.substring(cut + 1).replace(/^\s+/, '');
    }
    if (rest.trim().length > 0) chunks.push(rest);

    let total = 0;
    for (let i = 0; i < chunks.length; i++) total += chunks[i].length;
    if (total < 1) total = 1;
    const span = Math.max(endMs - startMs, 0);
    const out: TranscribedSegment[] = [];
    let acc = 0;
    for (let i = 0; i < chunks.length; i++) {
      const s = startMs + Math.floor(span * acc / total);
      acc += chunks[i].length;
      const e = startMs + Math.floor(span * acc / total);
      out.push({ text: chunks[i], startMs: s, endMs: Math.max(e, s), words: [] } as TranscribedSegment);
    }
    return out;
  }

  /**
   * 把孤零零的碎片行并回上一行。
   *
   * 为什么需要:长度规则会在句末词之前就把行切掉,于是句子的最后一两个词单独成行 ——
   * 屏幕上就是 "one." 独占一行,很难看。只在**与上一行几乎连着说**(间隔 < 400ms)时才并,
   * 否则那本来就是一句短的应答(「Yes.」「我也是。」),独立成行是对的。
   */
  static glueOrphans(lines: TranscribedSegment[]): TranscribedSegment[] {
    const out: TranscribedSegment[] = [];
    for (let i = 0; i < lines.length; i++) {
      const seg = lines[i];
      const prev = out.length > 0 ? out[out.length - 1] : null;
      if (prev !== null && seg.text.length < TranscriptLines.ORPHAN_CHARS
          && seg.startMs - prev.endMs < TranscriptLines.GLUE_GAP_MS) {
        // 空格折进被并进来那一段的文本里,维持"words 拼接 == 整句"的不变式
        const glued = TranscriptLines.isAsciiHead(seg.text) ? ' ' + seg.text : seg.text;
        const mergedWords: TranscribedWord[] = [];
        if (prev.words.length > 0) {
          for (let k = 0; k < prev.words.length; k++) mergedWords.push(prev.words[k]);
        } else {
          mergedWords.push({ text: prev.text, startMs: prev.startMs, endMs: prev.endMs } as TranscribedWord);
        }
        if (seg.words.length > 0) {
          // 被并进来的一段:第一条要带上那个空格,否则拼接不等于整句
          for (let k = 0; k < seg.words.length; k++) {
            const w = seg.words[k];
            const t = (k === 0 && glued !== seg.text) ? ' ' + w.text : w.text;
            mergedWords.push({ text: t, startMs: w.startMs, endMs: w.endMs } as TranscribedWord);
          }
        } else {
          mergedWords.push({ text: glued, startMs: seg.startMs, endMs: seg.endMs } as TranscribedWord);
        }
        out[out.length - 1] = {
          text: prev.text + glued,
          startMs: prev.startMs,
          endMs: seg.endMs,
          words: mergedWords
        } as TranscribedSegment;
      } else {
        out.push(seg);
      }
    }
    return out;
  }

  /**
   * 把起点夹成**单调不减**、且不为负;终点不早于起点。
   *
   * 为什么非做不可:渲染侧判断"读到哪个词/哪句"是从后往前找第一个 `startMs <= now` ——
   * 这个写法只在起点单调时才正确。队尾只要混进一个异常小的值,它就永远满足条件,
   * 于是**高亮钉死在那一条再也不动**(Android 端真实事故,见 TROUBLESHOOTING H60)。
   *
   * 这里是所有来源的共同入口,所以放在这里最省事 —— 尤其覆盖**发布方给的稿**:
   * 别人生成的文件不能假定一定按时间排好。
   */
  static monotonic(words: TranscribedWord[]): TranscribedWord[] {
    let prev = 0;
    let needFix = false;
    for (let i = 0; i < words.length; i++) {
      const w = words[i];
      if (w.startMs < prev || w.startMs < 0 || w.endMs < w.startMs) { needFix = true; break; }
      prev = w.startMs;
    }
    if (!needFix) return words;
    const out: TranscribedWord[] = [];
    let at = 0;
    for (let i = 0; i < words.length; i++) {
      const w = words[i];
      const s = Math.max(w.startMs, at);
      at = s;
      out.push({ text: w.text, startMs: s, endMs: Math.max(w.endMs, s) } as TranscribedWord);
    }
    return out;
  }

  /**
   * **细碎条目 → 可读的一行**,并把原始条目留在 `words` 里(于是能逐词高亮)。
   *
   * 三个断句依据,先到先断:句末标点 / 累计长度超过一行 / 与下一条之间静音超过 900ms
   * (换气或换人说话)。行宽按**这一行的首条**判中西文并锁定 —— 逐条重判会在中文句里夹一个
   * 英文词时突然把行宽从 24 放到 42,断句就一会儿宽一会儿窄。
   *
   * @param spaced 传 true 表示条目**不自带空格**,需要按 ASCII 规则补(官方 JSON 稿);
   *   传 false 表示条目自带该有的空格,原样拼接。
   *   无论哪种,产出都满足 `words` 拼接 == 行文本这条不变式。
   */
  static mergeWords(wordsIn: TranscribedWord[], spaced: boolean): TranscribedSegment[] {
    const words = TranscriptLines.monotonic(wordsIn);
    const out: TranscribedSegment[] = [];
    let buf: TranscribedWord[] = [];
    let len = 0;
    let target = TranscriptLines.WEST_CHARS;

    for (let i = 0; i < words.length; i++) {
      const w = words[i];
      // 需要补空格时**把空格折进 text**,以维持"拼接 == 整句"的不变式
      const text = (spaced && len > 0 && TranscriptLines.isAsciiHead(w.text)) ? ' ' + w.text : w.text;
      if (buf.length === 0) target = TranscriptLines.targetChars(text);
      buf.push({ text: text, startMs: w.startMs, endMs: w.endMs } as TranscribedWord);
      len += text.length;

      const trimmed = text.replace(/\s+$/, '');
      const endsSentence = trimmed.length > 0
        && TranscriptLines.isSentenceEnd(trimmed.charAt(trimmed.length - 1));
      const gapNext = i + 1 < words.length ? words[i + 1].startMs - w.endMs : 0;

      if (endsSentence || len >= target || gapNext > TranscriptLines.MAX_GAP_MS) {
        out.push(TranscriptLines.flush(buf));
        buf = [];
        len = 0;
      }
    }
    if (buf.length > 0) out.push(TranscriptLines.flush(buf));
    return TranscriptLines.glueOrphans(out);
  }

  private static flush(buf: TranscribedWord[]): TranscribedSegment {
    let text = '';
    for (let i = 0; i < buf.length; i++) text += buf[i].text;
    const kept: TranscribedWord[] = [];
    // 只有真的合了多条才留词级时间;本来就是整句的稿留了也没用,白占缓存
    if (buf.length > 1) {
      for (let i = 0; i < buf.length; i++) kept.push(buf[i]);
    }
    return {
      text: text,
      startMs: buf[0].startMs,
      endMs: buf[buf.length - 1].endMs,
      words: kept
    } as TranscribedSegment;
  }
}
