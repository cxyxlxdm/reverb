import taskpool from '@ohos.taskpool';
import { Episode, Podcast, FeedResult, SearchOutcome } from '../model/Models';
import { RssParser } from './RssParser';
import { fetchFeedConcurrent } from './FeedTask';
import { PopularCacheStore } from '../store/Stores';
import { SeedCatalog } from '../store/SeedCatalog';
import { FeedCacheStore } from '../store/FeedCacheStore';
import { Log } from '../util/Logger';

/**
 * 取源门面。本端只有 **RSS 直连** 一条路。
 *
 * 原先还有「Apple iTunes / Apple 榜单 / fyyd.de / gpodder.net」四路目录源(降级链),
 * 由 `Features.CATALOG` 在这一层拦住。但**光拦住不够** —— ArkTS 没有 R8 那样的
 * dead code elimination,常量为 false 也照样把类和 URL 编进 `modules.abc`,解包 grep 一抓就有,
 * 而合规申报写的是"仅作为 RSS 订阅解析工具"(见 TROUBLESHOOTING H46 / H54)。
 * 所以那四个类**整个移出了编译树**,现在在 `harmony/shelved/net/Sources.ets`。
 * 要放开内容目录的话,照 `harmony/shelved/README.md` 把三处 `TODO(catalog)` 接回来。
 *
 * 播放一律回落发布方 RSS 的 enclosure 原始直链。
 */
export class PodcastRepository {
  private cache: PopularCacheStore;
  /// 随包内置的精选清单:缓存为空(首装/清缓存/无网)时给发现页兜底,避免首屏空白
  private seed: SeedCatalog;
  /// 频道详情(解析后的 RSS)缓存:详情页秒开,且断网时仍能看已访问过的频道
  private feedCache: FeedCacheStore;

  constructor(cache: PopularCacheStore, seed: SeedCatalog, feedCache: FeedCacheStore) {
    this.cache = cache;
    this.seed = seed;
    this.feedCache = feedCache;
  }

  /// 搜索频道:**只认 RSS 地址直连**。
  /// TODO(catalog): 放开内容目录时,URL 解析失败要继续降级到 Apple → fyyd → gpodder
  /// (Android 侧的行为;macOS 是直接返回空)。
  async search(query: string, region: string): Promise<SearchOutcome> {
    const q = query.trim();
    if (q.length === 0) return { podcasts: [], sourceLabel: '', failed: false };

    if (q.startsWith('http://') || q.startsWith('https://')) {
      const feed = await RssParser.fetch(q);
      if (feed !== null) {
        Log.i('Repo', `搜索命中 RSS 直连 "${feed.podcast.title}"`);
        return { podcasts: [feed.podcast], sourceLabel: 'RSS', failed: false };
      }
    }

    // 到此为止:关键词检索返回的是节目列表,同样构成动态目录(Features.CATALOG=false)。
    Log.w('Repo', `搜索无结果 q="${q}"`);
    return { podcasts: [], sourceLabel: '', failed: true };
  }

  /// 搜索单集:本端不提供(单集检索只有 Apple 有,属内容目录)。
  /// TODO(catalog): 放开内容目录时接回 `ITunesSource.searchEpisodes`;注意 **URL 输入不参与**
  /// (与 Android 一致)—— 把一条 RSS 地址当关键词丢给 iTunes,既拿不到结果,
  /// 又平白多一次目录请求。
  async searchEpisodes(query: string, region: string): Promise<Episode[]> {
    return [];
  }

  cacheKey(genreId: number, region: string): string {
    return `${region}:${genreId > 0 ? `${genreId}` : 'default'}`;
  }

  /// 秒返可展示列表(零 IO),供 UI 立即渲染。优先真实缓存;缓存为空(首装/清过缓存/一直无网)
  /// 则回退到随包内置清单,保证首屏不空。种子**只读不写缓存**,联网刷新成功即被真数据取代。
  cachedPopular(genreId: number, region: string): Podcast[] {
    const real = this.cache.get(this.cacheKey(genreId, region));
    if (real.length > 0) return real;
    return this.seed.get(genreId, region);
  }

  /// 当前展示的是内置清单(而非联网取回的真榜单)——UI 据此把标题标成「内置精选」。
  isSeedList(genreId: number, region: string): boolean {
    return this.cache.get(this.cacheKey(genreId, region)).length === 0
      && this.seed.get(genreId, region).length > 0;
  }

  /// 内置清单的生成日期(yyyy-MM-dd)。
  seedGeneratedAt(): string {
    return this.seed.generatedAt();
  }

  /// 刷新热门榜:本端不提供(榜单即内容目录),恒返回空。
  /// TODO(catalog): 放开内容目录时接回三层降级 —— 分类榜/综合榜 →(综合榜且非 us 时)
  /// 回落 us → fyyd hot;**只有拿到非空结果才写缓存**,失败保留旧缓存。
  async refreshPopular(genreId: number, region: string): Promise<Podcast[]> {
    return [];
  }

  /**
   * 解析某个 feed(频道详情 / 最新聚合都走这里)。成功回写磁盘缓存;
   * 失败返回 null(旧缓存保留,由调用方决定是否用)。
   *
   * **走 TaskPool 子线程**:解析是同步 JS,大源能占住 UI 线程近两秒(见 `FeedTask` 与 H64)。
   * 子线程不可用时**回落到本线程解析** —— 宁可卡一下也不能让刷新整个失效
   * (与本仓库其它降级链同一取舍)。
   */
  async feed(feedUrl: string): Promise<FeedResult | null> {
    if (feedUrl.trim().length === 0) return null;
    let r: FeedResult | null = null;
    try {
      const out: Object = await taskpool.execute(fetchFeedConcurrent, feedUrl);
      r = out === null || out === undefined ? null : out as FeedResult;
    } catch (e) {
      Log.w('Repo', `子线程解析失败,回落本线程:${(e as Error).message}`);
      r = await RssParser.fetch(feedUrl);
    }
    if (r !== null && r.episodes.length > 0) this.feedCache.put(feedUrl, r);
    return r;
  }

  /// 立即返回上次解析结果(可能过时,可能为 null),供进入详情页时秒开、断网时兜底。
  cachedFeed(feedUrl: string): FeedResult | null {
    const e = this.feedCache.get(feedUrl);
    if (e === null) return null;
    return { podcast: e.podcast, episodes: e.episodes };
  }

  /// 该 feed 缓存的落盘时刻(毫秒);无缓存返回 0。用于「上次更新于 X」提示。
  feedCachedAt(feedUrl: string): number {
    const e = this.feedCache.get(feedUrl);
    return e === null ? 0 : e.fetchedAt;
  }

  /// 随机取一集(随机/情境电台用)。先用缓存榜单组池,零联网;池不够再补拉一次。
  async randomEpisode(region: string, genreIds: number[], exclude: string[]): Promise<Episode | null> {
    const pool: Podcast[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < genreIds.length; i++) {
      const list = this.cachedPopular(genreIds[i], region);
      for (let j = 0; j < list.length; j++) {
        const p = list[j];
        if (p.feedUrl.length === 0 || seen.has(p.feedUrl)) continue;
        seen.add(p.feedUrl);
        pool.push(p);
      }
    }
    if (pool.length < 10) {
      const extra = await this.refreshPopular(0, region);
      for (let j = 0; j < extra.length; j++) {
        const p = extra[j];
        if (p.feedUrl.length === 0 || seen.has(p.feedUrl)) continue;
        seen.add(p.feedUrl);
        pool.push(p);
      }
    }
    if (pool.length === 0) return null;

    // 付费源常拿不到直链;全付费则放开
    let candidates = pool.filter((p: Podcast) => !p.isPaid);
    if (candidates.length === 0) candidates = pool;

    const picked = shuffle(candidates).slice(0, 6);
    const excludeSet = new Set<string>(exclude);
    for (let i = 0; i < picked.length; i++) {
      const feed = await this.feed(picked[i].feedUrl);
      if (feed === null) continue;
      const usable = feed.episodes.filter((e: Episode) => e.audioUrl.length > 0 && !excludeSet.has(e.id));
      if (usable.length === 0) continue;
      const idx = Math.floor(Math.random() * usable.length);
      return usable[idx];
    }
    return null;
  }
}

function shuffle(src: Podcast[]): Podcast[] {
  const a = src.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    const t = a[i];
    a[i] = a[j];
    a[j] = t;
  }
  return a;
}
