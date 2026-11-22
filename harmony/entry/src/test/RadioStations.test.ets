import { describe, it, expect } from '@ohos/hypium';
import { Station, StationMeta } from '../main/ets/model/Station';
import { StationJson } from '../main/ets/store/StationStore';
import { RadioBrowserSource } from '../main/ets/net/RadioBrowserSource';

/**
 * 电台的纯逻辑判据(不碰 UI、不读 rawfile、不发网络请求):
 *  - 七键编解码与 Android `StationJson` 同一套键名;
 *  - 缺 `id` / `name` / `source` 时的确定兜底;
 *  - 目录解析:优先 `url_resolved`、`lastcheckok=0` 剔除、空名/空地址剔除、同地址去重。
 *
 * 与 Android `StationJsonTest` / `RadioBrowserSourceTest` 同一组断言 —— 两端对同一份
 * `reverb-backup.json` 与同一份目录响应必须得到同一组电台。
 */
export default function radioStationsTest(): void {
  describe('RadioStations', () => {

    it('七键往返逐字一致', 0, () => {
      const s: Station = {
        id: 'local:1', name: '测试电台', url: 'https://example.com/live.mp3',
        logo: 'https://example.com/a.png', group: 'music', country: 'CN',
        source: StationMeta.SOURCE_MANUAL
      };
      const back = StationJson.fromJson(StationJson.toJson(s)) as Station;
      expect(back.id).assertEqual(s.id);
      expect(back.name).assertEqual(s.name);
      expect(back.url).assertEqual(s.url);
      expect(back.logo).assertEqual(s.logo);
      expect(back.group).assertEqual(s.group);
      expect(back.country).assertEqual(s.country);
      expect(back.source).assertEqual(s.source);
    });

    it('地址为空的不收', 0, () => {
      expect(StationJson.fromJson({
        'id': 'x', 'name': '空地址', 'url': '   '
      } as Record<string, Object>) === null).assertTrue();
    });

    it('缺 id/name/source 时确定兜底', 0, () => {
      const s = StationJson.fromJson({
        'url': 'https://example.com/a.m3u8'
      } as Record<string, Object>) as Station;
      expect(s.id).assertEqual('local:https://example.com/a.m3u8');
      expect(s.name).assertEqual('https://example.com/a.m3u8');
      expect(s.source).assertEqual(StationMeta.SOURCE_MANUAL);
    });

    it('未知分组归为未分组', 0, () => {
      expect(StationMeta.normalizeGroup('News')).assertEqual('news');
      expect(StationMeta.normalizeGroup('unknown')).assertEqual('');
      expect(StationMeta.normalizeGroup('')).assertEqual('');
    });

    it('目录解析:优先 url_resolved 且剔除不可用条目', 0, () => {
      const text = JSON.stringify([
        { 'stationuuid': 'a', 'name': '一台', 'url': 'https://a/old', 'url_resolved': 'https://a/new',
          'favicon': 'https://a/i.png', 'country': 'China', 'lastcheckok': 1 },
        { 'stationuuid': 'b', 'name': '坏台', 'url': 'https://b/x', 'lastcheckok': 0 },
        { 'stationuuid': 'c', 'name': '', 'url': 'https://c/x', 'lastcheckok': 1 },
        { 'stationuuid': 'd', 'name': '四台', 'url': 'https://d/x', 'lastcheckok': 1 },
        { 'stationuuid': 'e', 'name': '重复地址', 'url': 'https://d/x', 'lastcheckok': 1 }
      ]);
      const list = RadioBrowserSource.parse(text);
      expect(list.length).assertEqual(2);
      expect(list[0].id).assertEqual('rb:a');
      expect(list[0].url).assertEqual('https://a/new');
      expect(list[0].source).assertEqual(StationMeta.SOURCE_DIRECTORY);
      expect(list[1].id).assertEqual('rb:d');
    });

    it('目录响应不是数组时给空', 0, () => {
      expect(RadioBrowserSource.parse('{}').length).assertEqual(0);
      expect(RadioBrowserSource.parse('not json').length).assertEqual(0);
    });
  });
}
