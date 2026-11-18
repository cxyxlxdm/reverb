import { describe, it, expect } from '@ohos/hypium';
import { LanSyncLive, LanPlaybackStatus, LanClockEstimator, LanClockSample } from '../main/ets/sync/LanSyncLive';
import { Episode } from '../main/ets/model/Models';

/**
 * 播放交接的纯判据(不起 socket、不碰播放器)。
 *
 * 与 Android `LanSyncLiveTest` / Apple `LanSyncLiveTest` 同一组断言:时钟样本、交接位置、
 * 状态帧的字段口径。真正的"先暂停再开播"顺序由 Android / Apple 两侧的通道测试覆盖,
 * 鸿蒙这边的收发链要真机两台设备才验得了(清单在 docs/ROADMAP.md)。
 */
function episode(title: string, description: string): Episode {
  return {
    id: 'ep-1',
    title: title,
    description: description,
    audioUrl: 'https://example.com/a.mp3',
    artworkUrl: 'https://example.com/a.jpg',
    podcastTitle: '频道',
    durationSec: 600,
    pubDate: '2026-11-01T00:00:00Z',
    feedUrl: 'https://example.com/feed.xml',
    transcriptUrl: '',
    transcriptType: '',
    chaptersUrl: '',
    chaptersType: ''
  };
}

export default function lanSyncLiveTest(): void {
  describe('LanSyncLive', () => {

    it('时钟样本取的是往返的一半', 0, () => {
      // t0=1000 本机发, t1=1350 对端收, t2=1450 对端发, t3=1200 本机收
      const s = LanClockEstimator.sample(1000, 1350, 1450, 1200);
      expect(s === null).assertFalse();
      const sample = s as LanClockSample;
      expect(sample.rttMs).assertEqual(100);
      // ((t1-t0) + (t2-t3)) / 2 = (350 + 250) / 2 = 300
      expect(sample.offsetMs).assertEqual(300);
    });

    it('垃圾时钟样本不采信', 0, () => {
      // 对端说自己在 1000ms 才收,而本机 200ms 就收到了 → 负往返
      expect(LanClockEstimator.sample(0, 100, 1000, 200) === null).assertTrue();
      // 往返超过 2 秒
      expect(LanClockEstimator.sample(0, 100, 1100, 5000) === null).assertTrue();
    });

    it('中位数', 0, () => {
      expect(LanClockEstimator.median([])).assertEqual(0);
      expect(LanClockEstimator.median([3, 1, 2])).assertEqual(2);
      expect(LanClockEstimator.median([4, 1, 3, 2])).assertEqual(2.5);
    });

    it('两组样本才可用且只留最近五组', 0, () => {
      const e = new LanClockEstimator();
      expect(e.usable).assertFalse();
      for (let i = 1; i <= 6; i++) {
        e.add(LanClockEstimator.sample(0, i * 10, i * 10 + 100, 100) as LanClockSample);
      }
      expect(e.usable).assertTrue();
      // 偏移是 i×10(10..60),丢掉第一组后 20..60 的中位数是 40
      expect(e.offsetMs).assertEqual(40);
      expect(e.rttMs).assertEqual(0);
    });

    it('交接位置加的是往返的一半', 0, () => {
      expect(LanSyncLive.handoffPosition(60000, 400, 1.0, 600000)).assertEqual(60200);
      // 2 倍速时,同样的往返会多走一倍
      expect(LanSyncLive.handoffPosition(60000, 400, 2.0, 600000)).assertEqual(60400);
    });

    it('交接位置在结尾前留一秒半', 0, () => {
      expect(LanSyncLive.handoffPosition(599000, 400, 1.0, 600000)).assertEqual(598500);
      // 时长不足一秒半时不夹
      expect(LanSyncLive.handoffPosition(0, 0, 1.0, 1000)).assertEqual(0);
    });

    it('交接位置能容忍异常输入', 0, () => {
      expect(LanSyncLive.handoffPosition(-1000, -50, 0, 0)).assertEqual(0);
    });

    it('状态帧往返且不带 shownotes', 0, () => {
      const s = new LanPlaybackStatus();
      s.episode = episode('第一集', '几十 KB 的 shownotes');
      s.positionMs = 61000;
      s.durationMs = 600000;
      s.playing = true;
      s.rate = 1.5;
      s.atMs = 1760000000000;
      const f = s.frame('pb');
      expect(f['t'] as string).assertEqual('pb');
      const ep = f['ep'] as Record<string, Object>;
      expect(ep['description'] as string).assertEqual('');
      expect(ep['id'] as string).assertEqual('ep-1');

      const back = LanPlaybackStatus.parse(f) as LanPlaybackStatus;
      expect(back.positionMs).assertEqual(61000);
      expect(back.durationMs).assertEqual(600000);
      expect(back.playing).assertTrue();
      expect(back.rate).assertEqual(1.5);
      expect(back.atMs).assertEqual(1760000000000);
      const parsedEp = back.episode as Episode;
      expect(parsedEp.title).assertEqual('第一集');
      expect(parsedEp.audioUrl).assertEqual('https://example.com/a.mp3');
    });

    it('没有位置的帧解析成没有状态', 0, () => {
      const f: Record<string, Object> = {};
      f['t'] = 'pb';
      expect(LanPlaybackStatus.parse(f) === null).assertTrue();
    });
  });
}
