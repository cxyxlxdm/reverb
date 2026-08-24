import { Http } from './Http';
import { TranscribedSegment, TranscribedWord } from '../model/Models';
import { TranscriptLines } from '../util/TranscriptLines';
import { Log } from '../util/Logger';

/**
 * 取**发布方自己提供的逐字稿**并解析成句子(RSS 的 `podcast:transcript`,Podcasting 2.0)。
 * 对应 Android `data/remote/TranscriptFetcher.kt`,三种格式与断行规则逐条对齐。
 *
 * 为什么这条路优先于系统识别:时间轴是发布方给的,又准又免费又省电;JSON 格式的稿更是
 * **一词一条自带词级时间**,逐字高亮的效果比任何本机识别都好。
 *
 * 支持 **SRT / WebVTT / Podcast Index JSON** 三种。**先按内容嗅探,再看声明的 type** ——
 * 实际的 feed 里 type 写错的不少(把 VTT 标成 `text/plain`、把 JSON 标成 `application/srt`),
 * 而这三种格式的开头特征很好认,嗅探比信声明可靠。
 */
export class TranscriptFetcher {

  /// 稿文件的大小上限。8 MB 已经是一集几万字的量级,再大八成是拿错了东西(网页/播放列表)
  private static readonly MAX_BYTES: number = 8 * 1024 * 1024;
  private static readonly TAG: string = 'Transcript';

  /**
   * @returns 解析好的句子;取不到或解析不出来返回空数组(调用方据此回退系统识别)
   */
  static async fetch(url: string, declaredType: string): Promise<TranscribedSegment[]> {
    if (url.length === 0) return [];
    const body = await Http.text(url);
    if (body === null || body.length === 0) {
      Log.w(TranscriptFetcher.TAG, `官方稿取不到 url=${url}`);
      return [];
    }
    if (body.length > TranscriptFetcher.MAX_BYTES) {
      Log.w(TranscriptFetcher.TAG, `官方稿过大(${body.length} 字节),不用`);
      return [];
    }
    const head = body.replace(/^﻿/, '').replace(/^\s+/, '');
    let segs: TranscribedSegment[] = [];
    if (head.startsWith('{') || head.startsWith('[')) {
      segs = TranscriptFetcher.parseJson(head);
    } else if (head.startsWith('WEBVTT')) {
      segs = TranscriptFetcher.parseCues(head);
    } else if (declaredType.toLowerCase().indexOf('json') >= 0) {
      segs = TranscriptFetcher.parseJson(head);
    } else {
      // 剩下的按 SRT/VTT 的 cue 结构解 —— 两者的时间行只差一个分隔符,同一个解析器能吃
      segs = TranscriptFetcher.parseCues(head);
    }
    Log.i(TranscriptFetcher.TAG, `官方稿解析出 ${segs.length} 句 url=${url}`);
    return segs;
  }

  /**
   * SRT / WebVTT。两者的差别只在时间行的小数分隔符(`,` vs `.`)与可选的序号行/头部,
   * 所以共用一个解析器。
   *
   * cue 可以长到几百字(整段独白一个 cue),所以每个 cue 还要**再按屏宽切**
   * (`TranscriptLines.split`),否则一行文字在屏幕上高亮二十多秒,跟读等于没有。
   */
  private static parseCues(body: string): TranscribedSegment[] {
    const lines = body.split(/\r?\n/);
    const out: TranscribedSegment[] = [];
    let i = 0;
    while (i < lines.length) {
      const line = lines[i].trim();
      const arrow = line.indexOf('-->');
      if (arrow < 0) { i++; continue; }
      const startMs = TranscriptFetcher.parseClock(line.substring(0, arrow));
      // 终点后面可能跟着 VTT 的排版参数(`align:start position:0%`),按空白截断
      let tail = line.substring(arrow + 3).trim();
      const sp = tail.search(/\s/);
      if (sp > 0) tail = tail.substring(0, sp);
      const endMs = TranscriptFetcher.parseClock(tail);
      if (startMs < 0 || endMs < 0) { i++; continue; }

      // 时间行之后到空行为止都是文本
      let text = '';
      i++;
      while (i < lines.length && lines[i].trim().length > 0) {
        const piece = TranscriptFetcher.cleanCueText(lines[i].trim());
        if (piece.length > 0) text += (text.length > 0 ? ' ' : '') + piece;
        i++;
      }
      if (text.length === 0) continue;
      const pieces = TranscriptLines.split(text, startMs, Math.max(endMs, startMs));
      for (let k = 0; k < pieces.length; k++) out.push(pieces[k]);
    }
    return TranscriptLines.glueOrphans(out);
  }

  /**
   * 去掉 cue 文本里的标注,只留实际说的话:
   * - VTT 的说话人标签 `<v Alice>` 与其它内联标签;
   * - `SPEAKER_01:` 这种自动生成的说话人前缀 —— 逐字稿里满屏 SPEAKER_00/01 很吵,
   *   而且它不是被说出来的内容,跟读时高亮到它就对不上了。
   */
  private static cleanCueText(s: string): string {
    let t = s.replace(/<[^>]*>/g, '');
    t = t.replace(/^SPEAKER_?\d+\s*:\s*/i, '');
    return t.trim();
  }

  /**
   * `HH:MM:SS,mmm` / `MM:SS.mmm` / `HH:MM:SS` → 毫秒。解析不出来返回 -1。
   * 小时段可省(VTT 允许),所以按冒号分段数决定怎么读。
   */
  private static parseClock(raw: string): number {
    const s = raw.trim().replace(',', '.');
    if (s.length === 0) return -1;
    const parts = s.split(':');
    if (parts.length < 2 || parts.length > 3) return -1;
    let h = 0;
    let m = 0;
    let secStr = '';
    if (parts.length === 3) {
      h = Number.parseInt(parts[0], 10);
      m = Number.parseInt(parts[1], 10);
      secStr = parts[2];
    } else {
      m = Number.parseInt(parts[0], 10);
      secStr = parts[1];
    }
    const sec = Number.parseFloat(secStr);
    if (Number.isNaN(h) || Number.isNaN(m) || Number.isNaN(sec)) return -1;
    return Math.round(((h * 60 + m) * 60 + sec) * 1000);
  }

  /**
   * Podcast Index JSON:`{ version, segments: [{ startTime, endTime, body, speaker? }] }`,
   * 时间是**秒(浮点)**。
   *
   * 这种稿通常**一条一个词**(实测一集 10245 条),直接显示会是一屏碎字,所以交给
   * `TranscriptLines.mergeWords` 合成可读的一行、并把原始条目留在 `words` 里 ——
   * 于是既好读,又有词级时间可以逐词高亮。`spaced = true`:条目自己不带空格,按 ASCII 规则补。
   */
  private static parseJson(body: string): TranscribedSegment[] {
    try {
      const root: Object = JSON.parse(body) as Object;
      let arr: Object[] | null = null;
      if (Array.isArray(root)) {
        arr = root as Object[];
      } else {
        const obj = root as Record<string, Object>;
        const segs = obj['segments'];
        if (Array.isArray(segs)) arr = segs as Object[];
      }
      if (arr === null) return [];

      const words: TranscribedWord[] = [];
      for (let i = 0; i < arr.length; i++) {
        const o = arr[i] as Record<string, Object>;
        if (o === null || o === undefined) continue;
        const text = TranscriptFetcher.pickString(o, ['body', 'text', 'word']);
        if (text.length === 0) continue;
        const st = TranscriptFetcher.pickSeconds(o, ['startTime', 'start', 'startMs']);
        const en = TranscriptFetcher.pickSeconds(o, ['endTime', 'end', 'endMs']);
        if (st < 0) continue;
        words.push({
          text: text,
          startMs: st,
          endMs: en < st ? st : en
        } as TranscribedWord);
      }
      if (words.length === 0) return [];
      return TranscriptLines.mergeWords(words, true);
    } catch (e) {
      Log.w(TranscriptFetcher.TAG, `官方稿 JSON 解析失败:${e}`);
      return [];
    }
  }

  private static pickString(o: Record<string, Object>, keys: string[]): string {
    for (let i = 0; i < keys.length; i++) {
      const v = o[keys[i]];
      if (typeof v === 'string') return (v as string).trim();
    }
    return '';
  }

  /**
   * 取时间并统一成毫秒。`*Ms` 结尾的键当毫秒,其它当**秒(可能是浮点)**。
   * 取不到返回 -1。
   */
  private static pickSeconds(o: Record<string, Object>, keys: string[]): number {
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = o[k];
      if (typeof v === 'number') {
        const n = v as number;
        return k.endsWith('Ms') ? Math.round(n) : Math.round(n * 1000);
      }
      if (typeof v === 'string') {
        const n = Number.parseFloat(v as string);
        if (!Number.isNaN(n)) return k.endsWith('Ms') ? Math.round(n) : Math.round(n * 1000);
      }
    }
    return -1;
  }
}
