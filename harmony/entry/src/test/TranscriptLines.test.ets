import { describe, it, expect } from '@ohos/hypium';
import { TranscribedSegment, TranscribedWord } from '../main/ets/model/Models';
import { TranscriptLines } from '../main/ets/util/TranscriptLines';

/**
 * 逐字稿时间轴的**不变式**。三端同一份判据(Android `TranscriptLinesTest`、macOS
 * `TranscriptLinesTests`):起点非负且单调不减、终点不早于起点、`words` 拼接等于整句。
 *
 * 这条之所以必须逐端都测:渲染侧找"当前词"用的是「从后往前第一个 startMs <= now」,
 * 队尾一个回退值就会让高亮钉死(见 TROUBLESHOOTING H60)。
 */
function word(text: string, startMs: number, endMs: number): TranscribedWord {
  return { text: text, startMs: startMs, endMs: endMs } as TranscribedWord;
}

export default function transcriptLinesTest(): void {
  describe('TranscriptLines', () => {

    it('行宽按中西文分流', 0, () => {
      expect(TranscriptLines.targetChars('中文内容')).assertEqual(TranscriptLines.CJK_CHARS);
      expect(TranscriptLines.targetChars('hello world')).assertEqual(TranscriptLines.WEST_CHARS);
      expect(TranscriptLines.targetChars('')).assertEqual(TranscriptLines.WEST_CHARS);
    });

    it('isAsciiHead 只认 ASCII 起头', 0, () => {
      expect(TranscriptLines.isAsciiHead('abc')).assertTrue();
      expect(TranscriptLines.isAsciiHead('中文')).assertFalse();
      expect(TranscriptLines.isAsciiHead('')).assertFalse();
    });

    it('起点回退时被夹成单调不减,终点不早于起点', 0, () => {
      const out = TranscriptLines.monotonic([
        word('a', 0, 100), word('b', 50, 200), word('c', 40, 60)
      ]);
      expect(out.length).assertEqual(3);
      expect(out[0].startMs).assertEqual(0);
      expect(out[1].startMs).assertEqual(50);
      // 40 回退到上一词的 50;终点 60 仍不早于起点
      expect(out[2].startMs).assertEqual(50);
      expect(out[2].endMs).assertEqual(60);
    });

    it('负数起点从零起算', 0, () => {
      const out = TranscriptLines.monotonic([word('a', -5, 10), word('b', 20, 30)]);
      expect(out[0].startMs).assertEqual(0);
      expect(out[0].endMs).assertEqual(10);
      expect(out[1].startMs).assertEqual(20);
    });

    it('本来就单调的输入原样返回(不复制)', 0, () => {
      const words = [word('a', 0, 10), word('b', 10, 20)];
      const out = TranscriptLines.monotonic(words);
      expect(out === words).assertTrue();
    });

    it('mergeWords:words 拼接等于整句(自带空格)', 0, () => {
      const segs: TranscribedSegment[] = TranscriptLines.mergeWords(
        [word('Hello', 0, 100), word('world', 100, 200), word('again', 200, 300)], true);
      expect(segs.length).assertEqual(1);
      expect(segs[0].text).assertEqual('Hello world again');
      let joined = '';
      for (let i = 0; i < segs[0].words.length; i++) joined += segs[0].words[i].text;
      expect(joined).assertEqual(segs[0].text);
    });

    it('mergeWords:中文不补空格', 0, () => {
      const segs: TranscribedSegment[] = TranscriptLines.mergeWords(
        [word('你', 0, 100), word('好', 100, 200)], true);
      expect(segs[0].text).assertEqual('你好');
    });

    it('split:短句原样返回', 0, () => {
      const segs = TranscriptLines.split('短句', 0, 1000);
      expect(segs.length).assertEqual(1);
      expect(segs[0].startMs).assertEqual(0);
      expect(segs[0].endMs).assertEqual(1000);
    });

    it('split:长句按时长比例切开,首尾对齐', 0, () => {
      let text = '';
      for (let i = 0; i < 8; i++) text += '这是一句用来测试断句的话。';
      const segs = TranscriptLines.split(text, 1000, 6000);
      expect(segs.length > 1).assertTrue();
      expect(segs[0].startMs).assertEqual(1000);
      expect(segs[segs.length - 1].endMs).assertEqual(6000);
      let chars = 0;
      for (let i = 0; i < segs.length; i++) {
        expect(segs[i].endMs >= segs[i].startMs).assertTrue();
        chars += segs[i].text.length;
      }
      // 中文无空格,切分只可能因 trim 丢字 —— 这里期望一个字都不丢
      expect(chars).assertEqual(text.length);
    });

    /**
     * 行宽是**跨端共用的尺子**,而且必须比一台手机真能放下的字数小两格 ——
     * 等于容量就是"每条都刚好溢出",屏幕上就是"一行铺满 + 下一行一个字"(见 H280)。
     */
    it('行宽是共用尺子', 0, () => {
      expect(TranscriptLines.CJK_CHARS).assertEqual(18);
      expect(TranscriptLines.WEST_CHARS).assertEqual(38);
      expect(TranscriptLines.targetChars('这是一段中文')).assertEqual(18);
      expect(TranscriptLines.targetChars('this is english')).assertEqual(38);
    });

    it('24 个汉字断成两条,每条都放得进一行', 0, () => {
      const ws: TranscribedWord[] = [];
      let text = '';
      for (let i = 0; i < 24; i++) {
        ws.push(word('字', i * 100, i * 100 + 90));
        text += '字';
      }
      const segs: TranscribedSegment[] = TranscriptLines.mergeWords(ws, false);
      expect(segs.length >= 2).assertTrue();
      let joined = '';
      for (let i = 0; i < segs.length; i++) {
        expect(segs[i].text.length <= TranscriptLines.CJK_CHARS).assertTrue();
        joined += segs[i].text;
      }
      expect(joined).assertEqual(text);
    });

    /**
     * 长度是**加之前**判的:一条 3 个字的词卡在边界上时,旧写法会产出 21 字
     * (18 加完再看),而 Android 正文一行只放得下 20 个 —— 21 字就是"一行铺满 + 下一行一个字"。
     */
    it('多字词不会把一行顶过目标字数', 0, () => {
      const ws: TranscribedWord[] = [];
      for (let i = 0; i < 8; i++) ws.push(word('三个字', i * 500, i * 500 + 400));
      const segs: TranscribedSegment[] = TranscriptLines.mergeWords(ws, false);
      for (let i = 0; i < segs.length; i++) {
        expect(segs[i].text.length <= TranscriptLines.CJK_CHARS).assertTrue();
      }
    });

    /// 中文排版不允许一行以「，」起头:长度到点那一刻正好轮到逗号时,逗号要黏在上一行尾。
    it('标点不落到行首', 0, () => {
      const ws: TranscribedWord[] = [];
      for (let i = 0; i < 18; i++) ws.push(word('字', i * 100, i * 100 + 90));
      ws.push(word('，', 1800, 1900));
      for (let i = 0; i < 6; i++) ws.push(word('后', 2000 + i * 100, 2050 + i * 100));
      const segs: TranscribedSegment[] = TranscriptLines.mergeWords(ws, false);
      for (let i = 0; i < segs.length; i++) {
        expect(TranscriptLines.isPunctOnly(segs[i].text.charAt(0))).assertFalse();
      }
      expect(segs[0].text.endsWith('，')).assertTrue();
    });

    /**
     * 27 字的 cue 早先整条进稿(`split` 的提前返回放宽到 1.5 倍行宽),上屏折成两行、
     * 第二行只剩几个字 —— 与"一行铺满 + 下一行一个字"同一个形状(H280)。
     */
    it('超一行的整条稿必被切开', 0, () => {
      const text = '这是一句刚好超过一行的稿件内容用来验证切分';
      expect(text.length > TranscriptLines.CJK_CHARS).assertTrue();
      const segs = TranscriptLines.split(text, 0, 1000);
      expect(segs.length >= 2).assertTrue();
      let joined = '';
      for (let i = 0; i < segs.length; i++) {
        expect(segs[i].text.length <= TranscriptLines.CJK_CHARS).assertTrue();
        joined += segs[i].text;
      }
      expect(joined).assertEqual(text);
    });

    /// 中英混排里汉字不到一半,但按字宽折算已超过一行 —— 按西文的 38 切就会折行。
    it('中英混排按字宽折算选中文行宽', 0, () => {
      const mixed = '元今年 open a i 一度在部分收入指标上落后于 anropic 彭';
      let cjk = 0;
      for (let i = 0; i < mixed.length; i++) {
        const c = mixed.charCodeAt(i);
        if ((c >= 0x3400 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF)) cjk++;
      }
      expect(cjk * 2 < mixed.length).assertTrue();
      expect(TranscriptLines.targetChars(mixed)).assertEqual(TranscriptLines.CJK_CHARS);
    });

    /**
     * 首条是「4分之1。」这种混排小条目时,行宽不能只看它 —— 单看首条会判成西文 38 字,
     * 同一行后面再接汉字就撑到 25 字,上屏折两行(2026-11-13 Android 装机实测)。
     */
    it('首条是混排数字时行宽仍按中文', 0, () => {
      const texts = ['4分之1。', '另外，', '面对签约运动员姆巴佩引发的', '争议，', '昂跑联席CEO表示，'];
      const ws: TranscribedWord[] = [];
      for (let i = 0; i < texts.length; i++) ws.push(word(texts[i], i * 100, i * 100 + 90));
      const segs = TranscriptLines.mergeWords(ws, false);
      for (let i = 0; i < segs.length; i++) {
        expect(segs[i].text.length <= TranscriptLines.CJK_CHARS + TranscriptLines.GLUE_OVERHANG).assertTrue();
      }
    });

    /// 行首 18 个字符被英文占满时,`headWindow` 会把整行判成西文 38 字,于是一条 38 字的混排行
    /// 上屏折两行(2026-11-13 鸿蒙装机实测)。`fitLines` 按整行重判后必须切开。
    it('行首是长串英文的混排行仍被切开', 0, () => {
      const texts = ['亿美元今年', ' open a i ', '一度在部分收入指标上落后于', ' anropic 彭'];
      const ws: TranscribedWord[] = [];
      for (let i = 0; i < texts.length; i++) ws.push(word(texts[i], i * 100, i * 100 + 90));
      const segs = TranscriptLines.mergeWords(ws, false);
      for (let i = 0; i < segs.length; i++) {
        expect(segs[i].text.length <= TranscriptLines.CJK_CHARS + TranscriptLines.GLUE_OVERHANG).assertTrue();
      }
    });

    /// 旧判据"碎片不足 12 字就并"会并出 29 字,换行后第二行只剩孤字。
    it('并句不会并出一行放不下的段落', 0, () => {
      const prev: TranscribedSegment =
        { text: '甲'.repeat(18), startMs: 0, endMs: 1000, words: [] } as TranscribedSegment;
      const tail: TranscribedSegment =
        { text: '乙'.repeat(11), startMs: 1100, endMs: 2000, words: [] } as TranscribedSegment;
      expect(TranscriptLines.glueOrphans([prev, tail]).length).assertEqual(2);
    });
  });
}
