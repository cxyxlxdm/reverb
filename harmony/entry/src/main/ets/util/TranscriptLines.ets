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

  /**
   * 中文一行 18 字、西文 38 字符 —— 切出来的每一条都必须**画得进一行**。
   *
   * 原先写的是 24 / 42,注明"按手机屏宽估的",但**从没拿真机量过**。2026-11-13 在 Mate 60
   * (374 vp 宽、页面左右各 24 ⇒ 正文 326 vp、14 vp 字)上量到一行只放得下 **23 个汉字**:
   * 每条 24 字的段落因此恰好溢出 1 个字,屏幕上就是"一行铺满 + 下一行一个字",且断点落在词中间。
   * 本页字号已按另两端对齐到 16 vp(容量 ⇒ 20 个);Android 的 `bodyLarge`
   * (16sp + 0.5sp 字距、344 dp 正文)同样是 20 个 —— 24 对这两端都是**取整取在了临界点上**。
   *
   * 规律:目标字数要比**最窄那台机器**的容量再小两格,不能等于容量(等于就是"每次刚好溢出")。
   * 18 对应的容量下限是 360 dp 小屏(正文 312 dp ÷ 每字 16.5 dp ⇒ 18 个);
   * 38 按 18 × 2.1(汉字宽度约西文的 2.1 倍)折出来,西文又按词断开,余量更宽。
   * ⚠️ 系统字号调到 1.1 倍以上仍可能挤出一两个字 —— 固定尺子的固有边界:三端共用一把尺子
   * (跨端要能数行数,见 H150)优先于按每台机器的实际排版宽度算。
   */
  static readonly CJK_CHARS: number = 18;
  static readonly WEST_CHARS: number = 38;
  /// 细碎条目之间静音超过这个值就断句 —— 通常是换气或换人说话
  static readonly MAX_GAP_MS: number = 900;
  /**
   * 并回上一行后允许比目标多出的**字数**。多一两个仍画得进一行(`CJK_CHARS` 那里留了余量),
   * 再多就会把第二行挤成一两个字 —— 那正是 2026-11-13 修掉的形状(见 H280)。
   *
   * 原先的判据是"碎片不足 12 字就并",**没有上限**:18 字的行并上一个 11 字的尾巴就是 29 字,
   * 换行后第二行只剩一两个字符。并句的目的只是别让「one.」独占一行,不是"越长越好"。
   */
  static readonly GLUE_OVERHANG: number = 2;
  static readonly GLUE_GAP_MS: number = 400;

  /// 句末标点(中西都收)。合并细碎条目与切分长句都按它断。
  private static readonly SENTENCE_END: string = '。！？；.!?;…';

  private static isSentenceEnd(ch: string): boolean {
    return TranscriptLines.SENTENCE_END.indexOf(ch) >= 0;
  }

  /**
   * 一行的目标字数。**中文与西文不是一个数** —— 一个汉字大约占两个西文字符的宽度。
   * 汉字占一半以上,或**有汉字且按字宽折算**已超过一行西文的容量,都按中文行宽走
   * (纯西文永远走 38,不受折算影响)。
   *
   * 只看"汉字是否过半数"会漏掉中英混排:"元今年 open a i 一度在部分收入指标上落后于
   * anropic 彭"汉字只有 47%,按 38 个字符切,上屏就是一行放不下再折一行 ——
   * 与 H280 修的是同一个形状,只是触发条件藏在混排里。
   */
  static targetChars(text: string): number {
    if (text.length === 0) return TranscriptLines.WEST_CHARS;
    let cjk = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if ((c >= 0x3400 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF)) cjk++;
    }
    const columns = cjk * 2 + (text.length - cjk);
    return (cjk * 2 >= text.length || columns > TranscriptLines.WEST_CHARS)
      ? TranscriptLines.CJK_CHARS : TranscriptLines.WEST_CHARS;
  }

  /// 以 ASCII 起头 ⇒ 拼接时前面要加空格(中文之间不加)。
  static isAsciiHead(s: string): boolean {
    return s.length > 0 && s.charCodeAt(0) < 128;
  }

  /// 一行开头**一小段**(够一个汉字行宽)用于判行宽 —— 只取首条会误判混排小条目。
  private static headWindow(words: TranscribedWord[], from: number): string {
    let head = '';
    let k = from;
    while (k < words.length && head.length < TranscriptLines.CJK_CHARS) {
      head += words[k].text;
      k++;
    }
    return head;
  }

  /**
   * 一句太长就切开,时间按字符占比分摊。**放得进一行的原样返回**。
   *
   * 早先的提前返回放宽到 `target * 3 / 2`,切分窗口也取到 `target + target / 4` ——
   * 于是 27 字的 cue 整条进稿,上屏折成两行、第二行只剩几个字。行宽这把尺子的用途就是
   * "每一条都画得进一行",这一条不能有例外(见 H280);宁可硬切,不越一行。
   */
  static split(text: string, startMs: number, endMs: number): TranscribedSegment[] {
    const target = TranscriptLines.targetChars(text);
    if (text.length <= target) {
      return [{ text: text, startMs: startMs, endMs: endMs, words: [] } as TranscribedSegment];
    }
    const chunks: string[] = [];
    let rest = text;
    while (rest.length > target) {
      // 优先在一行窗口内的句末标点断;找不到就退到最后一个空格;都没有(中文长句)就硬切
      const window = rest.substring(0, target);
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
   * 把孤零零的碎片行并回上一行 —— 但**并完必须仍放得进一行**。
   *
   * 为什么需要:长度规则会在句末词之前就把行切掉,于是句子的最后一两个词单独成行 ——
   * 屏幕上就是 "one." 独占一行,很难看。只在**与上一行几乎连着说**(间隔 < 400ms)时才并,
   * 否则那本来就是一句短的应答(「Yes.」「我也是。」),独立成行是对的。
   *
   * 上限是"**并完之后**这一行的目标字数 + `GLUE_OVERHANG`":并句是为了消灭碎片行,
   * 不是为了把两行挤进一段。
   * 旧判据只看"碎片本身不足 12 字",于是 18+11=29 字也能并出来,换行后第二行只剩一两个字 ——
   * 与用户报的"一行铺满 + 一个字"是同一个形状(见 H280)。超出一行的尾巴**宁可让它自己成行**:
   * 一条 5~17 字的短句读着正常,挤出来的孤字不正常。
   */
  static glueOrphans(lines: TranscribedSegment[]): TranscribedSegment[] {
    const out: TranscribedSegment[] = [];
    for (let i = 0; i < lines.length; i++) {
      const seg = lines[i];
      const prev = out.length > 0 ? out[out.length - 1] : null;
      // 空格折进被并进来那一段的文本里,维持"words 拼接 == 整句"的不变式
      const glued = TranscriptLines.isAsciiHead(seg.text) ? ' ' + seg.text : seg.text;
      // 上限按**并完之后整行**的字宽判,不按上一行自己:上一行常是「4分之1。」这种
      // 五六个字的短条,单看它会被判成西文 38 字,于是并出一条 21 字的长行。
      const merged = prev === null ? null : prev.text + glued;
      if (prev !== null && merged !== null && seg.startMs - prev.endMs < TranscriptLines.GLUE_GAP_MS
          && merged.length <= TranscriptLines.targetChars(merged) + TranscriptLines.GLUE_OVERHANG) {
        const mergedWords: TranscribedWord[] = [];
        // 两边都没有词级时间(整句稿被并起来,例如两条短 cue)时**不凭空造词**:
        // 早先这里会合成 [{prev.text}, {glued}] 两条,同一份稿于是鸿蒙按两句跳、
        // Android 整句一亮(另一端是 `words = null`),粒度对不上;而 `flush` 里
        // 明明写着"本来就是整句的稿留了也没用,白占缓存"。见 H150。
        if (prev.words.length > 0 || seg.words.length > 0) {
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
   * (换气或换人说话)。行宽按**这一行开头的一段**判中西文并锁定(不是按首条:首条常是
   * 「4分之1。」这种混排小条目,单看它会被判成西文 38 字,同一行后面再接汉字就撑到 25 字)——
   * 逐条重判也不行,中文句里夹一个英文词会让行宽一会儿 18 一会儿 38。
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
      // 空格算不算长度要在断行之前定:断完 len 归零,再加前缀就多一个空格
      const wantSpace = spaced && TranscriptLines.isAsciiHead(w.text);
      // 长度到点就断,**但要先加再看**:旧写法是"加完再看 len >= target",而一个条目
      // 可能是 2~3 个字,于是每行实际能到 target+3 —— 21 字在 Android 的 20 字容量下
      // 正好溢出,屏幕上又是"一行铺满 + 下一行一个字"(H280 的同一个形状)。
      // 标点条目例外:让它黏在上一行尾(见 isPunctOnly)。
      if (buf.length > 0 && !TranscriptLines.isPunctOnly(w.text)
        && len + w.text.length + (wantSpace ? 1 : 0) > target) {
        out.push(TranscriptLines.flush(buf));
        buf = [];
        len = 0;
      }
      if (buf.length === 0) target = TranscriptLines.targetChars(TranscriptLines.headWindow(words, i));
      // 需要补空格时**把空格折进 text**,以维持"拼接 == 整句"的不变式
      const text = (wantSpace && len > 0) ? ' ' + w.text : w.text;
      buf.push({ text: text, startMs: w.startMs, endMs: w.endMs } as TranscribedWord);
      len += text.length;

      const trimmed = text.replace(/\s+$/, '');
      const endsSentence = trimmed.length > 0
        && TranscriptLines.isSentenceEnd(trimmed.charAt(trimmed.length - 1));
      const gapNext = i + 1 < words.length ? words[i + 1].startMs - w.endMs : 0;
      // 下一条是标点时先别断:否则它就成了下一行的第一个字(中文排版不允许)
      const nextIsPunct = i + 1 < words.length && TranscriptLines.isPunctOnly(words[i + 1].text);

      if (endsSentence || gapNext > TranscriptLines.MAX_GAP_MS || (len >= target && !nextIsPunct)) {
        out.push(TranscriptLines.flush(buf));
        buf = [];
        len = 0;
      }
    }
    if (buf.length > 0) out.push(TranscriptLines.flush(buf));
    return TranscriptLines.fitLines(TranscriptLines.glueOrphans(out));
  }

  /**
   * 最后一道闸:**任何一条都必须画得进它自己那一行**。
   *
   * 前两道(按字宽折算、`headWindow` 取样)都只能拿到"一行开头"的信息:引擎一次吐出整句、
   * 或一行开头是一长串英文时,`headWindow` 那 18 个字符会被英文占满,整行汉字占多数的稿
   * 也会被判成西文 38 字 —— 上屏照样折两行(2026-11-13 本端装机实测:
   * 「亿美元今年 open a i 一度在部分收入指标上落后于 anropic 彭」38 字,第二行 6 个字)。
   * 这里按**整行**重判一次,超了就切;切出来的碎片不带词级时间 —— 那一行退化为行级高亮,
   * 好过在屏幕上折出第二行。
   */
  private static fitLines(lines: TranscribedSegment[]): TranscribedSegment[] {
    const fitted: TranscribedSegment[] = [];
    for (let i = 0; i < lines.length; i++) {
      const seg = lines[i];
      if (seg.text.length <= TranscriptLines.targetChars(seg.text) + TranscriptLines.GLUE_OVERHANG) {
        fitted.push(seg);
      } else {
        const pieces = TranscriptLines.split(seg.text, seg.startMs, seg.endMs);
        for (let k = 0; k < pieces.length; k++) fitted.push(pieces[k]);
      }
    }
    return fitted;
  }

  /**
   * 只由标点组成的条目(「，」「。」「……」这种)。
   *
   * 断行时它们**必须黏在前一行尾部**,原因有两条,都是 2026-11-13 在 Android 装机时看见的:
   * ① 中文排版不允许一行以「，」起头 —— 长度到点那一刻正好轮到一个逗号,屏幕上就是
   * 下一段以逗号开头;② 标点还占一个字宽,甩到新行会白白吃掉下一行的容量。
   */
  static isPunctOnly(s: string): boolean {
    if (s.length === 0) return false;
    for (let i = 0; i < s.length; i++) {
      if (TranscriptLines.PUNCT_ONLY.indexOf(s.charAt(i)) < 0) return false;
    }
    return true;
  }

  private static readonly PUNCT_ONLY: string = '，。、；：！？…—,.!?;:)）」。』》”’"';

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
