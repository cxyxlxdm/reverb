import { describe, it, expect } from '@ohos/hypium';
import { Episode, TranscribedSegment } from '../main/ets/model/Models';
import { TranscriptSearch } from '../main/ets/util/TranscriptSearch';
import { TranscriptExport, TranscriptFormat } from '../main/ets/util/TranscriptExport';

/**
 * 搜索与导出是纯逻辑,判据与 Android `TranscriptExportTest`、macOS
 * `TranscriptSearchExportTests` **同一套**:同一段稿必须给出相同的命中句、相同的区间、
 * 逐字节相同的导出文本 —— 三端任何一个对不上,跨端核对就失去基本单位。
 */
function seg(text: string, startMs: number, endMs: number): TranscribedSegment {
  return { text: text, startMs: startMs, endMs: endMs, words: [] } as TranscribedSegment;
}

function episode(title: string, channel: string): Episode {
  return {
    id: 'ep1', title: title, description: '', audioUrl: 'https://example.com/a.mp3',
    artworkUrl: '', podcastTitle: channel, durationSec: 0, pubDate: '', feedUrl: '',
    transcriptUrl: '', transcriptType: '', chaptersUrl: '', chaptersType: ''
  } as Episode;
}

export default function transcriptSearchExportTest(): void {
  describe('TranscriptSearchExport', () => {

    it('大小写不敏感,跨句给出同一组区间', 0, () => {
      const r = TranscriptSearch.find([
        seg('Hello world', 0, 5000),
        seg('nothing here', 5000, 9000),
        seg('另一个 PODCAST 与 podcast', 9000, 12000)
      ], 'podcast');
      expect(r.hits.length).assertEqual(1);
      expect(r.hits[0].index).assertEqual(2);
      expect(r.hits[0].ranges.length).assertEqual(2);
      expect(r.hits[0].ranges[0].start).assertEqual(4);
      expect(r.hits[0].ranges[0].end).assertEqual(11);
      expect(r.hits[0].ranges[1].start).assertEqual(14);
      expect(r.hits[0].ranges[1].end).assertEqual(21);
    });

    it('空查询不命中', 0, () => {
      expect(TranscriptSearch.find([seg('hello', 0, 1000)], '').hits.length).assertEqual(0);
    });

    it('重叠命中不重复计数', 0, () => {
      const rs = TranscriptSearch.rangesIn('aaaa', 'aa');
      expect(rs.length).assertEqual(2);
      expect(rs[0].start).assertEqual(0);
      expect(rs[1].start).assertEqual(2);
    });

    it('纯文本逐字节对照', 0, () => {
      const out = TranscriptExport.build(
        episode('Ep', 'Ch'),
        [seg('第一句', 0, 3000), seg('第二句', 5000, 7000)],
        TranscriptFormat.Text);
      expect(out).assertEqual('Ep\nCh\n\n[0:00] 第一句\n[0:05] 第二句\n');
    });

    it('Markdown 逐字节对照', 0, () => {
      const out = TranscriptExport.build(episode('Ep', 'Ch'), [seg('Hello', 0, 2000)], TranscriptFormat.Markdown);
      expect(out).assertEqual('# Ep\n\n_Ch_\n\n- [0:00] Hello\n');
    });

    it('超过一小时的整篇才写小时位', 0, () => {
      expect(TranscriptExport.stamp(65000, false)).assertEqual('1:05');
      expect(TranscriptExport.stamp(3725000, true)).assertEqual('1:02:05');
      expect(TranscriptExport.stamp(-5, false)).assertEqual('0:00');
      const out = TranscriptExport.build(
        episode('Ep', ''),
        [seg('a', 0, 1000), seg('b', 3700000, 3705000)],
        TranscriptFormat.Text);
      expect(out.indexOf('[0:00:00] a') >= 0).assertTrue();
      expect(out.indexOf('[1:01:40] b') >= 0).assertTrue();
    });

    it('换行折叠,空标题回退', 0, () => {
      expect(TranscriptExport.build(episode('  \n ', ''), [], TranscriptFormat.Text)).assertEqual('Transcript\n\n');
      expect(TranscriptExport.fileName(episode('上\n下', 'Ch'), TranscriptFormat.Text)).assertEqual('上 下.txt');
    });

    it('文件名去掉路径分隔符', 0, () => {
      expect(TranscriptExport.fileName(episode('a/b\\c:d*e?f"g<h>i|j', ''), TranscriptFormat.Text))
        .assertEqual('a b c d e f g h i j.txt');
      expect(TranscriptExport.fileName(episode('', ''), TranscriptFormat.Markdown)).assertEqual('transcript.md');
    });
  });
}
