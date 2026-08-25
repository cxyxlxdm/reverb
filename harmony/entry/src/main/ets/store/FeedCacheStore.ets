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

  load(): void {
    const o = JsonFile.readObject(FeedCacheStore.FILE);
    if (o === null) return;
    const keys = Object.keys(o);
    for (let i = 0; i < keys.length; i++) {
      const item = J.asObj(o[keys[i]]);
      if (item === null) continue;
      const podcastObj = J.obj(item, 'podcast');
      if (podcastObj === null) continue;
      const arr = J.arr(item, 'episodes');
      const episodes: Episode[] = [];
      for (let j = 0; j < arr.length; j++) {
        episodes.push(Codec.episodeFromJson(J.asObj(arr[j])));
      }
      if (episodes.length === 0) continue;
      this.mem[keys[i]] = new FeedCacheEntry(
        Codec.podcastFromJson(podcastObj), episodes, J.num(item, 'fetchedAt'));
    }
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
