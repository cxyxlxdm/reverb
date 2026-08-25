import { Episode, Podcast } from '../model/Models';
import { JsonFile } from './JsonFile';
import { Codec } from './Codec';
import { J } from '../net/Http';
import { PodcastRepository } from '../net/PodcastRepository';
import { parsePubMillis } from '../util/DateParse';
import { Log } from '../util/Logger';

/**
 * 「最新」收件箱:跨全部订阅聚合最新单集。
 *
 * 移植时必须保留 Android/macOS 已验证的三个设计(都是踩过坑换来的):
 *  1. **有缓存时不做增量替换** —— 否则可见列表会先坍缩再重建,既跳闪又会顶起下拉刷新偏移;
 *     仅冷启动(无缓存)才逐源增量填充以提供进度反馈。
 *  2. **稳定排序**(日期 desc + id asc) —— 各源并行返回顺序不定,若仅按日期排,
 *     日期相同/无法解析的条目相对次序会随刷新变动,导致内容没变却"闪动"。
 *  3. **失败不覆盖** —— 全部源失败/超时时不要用空列表覆盖已有缓存。
 *
 * 另吸收 macOS 的 loadedSignature:订阅集未变则跳过重复全量刷新(切 tab 不再重拉)。
 * ArkTS 无协程,有界并发用 Promise 池 + 单源超时竞速实现。
 */
@Observed
export class InboxStore {
  episodes: Episode[] = [];
  refreshing: boolean = false;

  private static FILE = 'inbox.json';
  private static MAX = 100;
  private static PER_FEED_MAX = 12;      // 每源只取最新 12 集,避免大源刷屏
  private static PARALLELISM = 8;        // 有界并发
  private static PER_FEED_TIMEOUT = 8000; // 单源超时,慢源不拖垮整体

  private loadedSignature = '';
  private busy = false;                  // 防重入

  load(): void {
    const arr = JsonFile.readArray(InboxStore.FILE);
    const out: Episode[] = [];
    for (let i = 0; i < arr.length; i++) out.push(Codec.episodeFromJson(J.asObj(arr[i])));
    this.episodes = out;
    Log.i('Inbox', `加载 ${out.length} 条`);
  }

  /// 订阅集签名未变则跳过(避免切 tab 反复全量刷新)。
  async refreshIfStale(subs: Podcast[], repo: PodcastRepository): Promise<void> {
    const sig = InboxStore.signature(subs);
    if (sig === this.loadedSignature && this.episodes.length > 0) {
      Log.d('Inbox', '订阅集未变且已有内容,跳过刷新');
      return;
    }
    await this.refresh(subs, repo);
  }

  async refresh(subs: Podcast[], repo: PodcastRepository): Promise<void> {
    if (this.busy) {
      Log.d('Inbox', '刷新中,忽略重入');
      return;
    }
    const feeds = subs.map((p: Podcast) => p.feedUrl).filter((u: string) => u.length > 0);
    if (feeds.length === 0) {
      this.episodes = [];
      this.persist();
      this.loadedSignature = '';
      return;
    }

    this.busy = true;
    this.refreshing = true;
    const hasCache = this.episodes.length > 0;
    const collected: Episode[] = [];

    try {
      let next = 0;
      const worker = async (): Promise<void> => {
        while (true) {
          const i = next;
          next += 1;
          if (i >= feeds.length) return;
          const eps = await this.loadCapped(feeds[i], repo);
          for (let k = 0; k < eps.length; k++) collected.push(eps[k]);
          // 冷启动才逐源刷 UI(给进度反馈);有缓存则一律等最终原子替换
          if (!hasCache) this.episodes = InboxStore.merge(collected);
        }
      };
      const pool: Promise<void>[] = [];
      const n = Math.min(InboxStore.PARALLELISM, feeds.length);
      for (let i = 0; i < n; i++) pool.push(worker());
      await Promise.all(pool);

      const latest = InboxStore.merge(collected);
      // 失败不覆盖:全部源失败时保留旧内容,宁可陈旧也不白屏
      if (latest.length > 0 || !hasCache) this.episodes = latest;
      if (latest.length > 0) {
        this.persist();
        this.loadedSignature = InboxStore.signature(subs);
      }
      Log.i('Inbox', `刷新完成 源=${feeds.length} 得到 ${latest.length} 条`);
    } finally {
      this.busy = false;
      this.refreshing = false;
    }
  }

  /// 单源拉取 + 超时竞速 + 每源截断。
  private async loadCapped(feedUrl: string, repo: PodcastRepository): Promise<Episode[]> {
    const timeout: Promise<Episode[]> = new Promise((resolve: (v: Episode[]) => void) => {
      setTimeout(() => resolve([]), InboxStore.PER_FEED_TIMEOUT);
    });
    const work: Promise<Episode[]> = (async (): Promise<Episode[]> => {
      const feed = await repo.feed(feedUrl);
      if (feed === null) return [];
      const eps = feed.episodes.filter((e: Episode) => e.audioUrl.length > 0);
      const sorted = InboxStore.sortStable(eps);
      return sorted.slice(0, InboxStore.PER_FEED_MAX);
    })();
    return Promise.race([work, timeout]);
  }

  /// 按 id 去重 + 稳定排序 + 总量截断。
  private static merge(all: Episode[]): Episode[] {
    const seen = new Set<string>();
    const uniq: Episode[] = [];
    for (let i = 0; i < all.length; i++) {
      const e = all[i];
      if (e.id.length === 0 || seen.has(e.id)) continue;
      seen.add(e.id);
      uniq.push(e);
    }
    const sorted = InboxStore.sortStable(uniq);
    return sorted.length > InboxStore.MAX ? sorted.slice(0, InboxStore.MAX) : sorted;
  }

  /// 稳定全序:发布时间倒序,时间相同则按 id 升序(消除"内容没变却闪动")。
  private static sortStable(src: Episode[]): Episode[] {
    const a = src.slice();
    a.sort((x: Episode, y: Episode): number => {
      const dx = parsePubMillis(x.pubDate);
      const dy = parsePubMillis(y.pubDate);
      if (dx !== dy) return dy - dx;
      return x.id < y.id ? -1 : (x.id > y.id ? 1 : 0);
    });
    return a;
  }

  private static signature(subs: Podcast[]): string {
    const urls = subs.map((p: Podcast) => p.feedUrl).filter((u: string) => u.length > 0);
    urls.sort();
    return urls.join('|');
  }

  /// 惰性落盘(冷启动时每源都会刷一次列表,序列化只做最后一次)
  private persist(): void {
    JsonFile.writeJsonDebouncedLazy(InboxStore.FILE, (): Object => {
      const arr: Object[] = [];
      for (let i = 0; i < this.episodes.length; i++) arr.push(Codec.episodeToJson(this.episodes[i]));
      return arr;
    });
  }
}
