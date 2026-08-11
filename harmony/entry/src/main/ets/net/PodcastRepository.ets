import { Episode, Podcast, FeedResult, SearchOutcome } from '../model/Models';
import { ITunesSource, AppleChartsSource, FyydSource, GpodderSource } from './Sources';
import { RssParser } from './RssParser';
import { PopularCacheStore } from '../store/Stores';
import { Log } from '../util/Logger';

/// 取源门面。四层降级搜索、热门榜三层降级(失败保留旧缓存)、随机单集。
/// 全链路免费无鉴权;播放一律回落发布方 RSS 的 enclosure 原始直链。
export class PodcastRepository {
  private cache: PopularCacheStore;

  constructor(cache: PopularCacheStore) {
    this.cache = cache;
  }

  /// 搜索频道:URL 直连 → Apple → fyyd → gpodder。
  /// 注意:URL 解析失败时**继续向下降级**(取 Android 行为,macOS 是直接返回空)。
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

    const apple = await ITunesSource.search(q, region);
    if (apple.length > 0) return { podcasts: apple, sourceLabel: 'Apple Podcasts', failed: false };

    const fyyd = await FyydSource.search(q);
    if (fyyd.length > 0) return { podcasts: fyyd, sourceLabel: 'fyyd.de', failed: false };

    const gp = await GpodderSource.search(q);
    if (gp.length > 0) return { podcasts: gp, sourceLabel: 'gpodder.net', failed: false };

    Log.w('Repo', `搜索无结果 q="${q}"`);
    return { podcasts: [], sourceLabel: '', failed: true };
  }

  /// 搜索单集(仅 Apple 提供单集检索)。
  async searchEpisodes(query: string, region: string): Promise<Episode[]> {
    const q = query.trim();
    if (q.length === 0) return [];
    return ITunesSource.searchEpisodes(q, region);
  }

  cacheKey(genreId: number, region: string): string {
    return `${region}:${genreId > 0 ? `${genreId}` : 'default'}`;
  }

  /// 缓存秒返(零 IO),供 UI 立即渲染。
  cachedPopular(genreId: number, region: string): Podcast[] {
    return this.cache.get(this.cacheKey(genreId, region));
  }

  /// 刷新热门榜:分类榜/综合榜 → (综合榜且非 us 时)回落 us → fyyd hot。
  /// 只有拿到非空结果才写缓存,失败保留旧缓存。
  async refreshPopular(genreId: number, region: string): Promise<Podcast[]> {
    let list: Podcast[] = genreId > 0
      ? await AppleChartsSource.topByGenre(region, genreId, 30)
      : await AppleChartsSource.top(region, 30);

    if (list.length === 0 && genreId === 0 && region !== 'us') {
      list = await AppleChartsSource.top('us', 30);
    }
    if (list.length === 0) {
      list = await FyydSource.hot(30);
    }
    if (list.length > 0) {
      this.cache.put(this.cacheKey(genreId, region), list);
      Log.i('Repo', `热门榜刷新 ${list.length} 条 key=${this.cacheKey(genreId, region)}`);
    } else {
      Log.w('Repo', `热门榜刷新为空,保留旧缓存 key=${this.cacheKey(genreId, region)}`);
    }
    return list;
  }

  /// 解析某个 feed(频道详情 / 最新聚合都走这里)。
  async feed(feedUrl: string): Promise<FeedResult | null> {
    if (feedUrl.trim().length === 0) return null;
    return RssParser.fetch(feedUrl);
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
