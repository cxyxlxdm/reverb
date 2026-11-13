import { describe, it, expect } from '@ohos/hypium';
import { SenseVoiceText } from '../main/ets/playback/asr/SenseVoiceText';

/**
 * SenseVoice 的纯文本逻辑。这些判据与 Android `SenseVoiceEngine` / `AsrFactory` 同一份 ——
 * 两端转同一段音频必须得到同一种时间轴与同一套过滤规则。
 *
 * 这里**不碰 native**(不建 recognizer、不读模型):单测跑在构建机上,没有 sherpa 的 .so。
 * 能测的正是「与引擎无关、但错了就会让逐字高亮/断句出错」的那几条。
 */
function pcm16(samples: number[]): Uint8Array {
  const bytes = new Uint8Array(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    const v = samples[i] < 0 ? samples[i] + 65536 : samples[i];
    bytes[i * 2] = v & 0xff;
    bytes[i * 2 + 1] = (v >> 8) & 0xff;
  }
  return bytes;
}

export default function senseVoiceTextTest(): void {
  describe('SenseVoiceText', () => {

    it('engineLanguage:支持的五种语言与大小写/地区后缀', 0, () => {
      expect(SenseVoiceText.engineLanguage('zh-CN')).assertEqual('zh');
      expect(SenseVoiceText.engineLanguage('zh-Hant')).assertEqual('zh');
      // 繁体也走 zh:模型没有输出繁体这个开关(已知限制,见 docs/TRANSCRIPT.md)
      expect(SenseVoiceText.engineLanguage('zh-TW')).assertEqual('zh');
      expect(SenseVoiceText.engineLanguage('en-US')).assertEqual('en');
      expect(SenseVoiceText.engineLanguage('ja-JP')).assertEqual('ja');
      expect(SenseVoiceText.engineLanguage('ko-KR')).assertEqual('ko');
      expect(SenseVoiceText.engineLanguage('yue-HK')).assertEqual('yue');
      expect(SenseVoiceText.engineLanguage('EN')).assertEqual('en');
    });

    it('engineLanguage:法语/西语/空串不在模型支持范围内', 0, () => {
      expect(SenseVoiceText.engineLanguage('fr-FR')).assertEqual('');
      expect(SenseVoiceText.engineLanguage('es-ES')).assertEqual('');
      expect(SenseVoiceText.engineLanguage('')).assertEqual('');
      expect(SenseVoiceText.supports('fr-FR')).assertFalse();
      expect(SenseVoiceText.supports('zh-CN')).assertTrue();
    });

    it('pcm16ToFloat:小端 s16 → [-1,1],奇数字节丢掉尾巴', 0, () => {
      const f = SenseVoiceText.pcm16ToFloat(pcm16([0, 16384, -32768, 32767]));
      expect(f.length).assertEqual(4);
      expect(f[0]).assertEqual(0);
      expect(f[1]).assertEqual(0.5);
      expect(f[2]).assertEqual(-1);
      expect(f[3] > 0.999 && f[3] < 1).assertTrue();

      const odd = new Uint8Array([0, 0, 1]);
      expect(SenseVoiceText.pcm16ToFloat(odd).length).assertEqual(1);
    });

    it('wordsFrom:词级时间轴单调、终点接下一词起点', 0, () => {
      const words = SenseVoiceText.wordsFrom(['你', '好'], [0, 0.5], 1000, 2000);
      expect(words.length).assertEqual(2);
      expect(words[0].text).assertEqual('你');
      expect(words[0].startMs).assertEqual(1000);
      expect(words[0].endMs).assertEqual(1500);
      expect(words[1].startMs).assertEqual(1500);
      expect(words[1].endMs).assertEqual(2000);
      expect(words[1].startMs >= words[0].endMs).assertTrue();
    });

    it('wordsFrom:跳过特殊标记,首尾空格削掉,空文本丢弃', 0, () => {
      const words = SenseVoiceText.wordsFrom(
        ['<|zh|>', ' hello', ' world ', '<|BGM|>'], [0, 0.1, 0.6, 1.0], 0, 1500);
      expect(words.length).assertEqual(2);
      expect(words[0].text).assertEqual('hello');
      // 非首条**保留**前导空格:英文字符拼接时它就是词间那个空格
      expect(words[1].text).assertEqual(' world');
      // 末词终点带的是"下一个 token 的起点"(这里是 BGM 标记的 1.0 秒),不是块尾
      expect(words[1].endMs).assertEqual(1000);
    });

    it('wordsFrom:长度对不上时返回空(坏结果不该造出假时间轴)', 0, () => {
      expect(SenseVoiceText.wordsFrom(['a', 'b'], [0], 0, 1000).length).assertEqual(0);
      expect(SenseVoiceText.wordsFrom([], [], 0, 1000).length).assertEqual(0);
    });

    it('keep:挡掉空串、连续复读与音乐/字幕标记', 0, () => {
      expect(SenseVoiceText.keep('', '')).assertFalse();
      expect(SenseVoiceText.keep('谢谢收听', '谢谢收听')).assertFalse();
      expect(SenseVoiceText.keep('[音乐]', '')).assertFalse();
      expect(SenseVoiceText.keep('（掌声）', '')).assertFalse();
      expect(SenseVoiceText.keep('(字幕:J Chong)', '')).assertFalse();
      expect(SenseVoiceText.keep('这是一句正常的正文', '')).assertTrue();
      // 超过 24 字的括号段不按标记丢:可能是真的正文(与 Android 同一条)
      expect(SenseVoiceText.keep('（这里的括号很长很长很长很长很长很长很长很长很长很长很长很长）', '')).assertTrue();
    });
  });
}
