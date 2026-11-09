import taskpool from '@ohos.taskpool';
import { Episode, Podcast, FeedResult, SearchOutcome } from '../model/Models';
import { RssParser, FeedOutcome } from './RssParser';
import { Http } from './Http';
import { ITunesSource, AppleChartsSource, FyydSource, GpodderSource } from './Sources';
import { fetchFeedConcurrent } from './FeedTask';
import { PopularCacheStore } from '../store/Stores';
import { SeedCatalog } from '../store/SeedCatalog';
import { FeedCacheStore } from '../store/FeedCacheStore';
import { FeedAuthStore } from '../store/FeedAuthStore';
import { FeedCredential } from '../model/FeedCredential';
import { Log } from '../util/Logger';
import { CatalogFeedFilter } from './CatalogFeedFilter';
import { BilibiliSource } from './BilibiliSource';
import { Features } from '../Features';

export enum FeedProbeState {
  UNCHECKED = 0,
  CHECKING = 1,
  AVAILABLE = 2,
  UNREACHABLE = 3
}

class ProbeFailure {
  failedAt: number;

  constructor(failedAt: number) {
    this.failedAt = failedAt;
  }
}

/**
 * 取源门面。频道搜索按 RSS 直连 → Apple → fyyd → gpodder 降级;
 * 榜单按 Apple 地区/分类榜 → 美国综合榜 → fyyd 热门降级。
 *
 * 目录接口只负责发现节目,播放始终回落发布方 RSS 的 enclosure 原始直链。
 */
export class PodcastRepository {
  private static RSS_TIMEOUT_MS = 12000;
  private static PROBE_TIMEOUT_MS = 8000;
  private static PROBE_FAILURE_TTL_MS = 2 * 60 * 1000;
  private static PROBE_CACHE_MAX = 64;

  private cache: PopularCacheStore;
  /// 随包内置的精选清单:缓存为空(首装/清缓存/无网)时给发现页兜底,避免首屏空白
  private seed: SeedCatalog;
  /// 频道详情(解析后的 RSS)缓存:详情页秒开,且断网时仍能看已访问过的频道
  private feedCache: FeedCacheStore;
  /// 私有订阅源的凭据账本。与 `feedCache` 一样由仓库持有 —— 但**只在本机**,
  /// 不随订阅列表导出,也不进备份(见 `FeedAuthStore` 类注释)。
  readonly authStore: FeedAuthStore = new FeedAuthStore();
  /**
   * 401 挑战。用回调而不是被观察的状态:同一时刻可能有多个页面在场(发现页 / 频道详情),
   * 而**只有发起这次请求的那一个该弹框** —— 由各页面自己按 feedUrl 认领(见 H253)。
   * 页面在 `aboutToAppear` 里挂、`aboutToDisappear` 里撤。
   */
  authChallenge: ((feedUrl: string, failed: boolean) => void) | null = null;
  /// 同一 URL + 超时策略只允许一条真实网络/解析链；预检成功后详情直接复用 FeedCache。
  /// 键里带凭据指纹 —— 用户改了口令之后,"上一次的失败链"不能被当成这一轮的结果复用。
  private feedInFlight: Map<string, Promise<FeedOutcome>> = new Map<string, Promise<FeedOutcome>>();
  /**
   * 视频当播客听。播放前解析也走它(见 `PlayerController.resolvePseudoUrl`)——
   * 播放层与检索**共用这一个实例**,候选流缓存与探活游标才有意义。
   */
  readonly bilibili: BilibiliSource = new BilibiliSource();
  /// 预检并发在 Repository 全局封顶为 2；新搜索不会绕过旧搜索仍在执行的两个请求。
  private probeActive = 0;
  private probeWaiters: Array<() => void> = [];
  private probeStates: Map<string, FeedProbeState> = new Map<string, FeedProbeState>();
  private probeStateOrder: string[] = [];
  /// 失败只作短期预检抑制，不参与 feed()，所以粘贴 URL 与已有订阅始终能重新真实请求。
  private probeFailures: Map<string, ProbeFailure> = new Map<string, ProbeFailure>();
  private probeFailureOrder: string[] = [];

  constructor(cache: PopularCacheStore, seed: SeedCatalog, feedCache: FeedCacheStore) {
    this.cache = cache;
    this.seed = seed;
    this.feedCache = feedCache;
  }

  /// 搜索频道:URL 只按 RSS 直连处理；关键词按 Apple → fyyd → gpodder 降级。
  async search(query: string, region: string): Promise<SearchOutcome> {
    const q = query.trim();
    if (q.length === 0) return { podcasts: [], sourceLabel: '', failed: false };

    // 视频页地址(BV 号本体 / 完整 URL / 短链)排在最前:它既是"用户点名的那一条",
    // 也永远解析不出 RSS —— 先跑 RSS 只会白等一次超时。
    // 这一步**不受目录闸管**:粘链接不是"下拉就能翻到的目录",与关键词检索不是一回事。
    if (BilibiliSource.looksLikeVideo(q)) {
      const feed = await this.bilibili.resolveInput(q);
      if (feed !== null) {
        Log.i('Repo', `搜索经视频站直连命中 parts=${feed.episodes.length}`);
        return { podcasts: [feed.podcast], sourceLabel: 'Bilibili', failed: false };
      }
      Log.w('Repo', '视频链接解析失败');
      return { podcasts: [], sourceLabel: 'Bilibili', failed: true };
    }

    if (q.startsWith('http://') || q.startsWith('https://')) {
      // 目录坏源表只过滤目录结果。用户明确粘贴的 URL 必须真实尝试；失败后也不能把整条
      // URL 当关键词发给目录服务,否则既泄露路径又给出毫不相关的搜索结果。
      const feed = await this.feed(q);
      if (feed !== null) {
        Log.i('Repo', `RSS 直连成功 host=${Http.host(q)}`);
        return { podcasts: [feed.podcast], sourceLabel: 'RSS', failed: false };
      }
      Log.w('Repo', `RSS 直连失败 host=${Http.host(q)}`);
      return { podcasts: [], sourceLabel: 'RSS', failed: true };
    }

    // `CATALOG=false` 的降级档到此为止:关键词检索返回的是节目列表,同样构成动态目录。
    // 与 Android `PodcastRepository.search` 同址同判据(那里是 `BuildConfig.CATALOG`,
    // 编译期常量 → R8 连三个数据源一起剔掉;本端没有 DCE,**代码仍在包里** ——
    // 要"真的没有"只能把整支移出编译树,见硬规矩 2)。上面两条(粘视频链接 / 粘 RSS 地址)
    // 在闸前返回,它们不是"下拉就能翻到的目录"。
    if (!Features.CATALOG) return { podcasts: [], sourceLabel: '', failed: true };

    const apple = CatalogFeedFilter.keepPodcasts(await ITunesSource.search(q, region));
    if (apple.length > 0) {
      Log.i('Repo', `搜索经 Apple 命中 ${apple.length} 条`);
      return { podcasts: apple, sourceLabel: 'Apple Podcasts', failed: false };
    }

    const fyyd = CatalogFeedFilter.keepPodcasts(await FyydSource.search(q));
    if (fyyd.length > 0) {
      Log.i('Repo', `搜索经 fyyd 命中 ${fyyd.length} 条`);
      return { podcasts: fyyd, sourceLabel: 'fyyd.de', failed: false };
    }

    const gpodder = CatalogFeedFilter.keepPodcasts(await GpodderSource.search(q));
    if (gpodder.length > 0) {
      Log.i('Repo', `搜索经 gpodder 命中 ${gpodder.length} 条`);
      return { podcasts: gpodder, sourceLabel: 'gpodder.net', failed: false };
    }

    Log.w('Repo', '搜索无结果');
    return { podcasts: [], sourceLabel: '', failed: true };
  }

  /// 按关键词搜索单集;URL 输入只参与频道 RSS 直连,不额外请求目录。
  async searchEpisodes(query: string, region: string): Promise<Episode[]> {
    // 与 Android `PodcastRepository.searchEpisodes` 同址同判据(那里是 BuildConfig.CATALOG)
    if (!Features.CATALOG) return [];
    const q = query.trim();
    if (q.length === 0 || q.startsWith('http://') || q.startsWith('https://')) return [];
    const episodes = CatalogFeedFilter.keepEpisodes(await ITunesSource.searchEpisodes(q, region));
    // 视频的"一条视频"与"一集"是同一粒度,直接并进这一路。**受目录闸管**:关键词检索
    // 拿到的是动态目录,与 Apple/fyyd/gpodder 同一口径(见 search() 里那段注释)。
    // 搜索失败不拖垮整列 —— 上面的 Apple 结果照常返回。
    let extra: Episode[] = [];
    try {
      extra = await this.bilibili.searchEpisodes(q);
    } catch (_e) {
      Log.w('Repo', '视频站单集搜索失败');
    }
    const out: Episode[] = episodes.concat(extra);
    Log.i('Repo', `单集搜索命中 ${out.length} 条 (视频 ${extra.length})`);
    return out;
  }

  cacheKey(genreId: number, region: string): string {
    return `${region}:${genreId > 0 ? `${genreId}` : 'default'}`;
  }

  /// 秒返可展示列表(零 IO),供 UI 立即渲染。优先真实缓存;缓存为空(首装/清过缓存/一直无网)
  /// 则回退到随包内置清单,保证首屏不空。种子**只读不写缓存**,联网刷新成功即被真数据取代。
  cachedPopular(genreId: number, region: string): Podcast[] {
    const real = CatalogFeedFilter.keepPodcasts(this.cache.get(this.cacheKey(genreId, region)));
    if (real.length > 0) return real;
    return CatalogFeedFilter.keepPodcasts(this.seed.get(genreId, region));
  }

  /// 当前展示的是内置清单(而非联网取回的真榜单)——UI 据此把标题标成「内置精选」。
  isSeedList(genreId: number, region: string): boolean {
    return CatalogFeedFilter.keepPodcasts(this.cache.get(this.cacheKey(genreId, region))).length === 0
      && CatalogFeedFilter.keepPodcasts(this.seed.get(genreId, region)).length > 0;
  }

  /// 内置清单的生成日期(yyyy-MM-dd)。
  seedGeneratedAt(): string {
    return this.seed.generatedAt();
  }

  /// 刷新热门榜:分类榜/地区综合榜 → 美国综合榜 → fyyd 热门;失败保留旧缓存。
  async refreshPopular(genreId: number, region: string): Promise<Podcast[]> {
    Log.i('Repo', `刷新榜单 genre=${genreId > 0 ? `${genreId}` : 'all'} region=${region}`);
    let list = CatalogFeedFilter.keepPodcasts(genreId > 0
      ? await AppleChartsSource.topByGenre(region, genreId, 30)
      : await AppleChartsSource.top(region, 30));
    if (list.length === 0 && genreId <= 0) {
      if (region !== 'us') list = CatalogFeedFilter.keepPodcasts(await AppleChartsSource.top('us', 30));
      if (list.length === 0) list = CatalogFeedFilter.keepPodcasts(await FyydSource.hot(30));
    }
    if (list.length > 0) this.cache.put(this.cacheKey(genreId, region), list);
    Log.i('Repo', `榜单刷新完成 count=${list.length}`);
    return list;
  }

  /**
   * 解析某个 feed(频道详情 / 最新聚合都走这里)。完整 trim URL 相同的并发调用共用一条
   * Promise；成功回写磁盘缓存,失败返回 null(旧缓存保留,由调用方决定是否用)。
   *
   * **走 TaskPool 子线程**:解析是同步 JS,大源能占住 UI 线程近两秒(见 `FeedTask` 与 H64)。
   * worker 返回 null 已经是一次完整网络尝试的正常失败终态,绝不能再在 UI 线程请求第二遍。
   * 只有 taskpool.execute 本身抛出调度/序列化/worker 初始化异常时才回落本线程一次。
   */
  async feed(feedUrl: string): Promise<FeedResult | null> {
    // 凭据/网址从同一处拆分:搜索页粘进来的带 userinfo 的地址,与订阅里存的那份
    // 必须收敛到同一个键 —— 否则缓存、凭据、备份会各认一个。(ArkTS 不支持解构声明)
    const split = FeedCredential.splitUrl(feedUrl);
    const url = split[0];
    const inline = split[1];
    if (url.length === 0) return null;
    // 视频源的 feedUrl 是 `bilibili://video/<bvid>` 这种伪地址:交给 RSS 解析器(它走
    // taskpool 里的 Http)会当场失败,所以在这里分叉,而不是让它统一落进 fetchFeedOnce。
    // 落盘缓存照写 —— 存的同样只有伪地址,不含会过期的直链(见 BilibiliSource 类注释第 2 条)。
    if (BilibiliSource.isPseudo(url)) {
      const result = await this.bilibili.feedOf(url);
      if (result !== null && result.episodes.length > 0) this.feedCache.put(url, result);
      return result;
    }
    const credential = inline !== null ? inline : this.authStore.get(url);
    const outcome = await this.feedWithTimeout(url, PodcastRepository.RSS_TIMEOUT_MS, credential);
    if (outcome.result !== null && inline !== null) this.authStore.save(url, inline);
    if (outcome.result === null && outcome.unauthorized) this.challenge(url);
    return outcome.result;
  }

  /// 界面在 401 弹框里点「保存」之后调用,然后自己重新拉一次。
  saveAuth(feedUrl: string, username: string, password: string): void {
    this.authStore.save(this.cleanUrl(feedUrl), new FeedCredential(username, password));
  }

  /// 取消订阅时清掉这个源的凭据(AppContainer 把它接在 `SubscriptionStore.onRemoved` 上)。
  forgetAuth(feedUrl: string): void {
    this.authStore.forget(this.cleanUrl(feedUrl));
  }

  /// 输入框预填用。
  credentialFor(feedUrl: string): FeedCredential | null {
    return this.authStore.get(this.cleanUrl(feedUrl));
  }

  /// 音频 / 逐字稿取流时用的头:只有与已存源同主机(或互为子域)才给。
  authHeader(url: string): string | null {
    return this.authStore.headerForUrl(url);
  }

  /// 去掉 userinfo 的 URL(订阅/缓存/凭据共用这一个键)。
  cleanUrl(raw: string): string {
    return FeedCredential.splitUrl(raw)[0];
  }

  /// 401 → 交给发起这次请求的页面。`failed` 只有一种来源:本机对这个源已经存着凭据 ——
  /// 那说明这次是**凭据不对**,输入框要显示错误行并预填用户名。
  private challenge(feedUrl: string): void {
    const clean = this.cleanUrl(feedUrl);
    const failed = this.authStore.get(clean) !== null;
    Log.w('Repo', `feed 需要认证 feed=${Log.endpoint(clean)} failed=${failed}`);
    if (this.authChallenge !== null) this.authChallenge(clean, failed);
  }

  /** 搜索结果预检。失败缓存仅存两分钟；feed() 从不读取它。 */
  async probeFeed(feedUrl: string): Promise<boolean> {
    const key = feedUrl.trim();
    if (key.length === 0) return false;
    // 伪地址没有 RSS 可"预检":它是不是还在,只能等点进频道页那次 view 回答。
    // 直接报可用 —— 否则搜索结果会把每一条视频都标成"不可达",而那是假话。
    if (BilibiliSource.isPseudo(key)) {
      this.clearProbeFailure(key);
      this.rememberProbeState(key, FeedProbeState.AVAILABLE);
      return true;
    }
    const cached = this.feedCache.get(key);
    if (cached !== null && cached.episodes.length > 0) {
      this.clearProbeFailure(key);
      this.rememberProbeState(key, FeedProbeState.AVAILABLE);
      return true;
    }
    const failure = this.validProbeFailure(key);
    if (failure !== null) {
      this.rememberProbeState(key, FeedProbeState.UNREACHABLE);
      return false;
    }
    const current = this.probeStates.get(key);
    if (current === FeedProbeState.AVAILABLE) return true;

    await this.acquireProbeSlot();
    try {
      // 排队期间同一 URL 可能已由另一条预检完成,进入网络前必须重读结果。
      if (this.validProbeFailure(key) !== null) {
        this.rememberProbeState(key, FeedProbeState.UNREACHABLE);
        return false;
      }
      if (this.probeStates.get(key) === FeedProbeState.AVAILABLE) return true;

      this.rememberProbeState(key, FeedProbeState.CHECKING);
      // 预检**静默**带上已存凭据:不弹框(预检是搜索结果的随手一测),
      // 但已经有口令的私有源不该在列表里被标成「不可达」。
      const outcome = await this.feedWithTimeout(key, PodcastRepository.PROBE_TIMEOUT_MS,
        this.authStore.get(key));
      if (outcome.result !== null) {
        this.clearProbeFailure(key);
        this.rememberProbeState(key, FeedProbeState.AVAILABLE);
        return true;
      }
      this.rememberProbeFailure(key);
      this.rememberProbeState(key, FeedProbeState.UNREACHABLE);
      return false;
    } finally {
      this.releaseProbeSlot();
    }
  }

  private async acquireProbeSlot(): Promise<void> {
    if (this.probeActive < 2) {
      this.probeActive += 1;
      return;
    }
    await new Promise<void>((resolve: () => void) => { this.probeWaiters.push(resolve); });
    this.probeActive += 1;
  }

  private releaseProbeSlot(): void {
    this.probeActive = Math.max(0, this.probeActive - 1);
    const next = this.probeWaiters.shift();
    if (next !== undefined) next();
  }

  feedProbeState(feedUrl: string): FeedProbeState {
    const key = feedUrl.trim();
    if (key.length === 0) return FeedProbeState.UNCHECKED;
    if (this.validProbeFailure(key) !== null) return FeedProbeState.UNREACHABLE;
    const state = this.probeStates.get(key);
    return state === undefined ? FeedProbeState.UNCHECKED : state;
  }

  private async feedWithTimeout(feedUrl: string, timeoutMs: number,
    credential: FeedCredential | null): Promise<FeedOutcome> {
    // 8s 预检与 12s 正式加载不能互相继承截止时间；相同策略的并发调用仍严格单飞。
    // 键里带凭据指纹:用户改完口令重试时,不能复用上一把口令那条已失败的链。
    const authKey = credential === null ? '' : credential.defaultHeader;
    const flightKey = `${timeoutMs}:${feedUrl}:${authKey}`;
    const existing = this.feedInFlight.get(flightKey);
    if (existing !== undefined) return await existing;

    const work = this.fetchFeedOnce(feedUrl, timeoutMs, credential);
    this.feedInFlight.set(flightKey, work);
    try {
      return await work;
    } finally {
      this.feedInFlight.delete(flightKey);
    }
  }

  private async fetchFeedOnce(feedUrl: string, timeoutMs: number,
    credential: FeedCredential | null): Promise<FeedOutcome> {
    const startedAt = Date.now();
    const user = credential === null ? '' : credential.username;
    const pass = credential === null ? '' : credential.password;
    let outcome: FeedOutcome = { result: null, unauthorized: false };
    try {
      const out: Object = await taskpool.execute(fetchFeedConcurrent, feedUrl, timeoutMs, user, pass);
      // null 是 worker 已完成请求后的正常失败结果,这里直接结束,不可回落后二次请求。
      if (out === null || out === undefined) {
        Log.w('Repo', `host=${Http.host(feedUrl)} 阶段=worker返回空 耗时=${Date.now() - startedAt}ms`);
        return outcome;
      }
      outcome = out as FeedOutcome;
    } catch (_e) {
      Log.w('Repo', `host=${Http.host(feedUrl)} 阶段=worker异常回落 耗时=${Date.now() - startedAt}ms`);
      outcome = await RssParser.fetchOutcome(feedUrl, timeoutMs, user, pass);
    }
    if (outcome.result !== null) {
      if (outcome.result.episodes.length > 0) this.feedCache.put(feedUrl, outcome.result);
      // 正式详情或后台刷新成功也要清掉较早的短期负缓存,否则搜索仍会错误显示不可达。
      this.clearProbeFailure(feedUrl);
      this.rememberProbeState(feedUrl, FeedProbeState.AVAILABLE);
    }
    return outcome;
  }

  private validProbeFailure(feedUrl: string): ProbeFailure | null {
    const failure = this.probeFailures.get(feedUrl);
    if (failure === undefined) return null;
    if (Date.now() - failure.failedAt < PodcastRepository.PROBE_FAILURE_TTL_MS) return failure;
    this.clearProbeFailure(feedUrl);
    if (this.probeStates.get(feedUrl) === FeedProbeState.UNREACHABLE) this.clearProbeState(feedUrl);
    return null;
  }

  private rememberProbeFailure(feedUrl: string): void {
    this.clearProbeFailure(feedUrl);
    this.probeFailures.set(feedUrl, new ProbeFailure(Date.now()));
    this.probeFailureOrder.push(feedUrl);
    while (this.probeFailureOrder.length > PodcastRepository.PROBE_CACHE_MAX) {
      const oldest = this.probeFailureOrder.shift();
      if (oldest !== undefined) {
        this.probeFailures.delete(oldest);
        // 负缓存淘汰时状态也必须一起忘掉,否则 UNREACHABLE 会脱离 TTL 永久残留。
        if (this.probeStates.get(oldest) === FeedProbeState.UNREACHABLE) this.clearProbeState(oldest);
      }
    }
  }

  private clearProbeFailure(feedUrl: string): void {
    this.probeFailures.delete(feedUrl);
    const index = this.probeFailureOrder.indexOf(feedUrl);
    if (index >= 0) this.probeFailureOrder.splice(index, 1);
  }

  private rememberProbeState(feedUrl: string, state: FeedProbeState): void {
    this.clearProbeState(feedUrl);
    this.probeStates.set(feedUrl, state);
    this.probeStateOrder.push(feedUrl);
    while (this.probeStateOrder.length > PodcastRepository.PROBE_CACHE_MAX) {
      const oldest = this.probeStateOrder.shift();
      if (oldest !== undefined) this.probeStates.delete(oldest);
    }
  }

  private clearProbeState(feedUrl: string): void {
    this.probeStates.delete(feedUrl);
    const index = this.probeStateOrder.indexOf(feedUrl);
    if (index >= 0) this.probeStateOrder.splice(index, 1);
  }

  /// 立即返回上次解析结果(可能过时,可能为 null),供进入详情页时秒开、断网时兜底。
  cachedFeed(feedUrl: string): FeedResult | null {
    const e = this.feedCache.get(feedUrl.trim());
    if (e === null) return null;
    return { podcast: e.podcast, episodes: e.episodes };
  }

  /// 该 feed 缓存的落盘时刻(毫秒);无缓存返回 0。用于「上次更新于 X」提示。
  feedCachedAt(feedUrl: string): number {
    const e = this.feedCache.get(feedUrl.trim());
    return e === null ? 0 : e.fetchedAt;
  }

  /// 随机取一集(随机/情境电台用)。电台严格当前地区,不读可能含跨区回退的综合榜缓存。
  async randomEpisode(region: string, genreIds: number[], exclude: string[]): Promise<Episode | null> {
    const pool: Podcast[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < genreIds.length; i++) {
      const genreId = genreIds[i];
      if (genreId <= 0) continue;
      const list = this.cachedPopular(genreId, region);
      for (let j = 0; j < list.length; j++) {
        const p = list[j];
        if (p.feedUrl.length === 0 || seen.has(p.feedUrl)) continue;
        seen.add(p.feedUrl);
        pool.push(p);
      }
    }
    if (pool.length < 10) {
      for (let i = 0; i < genreIds.length; i++) {
        const genreId = genreIds[i];
        const cached = CatalogFeedFilter.keepPodcasts(this.cache.get(this.cacheKey(genreId, region)));
        if (genreId <= 0 || cached.length > 0) continue;
        const extra = await this.refreshPopular(genreId, region);
        for (let j = 0; j < extra.length; j++) {
          const p = extra[j];
          if (p.feedUrl.length === 0 || seen.has(p.feedUrl)) continue;
          seen.add(p.feedUrl);
          pool.push(p);
        }
        if (pool.length >= 10) break;
      }
    }
    Log.i('Repo', `电台候选 region=${region} count=${pool.length}`);
    if (pool.length === 0) return null;

    // 付费源常拿不到直链;全付费则放开
    let candidates = pool.filter((p: Podcast) => !p.isPaid);
    if (candidates.length === 0) candidates = pool;

    const picked = shuffle(candidates).slice(0, 6);
    const excludeSet = new Set<string>(exclude);
    for (let i = 0; i < picked.length; i++) {
      const podcast = picked[i];
      const feed = await this.feed(podcast.feedUrl);
      if (feed === null) continue;
      const usable = feed.episodes.filter((e: Episode) => e.audioUrl.length > 0 && !excludeSet.has(e.id));
      if (usable.length === 0) continue;
      const idx = Math.floor(Math.random() * usable.length);
      Log.i('Repo', `电台选中 region=${region} podcast="${podcast.title}"`);
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
