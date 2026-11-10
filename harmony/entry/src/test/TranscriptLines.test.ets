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
  });
}
