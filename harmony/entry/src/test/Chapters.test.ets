import { describe, it, expect } from '@ohos/hypium';
import { ChaptersFetcher } from '../main/ets/net/ChaptersFetcher';
import { Chapter } from '../main/ets/model/Models';

/**
 * 章表解析(纯逻辑,不发请求)。与 Android `ChaptersFetcherTest` 同一组判据:
 * 两种时间写法、包装/裸数组、「失败」与「空」分开、以及数据出口必须保证的
 * **严格递增 + ≥0**(硬规矩 10 —— 界面靠这个不变式找当前章)。
 */
export default function chaptersTest(): void {
  describe('ChaptersFetcher', () => {

    it('包装对象:startTime 秒、排序、去重、夹零、丢无标题', 0, () => {
      const text = '{ "version": "1.2.0", "chapters": ['
        + '{ "startTime": 120, "title": "B" },'
        + '{ "startTime": 30.5, "title": "A" },'
        + '{ "startTime": 120, "title": "B 重复" },'
        + '{ "startTime": -5, "title": "夹到零" },'
        + '{ "startTime": 240, "title": "   " }'
        + '] }';
      const list = ChaptersFetcher.parse(text);
      expect(list === null).assertFalse();
      const c = list as Chapter[];
      expect(c.length).assertEqual(3);
      expect(c[0].startMs).assertEqual(0);
      expect(c[0].title).assertEqual('夹到零');
      expect(c[1].startMs).assertEqual(30500);
      expect(c[1].title).assertEqual('A');
      expect(c[2].startMs).assertEqual(120000);
      expect(c[2].title).assertEqual('B');
    });

    it('裸数组:start 时间串与 img / image 两种封面键', 0, () => {
      const text = '['
        + '{ "start": "00:01:23.500", "title": "X", "img": "i" },'
        + '{ "start": "4:5", "title": "Y", "image": "j" }'
        + ']';
      const c = ChaptersFetcher.parse(text) as Chapter[];
      expect(c.length).assertEqual(2);
      expect(c[0].startMs).assertEqual(83500);
      expect(c[0].imageUrl).assertEqual('i');
      expect(c[1].startMs).assertEqual(245000);
      expect(c[1].imageUrl).assertEqual('j');
    });

    it('startTime 是数字串也认,纯秒数不带冒号', 0, () => {
      const c = ChaptersFetcher.parse('[{ "startTime": "12.25", "title": "A" }]') as Chapter[];
      expect(c.length).assertEqual(1);
      expect(c[0].startMs).assertEqual(12250);
    });

    it('失败与空分开:没有 chapters 键是空表,不是章表则 null', 0, () => {
      const empty = ChaptersFetcher.parse('{ "version": "1.2.0" }');
      expect(empty === null).assertFalse();
      expect((empty as Chapter[]).length).assertEqual(0);
      const bad = ChaptersFetcher.parse('这不是 JSON');
      expect(bad === null).assertTrue();
    });

    it('没有 start 的章被跳过;url 原样保留', 0, () => {
      const c = ChaptersFetcher.parse(
        '[{ "title": "无时间" }, { "startTime": 3, "title": "有", "url": "https://e/x" }]'
      ) as Chapter[];
      expect(c.length).assertEqual(1);
      expect(c[0].title).assertEqual('有');
      expect(c[0].url).assertEqual('https://e/x');
    });
  });
}
