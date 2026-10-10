import { Episode, Podcast } from '../model/Models';
import { JsonFile } from './JsonFile';
import { Codec } from './Codec';
import { J } from '../net/Http';
import { PodcastRepository } from '../net/PodcastRepository';
import { parsePubMillis } from '../util/DateParse';
import { Log } from '../util/Logger';

/**
 * 「追更」收件箱:跨全部订阅聚合**全部单集**(内存侧不截断,落盘有界,见 persist)。
 *
 * 2026-10-10 之前是「每源最新 12 集 / 全局 100 条」,于是这一页只显示每个频道的头几集 ——
 * 与"这一格用来管理我订阅的全部内容"的定位不符。放开之后真正要重算的两笔:
 *  1. **排序成本**:比较器里不能再解析 pubDate(见 sortStable);
 *  2. **落盘体量**:全量约七千集(实测 20 个源,中位数 ~200,最大 2,828),整份写盘按装机
 *     实测的中位条大小估是十几到几十 MB(见 persist)。
 * 顺带一句:本端 `Repository.feed` 本来就整份下载并解析全量 RSS,那两道截断从来只限制
 * "留下多少条",不省网络也不省解析。
 *
 * 移植时必须保留 Android/macOS 已验证的三个设计(都是踩过坑换来的):
 *  1. **有缓存时不做增量替换** —— 否则可见列表会先坍缩再重建,既跳闪又会顶起下拉刷新偏移;
 *     仅冷启动(无缓存)才逐源增量填充以提供进度反馈。
 *  2. **稳定排序**(日期 desc + id asc) —— 各源并行返回顺序不定,若仅按日期排,
 *     日期相同/无法解析的条目相对次序会随刷新变动,导致内容没变却"闪动"。
 *  3. **失败不覆盖** —— 全部源失败/超时时不要用空列表覆盖已有缓存。
 *
 * 另吸收 macOS 的 loadedSignature:订阅集未变则跳过重复全量刷新(切 tab 不再重拉)。
 * ArkTS 无协程,有界并发用 Promise 池实现；单源截止由 Repository 的物理硬超时保证。
 */
@Observed
export class InboxStore {
  episodes: Episode[] = [];
  refreshing: boolean = false;

  private static FILE = 'inbox.json';
  private static PERSIST_MAX = 300;      // 落盘只留最新 300 条(内存留全量),理由见 persist
  private static PARALLELISM = 8;        // 有界并发

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
    // 全量之后这条耗时是**必须能看见**的量:merge/sort 没有协程帮忙,全程在 UI 线程上跑
    // (硬规矩 8),而这一页的数据规模刚从 100 条变成几千条。装机验收读这行数字。
    const t0 = Date.now();
    const hasCache = this.episodes.length > 0;
    const collected: Episode[] = [];
    // pubDate → 毫秒的**本次刷新**的键表:每集只解析一次,排序比较器只查表(见 sortStable)。
    const keys = new Map<string, number>();

    try {
      let next = 0;
      const worker = async (): Promise<void> => {
        while (true) {
          const i = next;
          next += 1;
          if (i >= feeds.length) return;
          const eps = await this.loadFeed(feeds[i], repo, keys);
          for (let k = 0; k < eps.length; k++) collected.push(eps[k]);
          // 冷启动才逐源刷 UI(给进度反馈);有缓存则一律等最终原子替换
          if (!hasCache) this.episodes = InboxStore.merge(collected, keys);
        }
      };
      const pool: Promise<void>[] = [];
      const n = Math.min(InboxStore.PARALLELISM, feeds.length);
      for (let i = 0; i < n; i++) pool.push(worker());
      await Promise.all(pool);

      const tMerge = Date.now();
      const latest = InboxStore.merge(collected, keys);
      const mergeMs = Date.now() - tMerge;
      // 失败不覆盖:全部源失败时保留旧内容,宁可陈旧也不白屏
      if (latest.length > 0 || !hasCache) this.episodes = latest;
      if (latest.length > 0) {
        this.persist();
        this.loadedSignature = InboxStore.signature(subs);
      }
      Log.i('Inbox', `刷新完成 源=${feeds.length} 得到 ${latest.length} 条 `
        + `落盘 ${Math.min(latest.length, InboxStore.PERSIST_MAX)} 条 末次合并=${mergeMs}ms 总=${Date.now() - t0}ms`);
    } finally {
      this.busy = false;
      this.refreshing = false;
    }
  }

  /// 单源拉取。**不截断**(旧口径是每源只留最新 12 集)—— 这一页要能翻到全部集数。
  /// 解析出的时刻顺手记进 [keys],让 merge 那边每集只解析一次。
  private async loadFeed(feedUrl: string, repo: PodcastRepository, keys: Map<string, number>): Promise<Episode[]> {
    const feed = await repo.feed(feedUrl);
    if (feed === null) return [];
    const eps = feed.episodes.filter((e: Episode) => e.audioUrl.length > 0);
    for (let i = 0; i < eps.length; i++) {
      if (!keys.has(eps[i].id)) keys.set(eps[i].id, parsePubMillis(eps[i].pubDate));
    }
    return eps;
  }

  /// 按 id 去重 + 稳定排序。**不在这里截断**,全量留在内存(落盘才截,见 persist)。
  private static merge(all: Episode[], keys: Map<string, number>): Episode[] {
    const seen = new Set<string>();
    const uniq: Episode[] = [];
    for (let i = 0; i < all.length; i++) {
      const e = all[i];
      if (e.id.length === 0 || seen.has(e.id)) continue;
      seen.add(e.id);
      // 去重时补解析:loadFeed 只填了「有音频地址」的那批,而 merge 也可能收到别的来源
      if (!keys.has(e.id)) keys.set(e.id, parsePubMillis(e.pubDate));
      uniq.push(e);
    }
    return InboxStore.sortStable(uniq, keys);
  }

  /// 稳定全序:发布时间倒序,时间相同则按 id 升序(消除"内容没变却闪动")。
  ///
  /// 时刻从 [keys] 查,**不在比较器里调 parsePubMillis**:全量之后一轮七千集,
  /// 一次排序的比较次数在十万量级,而本端这个解析函数每次要 split/正则/多次 parseInt。
  /// 硬规矩 6 那条乘法(调用次数 × 每次成本)在这里就是靠"每集只解析一次"拆掉的 ——
  /// 且本端没有协程,merge/sort 全部跑在 UI 线程,原先 100 条时这笔账根本不构成问题。
  private static sortStable(src: Episode[], keys: Map<string, number>): Episode[] {
    const a = src.slice();
    a.sort((x: Episode, y: Episode): number => {
      const kx = keys.get(x.id);
      const ky = keys.get(y.id);
      const dx = kx === undefined ? 0 : kx;
      const dy = ky === undefined ? 0 : ky;
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

  /// 惰性落盘(冷启动时每源都会刷一次列表,序列化只做最后一次)。
  ///
  /// **只写最新 [PERSIST_MAX] 条,而内存里是全量** —— 有意的分工:这份文件的作用只有
  /// 「冷启动秒显」,而 `load()` 在启动路径上同步读它(整份 JSON 解析七千集会卡启动,
  /// 与 H65 同一个形状);每条连 `description` 原文一起存,而**单条大小差一个数量级** ——
  /// 装机实测(2026-10-10,真机那份 `inbox.json`)落盘 333,160 B / 300 条,
  /// 单条 min 628 / 中位 811 / max 1,554 B(Android 同规模那份中位 1,354 / max 9,143,
  /// 因为那边存的简介更长,见 H168)⇒ **按中位 0.8–3.6 KB 外推到七千集是 6–27 MB 这一档**。
  /// 300 条是本机实测 0.33 MB(Android 0.74 MB),条数是旧那 100 条封顶的三倍,
  /// 这一倍数装机要盯:首帧若变慢先降到 100,再谈给冷启动那份裁掉 description。
  /// (已量过一次:鸿蒙冷启动 `[Inbox] 加载 300 条` 落在启动后 16 ms 内,首帧没变慢。)
  /// 写的是排序后的**前缀**,所以秒显那段就是全量列表的开头,刷新完只做后缀追加、不重排。
  /// 代价:深滚之后杀进程,重进要先等刷新完才够得着后面的集(或去频道主页,那里本来就是全量)。
  private persist(): void {
    JsonFile.writeJsonDebouncedLazy(InboxStore.FILE, (): Object => {
      const arr: Object[] = [];
      const limit = Math.min(this.episodes.length, InboxStore.PERSIST_MAX);
      for (let i = 0; i < limit; i++) arr.push(Codec.episodeToJson(this.episodes[i]));
      return arr;
    });
  }
}
