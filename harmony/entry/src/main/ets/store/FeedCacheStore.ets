import { Episode, Podcast, FeedResult } from '../model/Models';
import { Codec } from './Codec';
import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/// 一条频道缓存:解析结果 + 落缓存时刻(用于「上次更新于」提示与淘汰排序)。
export class FeedCacheEntry {
  podcast: Podcast;
  episodes: Episode[];
  fetchedAt: number;

  constructor(podcast: Podcast, episodes: Episode[], fetchedAt: number) {
    this.podcast = podcast;
    this.episodes = episodes;
    this.fetchedAt = fetchedAt;
  }
}

/// 磁盘表示。ArkTS 不接受无类型对象字面量(arkts-no-untyped-obj-literals),
/// 故显式声明这个中间类,而不是就地写 `{ fetchedAt: …, podcast: … }`。
class StoredFeed {
  fetchedAt: number;
  podcast: Record<string, Object>;
  episodes: Object[];

  constructor(fetchedAt: number, podcast: Record<string, Object>, episodes: Object[]) {
    this.fetchedAt = fetchedAt;
    this.podcast = podcast;
    this.episodes = episodes;
  }
}

/// 频道详情(解析后的 RSS)的磁盘缓存,按 feedUrl。
///
/// 解决两件事:
///  1. **断网可看**:此前进频道详情只能等网络,失败即"加载失败"整页空 —— 哪怕是自己订阅、
///     刚看过的频道也一样。现在先出缓存内容,再后台刷新。
///  2. **秒开**:详情页原本每次都从 LoadingBox 开始(RSS 动辄几百 KB)。
///
/// 容量有意收紧(RSS 是这个 App 里最大的数据):最多 MAX_FEEDS 个频道、每频道 MAX_EPISODES 集,
/// 超出按最近写入时间淘汰。整体 ~600KB 量级,计入设置页缓存大小。
export class FeedCacheStore {
  private static FILE = 'feed_cache.json';
  // 容量比另两端更紧:鸿蒙这份是**单文件整份写回**,每次落盘都要 JSON.stringify 全量,
  // 序列化仍在 UI 线程(只有写盘异步了)。20 × 50 约 600KB 量级,stringify 十几毫秒可接受。
  private static MAX_FEEDS = 20;
  private static MAX_EPISODES = 50;

  private mem: Record<string, FeedCacheEntry> = {};

  /**
   * 是否从盘上读过一次。**这是 中-4 的开关**:
   * `update/FeedUpdateExtension.ets` 里的 `new FeedCacheStore()` 是刻意不 load 的
   * (后台进程不该握着别人家的缓存,见那里的 H28 注释),但 `put()` 原先结尾**无条件** `persist()`,
   * 于是后台每轮刷新都会拿"这一轮只装了几个频道"的内存态整份覆写 `feed_cache.json` ——
   * 没订阅变化的那些频道详情缓存就此清空,还会和 UI 进程的去抖写互相踩。
   * 现在未 load 就只改内存、不落盘(见 REVIEW-2026-10-25 中-4)。
   */
  private loaded = false;
  /// 「跳过落盘」只在每个实例打一行,免得后台一轮 put 十几次就刷十几行同样的话。
  private skipLogged = false;

  load(): void {
    const o = JsonFile.readObject(FeedCacheStore.FILE);
    if (o === null) {
      // 文件不存在/为空也算"已经读过盘":这是全新装机,不是还没读,必须允许后续落盘。
      this.loaded = true;
      return;
    }
    const keys = Object.keys(o);
    for (let i = 0; i < keys.length; i++) {
      const item = J.asObj(o[keys[i]]);
      if (item === null) continue;
      const podcastObj = J.obj(item, 'podcast');
      if (podcastObj === null) continue;
      const arr = J.arr(item, 'episodes');
      const episodes: Episode[] = [];
      for (let j = 0; j < arr.length; j++) {
        // 一集坏数据只丢那一集,别让它变成详情页里一行空白点不开的格子
        // (见 REVIEW-2026-10-25 高-3 附带项)。id 是这一集的身份键(进度/收藏都按它)。
        const eo = J.asObj(arr[j]);
        if (eo === null) continue;
        const e = Codec.episodeFromJson(eo);
        if (e.id.length === 0) continue;
        episodes.push(e);
      }
      if (episodes.length === 0) continue;
      this.mem[keys[i]] = new FeedCacheEntry(
        Codec.podcastFromJson(podcastObj), episodes, J.num(item, 'fetchedAt'));
    }
    this.loaded = true;
    Log.i('FeedCache', `频道缓存加载 ${Object.keys(this.mem).length} 个`);
  }

  get(feedUrl: string): FeedCacheEntry | null {
    const v = this.mem[feedUrl];
    return v === undefined ? null : v;
  }

  /// 写入并按容量淘汰。episodes 超量时只留最前面的(RSS 本身按时间倒序)。
  put(feedUrl: string, result: FeedResult): void {
    if (feedUrl.length === 0 || result.episodes.length === 0) return;
    const eps = result.episodes.length > FeedCacheStore.MAX_EPISODES
      ? result.episodes.slice(0, FeedCacheStore.MAX_EPISODES)
      : result.episodes;
    this.mem[feedUrl] = new FeedCacheEntry(result.podcast, eps, Date.now());

    const keys = Object.keys(this.mem);
    if (keys.length > FeedCacheStore.MAX_FEEDS) {
      // 按 fetchedAt 升序,只保留最近的 MAX_FEEDS 条。
      // ArkTS 不支持 delete(arkts-no-delete),所以重建一份而不是原地删键。
      keys.sort((a: string, b: string) => this.mem[a].fetchedAt - this.mem[b].fetchedAt);
      const kept: Record<string, FeedCacheEntry> = {};
      for (let i = keys.length - FeedCacheStore.MAX_FEEDS; i < keys.length; i++) {
        kept[keys[i]] = this.mem[keys[i]];
      }
      this.mem = kept;
    }
    // 没 load 过就不落盘(中-4):本实例内存里只有"这一轮刷到的那几个频道",整份写回等于
    // 把别的频道的详情缓存抹掉(那正是后台轮次最不该做的事)。内存照写,让这一轮的刷新结果可用。
    if (!this.loaded) {
      if (!this.skipLogged) {
        this.skipLogged = true;
        Log.w('FeedCache', `未加载即写入(feedUrl=${feedUrl}),仅更新内存、跳过落盘:` +
          `整份覆写会清掉未订阅变化频道的缓存(见 REVIEW-2026-10-25 中-4)`);
      }
      return;
    }
    this.persist();
  }

  clear(): void {
    this.mem = {};
    JsonFile.remove(FeedCacheStore.FILE);
  }

  async sizeBytes(): Promise<number> {
    return JsonFile.sizeBytesAsync(FeedCacheStore.FILE);
  }

  /**
   * 落盘走**惰性**去抖:一次「最新」刷新会 put 15 次(每源一次),而每次 put 都要把整份缓存
   * (20 频道 × 50 集,约 600KB)重建成 JSON 对象再 stringify。原先那 15 遍全落在 UI 线程上,
   * 下拉刷新的转圈就卡在这儿。改成登记"怎么取值",到期只做一次(见 H64 与
   * `JsonFile.writeJsonDebouncedLazy`)。
   */
  private persist(): void {
    JsonFile.writeJsonDebouncedLazy(FeedCacheStore.FILE, (): Object => this.snapshot());
  }

  private snapshot(): Record<string, Object> {
    const out: Record<string, Object> = {};
    const keys = Object.keys(this.mem);
    for (let i = 0; i < keys.length; i++) {
      const e = this.mem[keys[i]];
      const eps: Object[] = [];
      for (let j = 0; j < e.episodes.length; j++) eps.push(Codec.episodeToJson(e.episodes[j]));
      out[keys[i]] = new StoredFeed(e.fetchedAt, Codec.podcastToJson(e.podcast), eps);
    }
    return out;
  }
}
