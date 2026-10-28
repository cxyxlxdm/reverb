import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { GuideEpisode } from '../store/GuideEpisode';
import { Features } from '../Features';
import { Recommended } from '../net/Recommended';
import { Podcast, Episode, SearchOutcome, HistoryEntry } from '../model/Models';
import { DISCOVER_CATEGORIES, DiscoverCategory, categoryLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { FeedProbeState } from '../net/PodcastRepository';
import { BilibiliSource } from '../net/BilibiliSource';
import { ScreenHeader, EmptyHint, LoadingBox, SquareArtwork, Glyph, GlyphImage, Sym } from './Widgets';
import { PodcastListItem, EpisodeListItem, ChipsRow, CHIPS_RESERVE_H, ChipsSwipeSync, LIST_MENU_LONG_PRESS_MS } from './Components';
import { RadioStation, RadioMode } from '../playback/RadioStation';
import { PlayerController } from '../playback/PlayerController';
import { SettingsStore } from '../store/SettingsStore';
import { SubscriptionStore, HistoryStore } from '../store/Stores';
import { InboxStore } from '../store/InboxStore';
import { TapGuard } from '../util/TapGuard';
import { Log } from '../util/Logger';

/**
 * 首屏「最新更新」这一节的条数上限(与 Android `DiscoverScreen.kt` 的 `HOME_LATEST_MAX` 同值)。
 * 两条理由见 `homeFeed` 注释。
 */
const HOME_LATEST_MAX = 20;

/// 发现页:分类热门榜(缓存秒开 + 后台刷新 + 下拉刷新)+ 搜索(节目/单集双分段)
/// + RSS 地址直接导入。对应 Android `DiscoverScreen.kt`。
@Component
export struct DiscoverPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 底部栏悬浮后,滚动内容需让出的底部空间(栏 + 手势区 + 播放条,Index 算好传入)。
  /// 只用于各 List 的 contentEndOffset —— 最后一项要能滚出栏底、取得到,内容又要
  /// 从栏下滚过才被糊出来(`barOverlap(true)`)。
  @Prop bottomPad: number = 0;
  /**
   * 把这一帧的滚动量(vp,向下为正)交给外壳,由它决定播放条收不收进栏(`Index.feedScroll`)。
   *
   * 每一处**竖向**滚动容器都要挂(`.onDidScroll`),漏一处就是从那一屏往下滚不收起 ——
   * 本页有五处(List:继续收听 / 最新 / 分类 / 电台 / …),另加一条横向 Scroll 与一个
   * 对话框内的 List **不挂**:前者不该触发收束,后者压根不在栏上方的内容里。
   */
  onScrollDy: (dy: number, st: ScrollState) => void = () => {};
  /// 见 LibraryPage 同名注释:驱动界面的 store 必须被观察,不能 `this.app.xxx` 直读。
  /// 电台按钮(图标/激活态/准备中)与「继续收听」都依赖它们。
  @ObjectLink settings: SettingsStore;
  @ObjectLink history: HistoryStore;
  /// 只用于判断"是不是全新用户"(决定引导卡显不显示)。必须是 @ObjectLink 而非直接读
  /// AppContainer 的裸对象 —— 否则订阅后返回本页,引导卡不会消失(同 H26 的坑)。
  @ObjectLink subscriptions: SubscriptionStore;
  @ObjectLink radio: RadioStation;
  /**
   * 「最新」聚合。`CATALOG=false` 的降级渠道下,**有订阅的人的首屏主体就是它**(见 subscribeStarter)。
   * 与顶层「追更」页(`FeedPage`)是**同一个 store**,但这一节只铺最新 [HOME_LATEST_MAX] 条
   * (`homeEpisodes()`);全量列表与翻到底的管理都在那一格。
   */
  @ObjectLink inbox: InboxStore;
  /// 单集行要显示"正在播放"高亮,故需观察播放态(只做渲染;playNext/enqueue 那种纯写走 app.player)
  @ObjectLink player: PlayerController;
  onOpenPodcast: (p: Podcast) => void = () => {};
  /**
   * 单集行**点封面**进频道页(与上面那颗不同:那颗拿的是已经有的 Podcast,这一颗只拿
   * `feedUrl`,由外壳去订阅里查、查不到合成最小种子)。与行上的 `showChannelJump` 成对传。
   */
  onOpenChannel: (feedUrl: string) => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[], tag: string) => void = () => {};

  @State catIndex: number = 0;
  /**
   * 分类表(**用户自定义顺序**)。`DISCOVER_CATEGORIES` 是默认序,这里的是它按
   * `AppContainer.categoryStore` 重排后的结果 —— 与 Android `DiscoverViewModel.orderedCategories` 同义。
   *
   * ⚠️ 页面里所有按下标取榜单的地方(`lists` / `loadingFlags` / `seedFlags`)都跟着**这一份**的顺序走,
   * 所以保存新顺序时必须把这三份数组一起按同一置换搬迁(见 `applyOrder`),
   * 否则「已经加载好的榜」会跟着位置错位,表现为点了 A 分类显示 B 的内容。
   */
  @State cats: DiscoverCategory[] = DISCOVER_CATEGORIES;
  /// 排序对话框:是否打开 / 草稿(打开时拷贝,取消不动原顺序)
  @State reorderShown: boolean = false;
  @State draft: DiscoverCategory[] = [];
  /// 正在拖的那一行的下标(-1 = 没在拖)与其视觉位移(vp)。口径同 Android 的拖动实现。
  @State dragIndex: number = -1;
  @State dragOffsetY: number = 0;
  /// 本次 Pan 相对上一次回调的增量基准(PanGesture 的 offsetY 是相对手势起点的累计值,
  /// 而每次换位都要把视觉位移减掉一格 —— 两者不同源,必须自己差分,否则会一次跳两行)。
  private dragLastCumulative: number = 0;
  /// chips 高亮专用索引,与驱动 Swiper `.index()` 的 catIndex 分开(理由见 LibraryPage 同名注释)
  @State chipSel: number = 0;
  /// 顶部分类条胶囊与 Swiper 的手势联动总线(每帧只重建胶囊,见 Components 注释)
  private chipSync: ChipsSwipeSync = new ChipsSwipeSync();
  /// Swiper 实测宽度,用于判断拖动是否过半
  @State pageW: number = 0;
  @State lists: Podcast[][] = [];          // 每个分类一份榜单
  @State loadingFlags: boolean[] = [];
  /// 该分类当前展示的是随包内置清单(非联网榜单)。内置清单是打包时的榜单快照,
  /// 标成「每日热门」会误导,故标题改为「内置精选」。
  @State seedFlags: boolean[] = [];
  @State refreshing: boolean = false;
  /// 「导入推荐订阅」进行中(`CATALOG=false` 的降级渠道的首屏动作)
  @State importing: boolean = false;
  /// 导入结果提示。沿用本项目既有形态(设置页的 hint)——内联一行文字,不用 toast。
  @State importHint: string = '';

  // 搜索
  @State query: string = '';
  @State searchingPodcasts: boolean = false;
  @State searchingEpisodes: boolean = false;
  @State searchTab: number = 0;            // 0 节目 / 1 单集
  @State searchPodcasts: Podcast[] = [];
  @State searchEpisodes: Episode[] = [];
  @State searchProbeStates: FeedProbeState[] = [];
  @State searchLabel: string = '';
  @State searchRssFailed: boolean = false;
  @State searched: boolean = false;
  // 网络返回顺序不可控;只允许最后一次提交的结果落到界面。
  private searchGeneration: number = 0;

  private app: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    this.cats = this.app.categoryStore.ordered();
    this.initSlots(this.cats.length);
    // `CATALOG=false` 的降级渠道**不拉榜单** —— 那是内容目录请求,而且界面上压根不展示它。
    // 漏了这一句的后果不是报错,是"看不见的目录请求"仍然在发,抓包一看就露。
    if (Features.CATALOG) this.loadCategory(0, false);
    // 反过来,`CATALOG=false` 的降级渠道的首屏主体是「最新」,进页就得按需刷一次。
    // refreshIfStale 自带订阅集签名判断与防重入,和音阁那边同时调用不会重复拉。
    else this.refreshInbox(false);
  }

  /// 三份按位置并行的数组(榜单 / 加载态 / 内置标记)按分类数开槽。
  private initSlots(n: number): void {
    const l: Podcast[][] = [];
    const f: boolean[] = [];
    const sd: boolean[] = [];
    for (let i = 0; i < n; i++) {
      l.push([]);
      f.push(false);
      sd.push(false);
    }
    this.lists = l;
    this.loadingFlags = f;
    this.seedFlags = sd;
  }

  /**
   * 应用新顺序:分类表与三份位置数组**一起**按同一置换搬迁,并把当前页跟到它的新下标。
   *
   * 为什么必须搬数组:这三份是「第 i 个分类的榜单/加载态/内置标记」,
   * 而 `i` 现在是按新顺序算的。只换 `cats` 不搬数组的话,把「科技」拖到第一位之后,
   * 第一页显示的是原来第 0 位(推荐)的内容 —— 分类名与内容错位。
   * 已加载的榜跟着分类走,重排不该触发任何网络请求。
   */
  private applyOrder(next: DiscoverCategory[]): void {
    const prev: DiscoverCategory[] = this.cats;
    const viewingKey: string = prev[this.catIndex] === undefined ? '' : prev[this.catIndex].key;
    const l: Podcast[][] = [];
    const f: boolean[] = [];
    const sd: boolean[] = [];
    for (let i = 0; i < next.length; i++) {
      const j = prev.findIndex((c: DiscoverCategory) => c.key === next[i].key);
      l.push(j < 0 ? [] : (this.lists[j] === undefined ? [] : this.lists[j]));
      f.push(j < 0 ? false : (this.loadingFlags[j] === undefined ? false : this.loadingFlags[j]));
      sd.push(j < 0 ? false : (this.seedFlags[j] === undefined ? false : this.seedFlags[j]));
    }
    this.cats = next;
    this.lists = l;
    this.loadingFlags = f;
    this.seedFlags = sd;
    const moved = next.findIndex((c: DiscoverCategory) => c.key === viewingKey);
    this.catIndex = moved < 0 ? 0 : moved;
    this.chipSel = this.catIndex;
    this.chipSync.end(this.catIndex);
    // 换位后当前页可能压根没加载过(原来排在后面的分类被拖到第一位且当前正停在这页)。
    if (this.lists[this.catIndex].length === 0) this.loadCategory(this.catIndex, false);
  }

  /// 打开排序框:草稿取当前顺序的副本,框内怎么拖都不影响线上顺序,点「保存」才落盘。
  private openReorder(): void {
    this.draft = this.cats.slice();
    this.dragIndex = -1;
    this.dragOffsetY = 0;
    this.reorderShown = true;
  }

  /// 落盘 + 应用。"空草稿不覆盖已有顺序"那条早退在 `CategoryStore.save` 里(同 Android 口径)。
  private saveReorder(): void {
    const keys: string[] = this.draft.map((c: DiscoverCategory) => c.key);
    this.app.categoryStore.save(keys);
    this.applyOrder(this.draft.slice());
    this.reorderShown = false;
    Log.i('Discover', `分类顺序已保存 ${keys.length} 项`);
  }

  private reorderRowHeight(): number {
    // Android 那一行的行高是 48dp;本端属**外壳**(不是字号那张等值表),
    // 按 1vp≈1.18dp 换算取 42vp(见 TROUBLESHOOTING 里"外壳按 0.876、字号不缩"那条口径)。
    return 42;
  }

  /**
   * Pan 增量 → 换位。算法与 Android `ReorderCategoriesDialog` 的 `onDrag` 逐句对应:
   * 视觉位移累计到 `dragOffsetY`,按整行高四舍五入得到目标位,换位后把已过的那几格
   * 从位移里减掉 —— 于是手指继续移动同样距离才换下一行,不会一次跳两行。
   *
   * ⚠️ 这三个方法**不能叫 `onDragStart` / `onDragEnd`**:它们是 `CustomComponent` 基类上
   * 已有的通用属性方法(组件原生拖拽的回调),成员方法同名会直接编译失败
   * (`Property 'onDragStart' in type ... is not assignable to the same property in base type`)。
   * 一次撞名就是一次整模块编译中断,所以统一加 `row` 前缀,一眼看出是"某一行的拖拽"。
   */
  private rowDragUpdate(cumulativeY: number): void {
    if (this.dragIndex < 0) return;
    const rowH = this.reorderRowHeight();
    this.dragOffsetY += cumulativeY - this.dragLastCumulative;
    this.dragLastCumulative = cumulativeY;
    const cur = this.dragIndex;
    const target = cur + Math.round(this.dragOffsetY / rowH);
    if (target === cur || target < 0 || target >= this.draft.length) return;
    const next: DiscoverCategory[] = this.draft.slice();
    const moved: DiscoverCategory[] = next.splice(cur, 1);
    if (moved.length === 0) return;
    next.splice(target, 0, moved[0]);
    this.draft = next;
    this.dragOffsetY -= (target - cur) * rowH;
    this.dragIndex = target;
  }

  /// 长按后开始拖:按下标取会过期(草稿刚换过位),按 key 取当前真实位置。同 Android 那条注释。
  private rowDragStart(c: DiscoverCategory, cumulativeY: number): void {
    this.dragIndex = this.draft.findIndex((x: DiscoverCategory) => x.key === c.key);
    // 差分基准取 Pan 起始那一刻的 offsetY(它是"相对按下位置"的累计量,序列手势里
    // 长按阶段手指已可能压掉 1~2vp),不能写死 0,否则第一帧就凭空多出一小段位移。
    this.dragLastCumulative = cumulativeY;
    this.dragOffsetY = 0;
  }

  private rowDragEnd(): void {
    this.dragIndex = -1;
    this.dragOffsetY = 0;
  }

  /// 刷新「最新」。转圈状态一律读 store 的 inbox.refreshing —— 若在本页另置一个标志,
  /// 被重入拒绝的那次调用会把转圈提前关掉(Android 与音阁页都踩过,见 LibraryPage 同名方法)。
  private async refreshInbox(force: boolean): Promise<void> {
    const subs = this.subscriptions.subscriptions;
    if (subs.length === 0) return;
    if (force) await this.inbox.refresh(subs, this.app.repository);
    else await this.inbox.refreshIfStale(subs, this.app.repository);
    // 这一行是装机读规模的入口:这一节铺多少 / store 全量多少,两个数都在
    Log.i('Discover', `最新一节=${Math.min(this.inbox.episodes.length, HOME_LATEST_MAX)} `
      + `追更全量=${this.inbox.episodes.length} 条`);
  }

  /**
   * 首屏这一节要铺的那一截:store 列表的**最新 [HOME_LATEST_MAX] 条**。
   *
   * 为什么在页面侧切而不是让 store 给两份:store 的列表已按发布时间倒序,`slice` 拿到的
   * 就是最新一截,不必再排一次;而全量归「追更」那一格,首屏只是预览。
   *
   * 写成方法而不是局部变量:`@Builder` 体内不能声明局部变量(编译器直接拒绝,见 H137),
   * 而这一节起播要把"屏上看到的这一截"当队列传下去,两处必须同一份口径。
   */
  private homeEpisodes(): Episode[] {
    return this.inbox.episodes.slice(0, HOME_LATEST_MAX);
  }

  /// 先取缓存秒显,再后台刷新。force=true 为下拉刷新(跳过缓存直接刷)。
  private async loadCategory(idx: number, force: boolean): Promise<void> {
    const cat: DiscoverCategory = this.cats[idx];
    const region = this.app.region();
    let hadCache = false;
    if (!force) {
      // 缓存为空时 cachedPopular 给出内置清单,同样能秒显,首屏不空
      const cached = this.app.repository.cachedPopular(cat.genreId, region);
      if (cached.length > 0) {
        this.setList(idx, cached);
        this.setSeed(idx, this.app.repository.isSeedList(cat.genreId, region));
        hadCache = true;   // 秒显后**继续往下走后台刷新**(不显转圈)
      }
    }
    if (!hadCache) this.setLoading(idx, true);
    const fresh = await this.app.repository.refreshPopular(cat.genreId, region);
    if (!hadCache) this.setLoading(idx, false);
    if (fresh.length > 0) {
      this.setList(idx, fresh);
      this.setSeed(idx, false);
    }
    Log.i('Discover', `分类 ${cat.key} 加载 ${fresh.length} 条`);
  }

  private setList(idx: number, list: Podcast[]): void {
    const next = this.lists.slice();
    next[idx] = list;
    this.lists = next;
  }

  private setSeed(idx: number, v: boolean): void {
    if (this.seedFlags[idx] === v) return;
    const next = this.seedFlags.slice();
    next[idx] = v;
    this.seedFlags = next;
  }

  private setLoading(idx: number, v: boolean): void {
    const next = this.loadingFlags.slice();
    next[idx] = v;
    this.loadingFlags = next;
  }

  private async runSearch(): Promise<void> {
    const q = this.query.trim();
    const generation = ++this.searchGeneration;
    // CATALOG=false 的降级包按「只接受地址」处理:http(s) 的订阅源,或一条视频地址
    // (完整链接 / 短链 / BV 号)。视频地址放行的理由与 `PodcastRepository.search` 那支相同 ——
    // 粘链接是用户点名的那一条,不是"下拉就能翻到的目录",不构成动态目录。
    if (!Features.CATALOG && q.length > 0
      && !q.startsWith('http://') && !q.startsWith('https://')
      && !BilibiliSource.looksLikeVideo(q)) {
      this.searchingPodcasts = false;
      this.searchingEpisodes = false;
      this.searched = false;
      this.importHint = L.s('search_url_only');
      return;
    }
    if (q.length === 0) {
      this.searchingPodcasts = false;
      this.searchingEpisodes = false;
      this.searched = false;
      this.searchPodcasts = [];
      this.searchEpisodes = [];
      this.searchProbeStates = [];
      this.searchRssFailed = false;
      return;
    }

    this.importHint = '';
    this.searched = true;
    this.searchingPodcasts = true;
    this.searchingEpisodes = true;
    this.searchPodcasts = [];
    this.searchEpisodes = [];
    this.searchProbeStates = [];
    this.searchLabel = '';
    this.searchRssFailed = false;
    const region = this.app.region();
    // 两类检索并行且各自落 UI；不再先等节目、再等单集，任一完成都能立即显示。
    const podcastsWork = this.loadSearchPodcasts(q, region, generation);
    const episodesWork = this.loadSearchEpisodes(q, region, generation);
    await Promise.all([podcastsWork, episodesWork]);
  }

  private async loadSearchPodcasts(q: string, region: string, generation: number): Promise<void> {
    let outcome: SearchOutcome = { podcasts: [], sourceLabel: '', failed: true };
    try {
      outcome = await this.app.repository.search(q, region);
    } catch (_e) {
      Log.w('Discover', '节目搜索异常');
    }
    if (generation !== this.searchGeneration || this.query.trim() !== q) return;
    this.searchPodcasts = outcome.podcasts;
    this.searchLabel = outcome.sourceLabel;
    // 视频地址解析失败**不是**「RSS 导入失败」——那条文案讲的是订阅源地址无效(与 Android
    // 同一口径:它那边也只是一句「没有找到相关节目」)。所以这一档只留给纯 RSS 地址。
    this.searchRssFailed = outcome.failed
      && (q.startsWith('http://') || q.startsWith('https://'))
      && !BilibiliSource.looksLikeVideo(q);
    this.searchingPodcasts = false;
    Log.i('Discover', `节目搜索完成 count=${outcome.podcasts.length} 源=${outcome.sourceLabel}`);
    await this.probeSearchPodcasts(outcome.podcasts, q, generation);
  }

  private async loadSearchEpisodes(q: string, region: string, generation: number): Promise<void> {
    let episodes: Episode[] = [];
    try {
      episodes = await this.app.repository.searchEpisodes(q, region);
    } catch (_e) {
      Log.w('Discover', '单集搜索异常');
    }
    if (generation !== this.searchGeneration || this.query.trim() !== q) return;
    this.searchEpisodes = episodes;
    this.searchingEpisodes = false;
    Log.i('Discover', `单集搜索完成 count=${episodes.length}`);
  }

  /** 前四条预检，固定两个 worker；第五条以后保持未检测且可点击。 */
  private async probeSearchPodcasts(podcasts: Podcast[], q: string, generation: number): Promise<void> {
    const limit = Math.min(4, podcasts.length);
    const initial: FeedProbeState[] = [];
    for (let i = 0; i < podcasts.length; i++) {
      if (i >= limit) {
        initial.push(FeedProbeState.UNCHECKED);
        continue;
      }
      const state = this.app.repository.feedProbeState(podcasts[i].feedUrl);
      initial.push(state === FeedProbeState.UNCHECKED ? FeedProbeState.CHECKING : state);
    }
    if (generation !== this.searchGeneration || this.query.trim() !== q) return;
    this.searchProbeStates = initial;

    let next = 0;
    const worker = async (): Promise<void> => {
      while (true) {
        // 新搜索只允许已在网络中的任务自然走到硬截止；旧 worker 不再领取后续条目。
        if (generation !== this.searchGeneration || this.query.trim() !== q) return;
        const index = next;
        next += 1;
        if (index >= limit) return;
        const state = this.app.repository.feedProbeState(podcasts[index].feedUrl);
        if (state === FeedProbeState.AVAILABLE || state === FeedProbeState.UNREACHABLE) {
          this.setSearchProbeState(index, state, q, generation);
          continue;
        }
        this.setSearchProbeState(index, FeedProbeState.CHECKING, q, generation);
        let available = false;
        try {
          available = await this.app.repository.probeFeed(podcasts[index].feedUrl);
        } catch (_e) {
          Log.w('Discover', 'RSS 预检异常');
        }
        this.setSearchProbeState(index,
          available ? FeedProbeState.AVAILABLE : FeedProbeState.UNREACHABLE, q, generation);
      }
    };
    const pool: Promise<void>[] = [];
    for (let i = 0; i < Math.min(2, limit); i++) pool.push(worker());
    await Promise.all(pool);
  }

  private setSearchProbeState(index: number, state: FeedProbeState, q: string, generation: number): void {
    if (generation !== this.searchGeneration || this.query.trim() !== q) return;
    const next = this.searchProbeStates.slice();
    next[index] = state;
    this.searchProbeStates = next;
  }

  private searchProbeState(index: number): FeedProbeState {
    const state = this.searchProbeStates[index];
    return state === undefined ? FeedProbeState.UNCHECKED : state;
  }

  private searchProbeLabel(index: number): string {
    const state = this.searchProbeState(index);
    if (state === FeedProbeState.CHECKING) return L.s('search_probe_checking');
    if (state === FeedProbeState.AVAILABLE) return L.s('search_probe_available');
    if (state === FeedProbeState.UNREACHABLE) return L.s('search_probe_unreachable');
    return '';
  }

  private clearSearchResults(): void {
    this.searchGeneration += 1;
    this.searchingPodcasts = false;
    this.searchingEpisodes = false;
    this.searched = false;
    this.searchPodcasts = [];
    this.searchEpisodes = [];
    this.searchProbeStates = [];
    this.searchLabel = '';
    this.searchRssFailed = false;
  }

  build() {
    Stack() {
      Column() {
        ScreenHeader({
          scheme: this.scheme,
          fontScale: this.fontScale,
          // 与 Android 一致:发现页顶部是**应用名 + slogan**,不是「发现」二字
          // (「发现」只作底部 tab 的标签)。
          title: L.s('app_title'),
          subtitle: L.s('app_slogan'),
          // 电台是**内容推荐**功能,`CATALOG=false` 的降级渠道不出现(见 Features.CATALOG)
          action: () => { this.headerAction() }
        })

        this.searchBar()

        if (this.searched) {
          this.searchResults()
        } else if (!Features.CATALOG) {
          // 无内容目录:首屏就是「导入推荐订阅」+ 继续收听 + 引导卡,
          // 不出现任何可浏览的节目目录(分类榜 / 电台 / 内置清单一律没有)。
          this.subscribeStarter()
        } else {
          // 玻璃分段条悬浮在内容上,内容从条下滚过(与底部玻璃栏同思路);
          // 顶部余量由榜单 List 的第一个占位 ListItem 给,高度用 CHIPS_RESERVE_H
          // (比条的盒子高,原因见 Components.ets 该常量注释)。
          Stack({ alignContent: Alignment.Top }) {
            Swiper() {
              ForEach(this.cats, (cat: DiscoverCategory, idx: number) => {
                this.categoryPage(idx)
              }, (cat: DiscoverCategory) => cat.key)
            }
            .index(this.catIndex)
            .loop(false)
            .indicator(false)
            .cachedCount(1)
            .onAreaChange((_o: Area, n: Area) => { this.pageW = Number(n.width); })
            // chips 高亮跟着手指走(位移过半即切),只改 chipSel、不碰 catIndex —— 详见 LibraryPage 注释
            .onGestureSwipe((index: number, e: SwiperAnimationEvent) => {
              this.chipSel = this.dragTarget(index, e.currentOffset);
              // 胶囊 1:1 联动:插值目标取拖动方向的相邻页,与过半预切的 dragTarget 无关 ——
              // 拖 30% 就该走 30% 路程;边缘橡皮筋(相邻页不存在)不报,胶囊原地不动。
              // currentOffset 实测是**当前页相对其锚点的带符号位移**:向左滑(去下一页,
              // 序号+1)为负、向右滑为正 —— 与既有 dragTarget 的方向约定一致
              // (offset < 0 ? index+1 : index-1)。若按"负=往前一页"理解,0→1 的拖动
              // 会被 to<0 的边缘保护整个吞掉,胶囊纹丝不动(踩过)。
              if (this.pageW <= 0) return;
              const to = index + (e.currentOffset < 0 ? 1 : -1);
              if (to < 0 || to >= this.cats.length) return;
              this.chipSync.report(index, to,
                Math.min(1, Math.abs(e.currentOffset) / this.pageW));
            })
            .onAnimationStart((_i: number, target: number) => {
              this.chipSel = target;
              // 动画一开始就收束胶囊:提交时随落位弹簧过去,回落时原地弹回 ——
              // 都不等 onAnimationEnd,否则手势帧已停,胶囊会僵在插值位直到动画结束
              this.chipSync.end(target);
            })
            .onAnimationEnd((_i: number, _e: SwiperAnimationEvent) => {
              // 兜底:回落若不触发 onAnimationStart,靠这里把胶囊从插值位收回来(幂等)
              this.chipSync.end(this.chipSel);
            })
            // 榜单加载**只在落位后**做:放到 gestureSwipe/animationStart 会让快速连滑时
            // 每划过一页都发一次网络请求。
            .onChange((i: number) => {
              this.catIndex = i;
              this.chipSel = i;
              if (this.lists[i].length === 0) this.loadCategory(i, false);
            })
            .width('100%')
            .height('100%')

            ChipsRow({
              scheme: this.scheme,
              fontScale: this.fontScale,
              labels: this.cats.map((c: DiscoverCategory) => categoryLabel(c)),
              selected: this.chipSel,
              sync: this.chipSync,
              onSelect: (i: number) => {
                this.catIndex = i;
                this.chipSel = i;
                if (this.lists[i].length === 0) this.loadCategory(i, false);
              },
              // Android 在同一颗分段条的右端放了「自定义分类排序」的入口(Trailing
              // `Icons.Rounded.Tune`),本端此前完全没有这个入口 ⇒ 分类顺序只能吃默认序。
              endAction: () => { this.reorderButton() }
            })
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')

      // 分类排序框(与 Android 的发现页 endAction 同义):草稿态在页内,保存才落盘。
      if (this.reorderShown) {
        this.reorderDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  /// 拖动位移 → 目标页(过半才切,并夹在合法范围)。符号不写死,用绝对值 + 方向判断。
  private dragTarget(index: number, offset: number): number {
    if (this.pageW <= 0) return index;
    if (Math.abs(offset) < this.pageW / 2) return index;
    const next = offset < 0 ? index + 1 : index - 1;
    return Math.max(0, Math.min(this.cats.length - 1, next));
  }

  /// 分段条右端的排序入口。图标与 Android 同一颗(`Icons.Rounded.Tune` = `slider_horizontal_2`)、
  /// 同一档尺寸与留白(20 / 左右 16 / 上下 12),按钮不自带背景 —— 底就是这条玻璃(见 ChipsRow 注释)。
  @Builder
  reorderButton() {
    Glyph({ symbol: Sym.speed, dim: 20, color: this.scheme.onSurfaceVariant })
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .accessibilityText(L.s('reorder_title'))
      .onClick(() => this.openReorder())
  }

  private closeReorder(): void {
    this.reorderShown = false;
    this.dragIndex = -1;
    this.dragOffsetY = 0;
  }

  /// 草稿列表的高度:按行数出来,最高不超过 380vp(再高就把按钮挤出屏外,框内自己滚)。
  private reorderListHeight(): number {
    return Math.min(this.draft.length * this.reorderRowHeight(), 380);
  }

  /**
   * 自定义分类排序框。**逐句对应** Android `ReorderCategoriesDialog`:
   * 标题 / 一行提示 / 48dp(本端 42vp)一行、右端拖拽装饰 / 「取消 + 完成」两颗文字按钮,
   * 长按后拖动、换位按整行高四舍五入(算法见 `rowDragUpdate`)。
   *
   * ⚠️ 与 Android 的一处已知差别:这里的遮罩覆盖的是**发现页区域**,底部玻璃 tab 栏仍浮在
   * 遮罩之上(Android 的 AlertDialog 是整窗)。要把框提到整窗,得让它长在 Index 上,
   * 而现在没有任何别的页面需要它 —— 先如实记着,不做半吊子搬运。
   */
  @Builder
  reorderDialog() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(withAlpha('#000000', 0.45))
        .onClick(() => this.closeReorder())

      Column() {
        Text(L.s('reorder_title'))
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .fontColor(this.scheme.onBackground)
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: 8 })
        Text(L.s('reorder_hint'))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: 10 })

        List({ space: 0 }) {
          ForEach(this.draft, (c: DiscoverCategory, i: number) => {
            ListItem() {
              Row() {
                Text(categoryLabel(c))
                  .fontSize(TypeScale.body * this.fontScale)
                  .fontColor(this.scheme.onBackground)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Glyph({ symbol: Sym.dragHandle, dim: 18, color: this.scheme.onSurfaceVariant })
              }
              .width('100%')
              .height(this.reorderRowHeight())
              .padding({ left: 6, right: 8 })
              .borderRadius(8)
              .backgroundColor(this.dragIndex === i ? this.scheme.surfaceVariant : Color.Transparent)
            }
            .zIndex(this.dragIndex === i ? 1 : 0)
            .translate({ y: this.dragIndex === i ? this.dragOffsetY : 0 })
            // 长按 → 拖:与 Android 的 `detectDragGesturesAfterLongPress` 同一条手势路径。
            // 用 priorityGesture 而不是 gesture:框内是 List,普通手势会被父滚动抢走,
            // 于是"拖行"变成"滚框",一次换位都做不成。
            .priorityGesture(
              GestureGroup(GestureMode.Sequence,
                LongPressGesture({ duration: LIST_MENU_LONG_PRESS_MS }),
                PanGesture({ direction: PanDirection.Vertical, distance: 1 })
                  .onActionStart((e: GestureEvent) => this.rowDragStart(c, e.offsetY))
                  .onActionUpdate((e: GestureEvent) => this.rowDragUpdate(e.offsetY))
                  .onActionEnd(() => this.rowDragEnd())
                  .onActionCancel(() => this.rowDragEnd())
              )
            )
          }, (c: DiscoverCategory) => c.key)
        }
        .width('100%')
        .height(this.reorderListHeight())
        .scrollBar(BarState.Off)
        .cachedCount(0)

        Row({ space: 22 }) {
          Text(L.s('action_cancel'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .onClick(() => this.closeReorder())
          Text(L.s('action_done'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.primary)
            .onClick(() => this.saveReorder())
        }
        .margin({ top: 18 })
        .alignSelf(ItemAlign.End)
      }
      .width('78%')
      .padding({ left: 22, right: 22, top: 22, bottom: 16 })
      .backgroundColor(this.scheme.surface)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .zIndex(20)
  }

  /// 情境电台的时段图标。**分界与 Android `contextualRadioIcon()` 逐段一致**:
  /// 5–10 晨曦 / 11–16 白日 / 17–19 黄昏 / 其余 夜。
  /// 注:`RadioStation.contextualPhase()` 的文字分界(5–8/9–17/18–21)与此不同,
  /// 它只用于长按提示,不参与这里的图标选择 —— 两端图标口径以 Android 为准。
  private radioIcon(): Resource {
    if (!this.settings.contextualRadio) return Sym.shuffle;
    const h = new Date().getHours();
    if (h >= 5 && h <= 10) return Sym.twilight;
    if (h >= 11 && h <= 16) return Sym.sun;
    if (h >= 17 && h <= 19) return Sym.twilight;
    return Sym.moon;
  }

  /// 电台按钮:未开台点击开台;在台时点击换下一首,长按停台。
  /// 与 Android `RadioActionButton` 一致 —— **只有一个图标**,不带时段文字;
  /// 随机模式用 Shuffle,情境模式用时段图标。原先用喇叭图标 + "白日"这类文字,是自创的。
  @Builder
  radioButton() {
    Row({ space: 5 }) {
      if (this.radio.preparing !== null) {
        LoadingProgress().width(18).height(18).color(this.scheme.primary)
      } else {
        Glyph({
          symbol: this.radioIcon(), dim: 21,
          color: this.radio.mode !== null ? this.scheme.primary : this.scheme.onSurfaceVariant
        })
      }
    }
    .alignItems(VerticalAlign.Center)
    .accessibilityText(L.s(this.radio.mode !== null ? 'radio_next' : 'radio_start'))
    .onClick(() => {
      const region = this.app.region();
      if (this.radio.mode !== null) {
        this.radio.skip(region);
      } else {
        const mode = this.settings.contextualRadio ? RadioMode.CONTEXTUAL : RadioMode.RANDOM;
        this.radio.start(mode, region);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (this.radio.mode !== null) this.radio.stop();
    }))
  }

  /// 顶部右侧动作。有内容目录时是电台按钮;没有则留空(不能整块删掉 —— ScreenHeader 要求这个插槽)。
  @Builder
  headerAction() {
    if (Features.CATALOG) {
      this.radioButton()
    }
  }

  /**
   * `CATALOG=false` 的降级渠道的首屏主体,**按有没有订阅分成两种布局**。
   *
   * 为什么分叉:原先不论有没有订阅,首屏顶着一大块「从添加订阅开始 + 导入推荐订阅」——
   * 那是给零订阅的新用户看的引导,一个已有几十个订阅的人每次打开都先看见它,很怪。
   *
   * 分叉后:
   *  - **零订阅** → 保持引导(标题 + 说明 + 导入按钮 + 引导卡),这本来就是它的场景;
   *  - **有订阅** → 首屏变成"你自己的内容流":继续收听 + 最新更新,
   *    导入入口降级成列表底部一行,仍然可用。
   *
   * 这样做**没有放宽合规口径**:展示的全是用户自己订阅的内容,不是可浏览的第三方节目目录
   * (分类榜 / 电台 / 关键词检索一律仍然不存在,见 Features.CATALOG)。
   *
   * 这一节的「最新」与顶层「追更」页(`FeedPage`)是**同一个 InboxStore**,但这一节只铺
   * 最新 `HOME_LATEST_MAX` 条(为什么切、以及为什么这一节下面那个导入入口还能够得到,见 `homeFeed`)。
   * 两个入口指向同一个数据源是有意保留:首屏是"打开就看到",追更页是这一列自己的管理入口
   * (标题栏那颗模式按钮按 `inbox` 存这一列的模式;这一节起播传空 tag,读不到那个模式)。
   */
  @Builder
  subscribeStarter() {
    if (this.subscriptions.subscriptions.length === 0) {
      this.starterOnboarding()
    } else {
      this.homeFeed()
    }
  }

  /**
   * 零订阅时的引导。
   *
   * 导入是**整份导入 + 结果提示**,不做"列出来让你挑"的中间页 —— 那等于把目录搬回应用里。
   * 导入后这些频道就是用户自己的订阅,在「音阁 · 订阅」里管理,与手动粘贴地址订阅的没有区别。
   */
  @Builder
  starterOnboarding() {
    List() {
      ListItem() {
        Column({ space: 6 }) {
          Text(L.s('starter_title'))
            .fontSize(TypeScale.titleSmall * this.fontScale)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.scheme.onBackground)
            .width('100%')
          Text(L.s('starter_desc'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .lineHeight(TypeScale.caption * this.fontScale * 1.6)
            .width('100%')
          Button(this.importing ? L.s('importing') : L.s('import_recommended'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onPrimary)
            .backgroundColor(this.scheme.primary)
            .width('100%')
            .enabled(!this.importing)
            .margin({ top: 8 })
            .onClick(() => this.doImportRecommended())
          if (this.importHint.length > 0) {
            Text(this.importHint)
              .fontSize(TypeScale.caption * this.fontScale)
              .fontColor(this.scheme.primary)
              .width('100%')
              .margin({ top: 8 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 8 })
      }
      if (this.showGuide()) {
        ListItem() {
          this.guideCard()
        }
      }
      if (this.continueEntries().length > 0) {
        ListItem() {
          this.continueStrip()
        }
      }
    }
    .scrollBar(BarState.Off)
    .contentEndOffset(this.bottomPad)
    .onDidScroll((dy: number, st: ScrollState): void => this.onScrollDy(dy, st))
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * 有订阅时的首屏:继续收听 + 最新更新(最新 `HOME_LATEST_MAX` 条)+ 底部导入入口。
   *
   * 整屏是**一个 List**,继续收听横条与底部入口都作为列表项一起滚 ——
   * 分成"固定头 + 可滚列表"会在小屏上把最新更新压成一条缝。
   *
   * 这一节**只铺一截**而不是全量(2026-10-10 store 改成内存全量之后必须做的配套):
   *  1. 它的下面还挂着「导入更多」那一行,全量之后被顶到几千行以下,再也够不着;
   *  2. 这一节的定位是"打开就看到有新内容"的预览,列表管理与往下翻都在中间那一格(「追更」)。
   * 切的是排序后的前缀,所以这一节看到的就是最新的那几条,与追更页开头逐条一致。
   */
  @Builder
  homeFeed() {
    Refresh({ refreshing: this.inbox.refreshing }) {
      List() {
        if (this.continueEntries().length > 0) {
          ListItem() {
            this.continueStrip()
          }
        }
        ListItem() {
          Text(L.s('home_latest'))
            .fontSize(TypeScale.titleSmall * this.fontScale)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.scheme.onBackground)
            .width('100%')
            .padding({ left: Metrics.pagePadding, top: 4, bottom: 6 })
        }
        if (this.inbox.episodes.length > 0) {
          ForEach(this.homeEpisodes(), (e: Episode) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: e,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === e.id,
                isPlaying: this.player.isPlaying,
                played: this.history.isPlayed(e.id),
                onPlay: () => this.onPlayEpisode(e, this.homeEpisodes(), ''),
                onPlayNext: () => { this.app.player.playNext(e); },
                onEnqueue: () => { this.app.player.enqueue(e); },
                // 封面单独可点 → 这一集所属频道页(与 Android 的 DiscoverScreen 同口径:
                // 那边由 CompositionLocal 提供入口,本端要显式传开关 + 动作这一对)。
                // 这一列**不给多选**:它是"打开就看到"的预览,批量入口在顶层「追更」页。
                showChannelJump: true, onOpenChannel: this.onOpenChannel
              })
            }
          }, (e: Episode) => e.id)
        } else {
          ListItem() {
            // 有订阅但还没聚合出内容:首刷进行中就转圈,刷完仍为空才给空态
            if (this.inbox.refreshing) {
              LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
            } else {
              EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('empty_inbox') })
            }
          }
        }
        ListItem() {
          this.addMoreFooter()
        }
      }
      .scrollBar(BarState.Off)
      .contentEndOffset(this.bottomPad)
      .onDidScroll((dy: number, st: ScrollState): void => this.onScrollDy(dy, st))
      .width('100%').height('100%')
    }
    .onRefreshing(() => { this.refreshInbox(true); })
    .width('100%')
    .layoutWeight(1)
  }

  /// 列表底部那行不显眼的导入入口。刻意做成文字按钮而不是通栏大按钮 ——
  /// 对已有订阅的人,这是个偶尔才用一次的东西。
  @Builder
  addMoreFooter() {
    Column({ space: 6 }) {
      Divider()
        .strokeWidth(0.5)
        .color(withAlpha(this.scheme.outline, 0.6))
        .margin({ bottom: 10 })
      Text(this.importing ? L.s('importing') : L.s('import_recommended'))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.importing ? this.scheme.onSurfaceVariant : this.scheme.primary)
        .onClick(() => this.doImportRecommended())
      if (this.importHint.length > 0) {
        Text(this.importHint)
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.primary)
      }
      Text(L.f('starter_have_subs', this.subscriptions.subscriptions.length))
        .fontSize(TypeScale.caption * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 6, bottom: 20 })
    .alignItems(HorizontalAlign.Center)
  }

  private async doImportRecommended(): Promise<void> {
    if (this.importing) return;
    this.importHint = '';
    this.importing = true;
    const n = await Recommended.importAll(this.app);
    this.importing = false;
    if (n > 0) {
      this.importHint = L.f('import_done', n);
      // 订阅集变了,「最新」要跟着重聚合 —— 否则刚导入完首屏还是空的,
      // 得等用户去一趟音阁才刷。不 await:提示先上屏,聚合在后台跑。
      this.refreshInbox(false);
    } else if (n === 0) {
      this.importHint = L.s('import_none');
    } else {
      this.importHint = L.s('import_failed');
    }
  }

  @Builder
  searchBar() {
    /**
     * 横向留白由**外层容器的 padding** 给,不要在搜索框自己身上写 margin。
     *
     * 原先是 `width('100%')` + `margin({ left: 16, right: 16 })` —— 真机上**右侧留白整个丢了**,
     * 圆角直接顶在屏幕边缘。ArkUI 里百分比宽度按父容器**内容宽**算出 100%,margin 再加在外面:
     * 左 margin 把它往右推,右 margin 没有东西可顶,于是整块溢出右缘。
     * 换成外层 Column 给 padding、内层 `width('100%')`,百分比就按"父内容宽 − padding"算,
     * 两侧才对称。
     *
     * 同样的写法在下面的 guideCard 也有一处,一并改了。**凡是 `width('100%')` 配横向 margin
     * 都是这个坑**,以后要么给外层加 padding,要么别写 100%。
     */
    Column() {
    // 图标 20、间距 12:原先 18 / 8 确实太挤(图标几乎贴着文字),但按 Material 给到
    // 24 / 16 又太胀 —— 那是 Android 的规范值,本机逻辑宽度更窄,照抄就显大(见 bottomBar 注释)。
    // 20 / 12 是两端观感之间的取值。**文字**是另一码事:仍按绝对物理尺寸对齐 Android 的
    // bodyLarge(16),字号是可读性常量,不随平台缩。
    Row({ space: 12 }) {
      Image($r('sys.media.ohos_ic_public_search_filled'))
        .width(20).height(20)
        .fillColor(this.scheme.onSurfaceVariant)
      TextInput({
        placeholder: Features.CATALOG ? L.s('search_placeholder') : L.s('search_hint_url'),
        text: this.query
      })
        .placeholderColor(this.scheme.onSurfaceVariant)
        .fontColor(this.scheme.onBackground)
        .fontSize(TypeScale.bodyLarge * this.fontScale)
        .backgroundColor(Color.Transparent)
        .borderRadius(0)
        .padding(0)
        .layoutWeight(1)
        .onChange((v: string) => {
          if (v !== this.query && this.searched) this.clearSearchResults();
          this.query = v;
        })
        .onSubmit(() => { this.runSearch(); })
      if (this.query.length > 0) {
        Text(L.s('action_cancel'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.primary)
          .onClick(() => {
            this.clearSearchResults();
            this.query = '';
          })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.10))
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
    .margin({ bottom: 8 })
  }

  /// 分类页:下拉刷新 + **单列列表**(与 Android 一致,非宫格),
  /// 首项为「继续收听」横条(有未播完历史时),其后是「每日热门 · X」小标题与频道行。
  @Builder
  categoryPage(idx: number) {
    Refresh({ refreshing: this.refreshing }) {
      Column() {
        if (this.loadingFlags[idx] && this.lists[idx].length === 0) {
          LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
        } else if (this.lists[idx].length === 0) {
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('discover_empty') })
        } else {
          List() {
            // 顶部占位:给玻璃分段条让出高度。不用 contentStartOffset —— 实测它是
            // 「初始滚动位」语义而不是内容留白:列表随数据到位重建后首项会被顶到条背后,
            // 静止时只剩一条缝露在条外。占位 ListItem 是纯布局,保证首项停在条下方。
            ListItem() {
              Row().width('100%').height(CHIPS_RESERVE_H)
            }
            if (this.continueEntries().length > 0) {
              ListItem() {
                this.continueStrip()
              }
            } else if (this.showGuide()) {
              ListItem() {
                this.guideCard()
              }
            }
            ListItem() {
              Text(L.f(this.seedFlags[idx] ? 'discover_seed_list' : 'discover_daily_hot',
                categoryLabel(this.cats[idx])))
                .fontSize(TypeScale.caption * this.fontScale)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.scheme.onSurfaceVariant)
                .padding({ left: Metrics.pagePadding, top: 4, bottom: 4 })
            }
            ForEach(this.lists[idx], (p: Podcast) => {
              ListItem() {
                PodcastListItem({
                  scheme: this.scheme, fontScale: this.fontScale, podcast: p,
                  onTap: () => this.onOpenPodcast(p)
                })
              }
            }, (p: Podcast) => p.id)
          }
          .scrollBar(BarState.Off)
          .contentEndOffset(this.bottomPad)
          .onDidScroll((dy: number, st: ScrollState): void => this.onScrollDy(dy, st))
          .width('100%').height('100%')
        }
      }
      .width('100%').height('100%')
    }
    .onRefreshing(() => {
      this.refreshing = true;
      this.loadCategory(idx, true).then(() => { this.refreshing = false; });
    })
    .width('100%')
    .height('100%')
  }

  /// 未播完的历史:进度在 10s ~ 95% 且未标记已播完,最新在前,最多 15 条(与 Android 同口径)。
  private continueEntries(): HistoryEntry[] {
    return this.history.history.filter((h: HistoryEntry) => {
      if (h.played) return false;
      if (h.positionMs < 10000 || h.durationMs <= 0) return false;
      return h.positionMs < h.durationMs * 0.95;
    }).slice(0, 15);
  }

  /// 全新用户(既没订阅也没听过任何东西)才展示引导入口。
  /// 一旦有任何使用痕迹就不再出现 —— 它是引导,不是常驻功能。
  private showGuide(): boolean {
    return GuideEpisode.available()
      && this.subscriptions.subscriptions.length === 0
      && this.history.history.length === 0;
  }

  /// 首次使用时的引导卡:点一下播放随包内置的 30 秒音频。
  /// 意义是让「全新安装 + 没网」也能走通完整播放链路,而不是对着空白猜是 App 坏了还是网不通。
  @Builder
  guideCard() {
    // 横向留白同样由外层 padding 给 —— `width('100%')` 配横向 margin 会丢右侧留白,
    // 详见 searchBar 注释。
    Column() {
    Row({ space: 12 }) {
      // 用 sys.media 的标准播放件而非 Symbol 字体:Symbol 名要到真机字体里才解析,
      // 写错不报错、直接空白渲染。这个件播放页已在用,确认可渲。
      GlyphImage({ icon: $r('sys.media.ohos_ic_public_play'), dim: 22, color: this.scheme.primary })
      Column({ space: 2 }) {
        Text(L.s('guide_title'))
          .fontSize(TypeScale.body * this.fontScale)
          .fontColor(this.scheme.onBackground)
        Text(L.s('guide_card_sub'))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(withAlpha(this.scheme.primary, 0.08))
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.onPlayEpisode(GuideEpisode.make(), [GuideEpisode.make()], ''))
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
    .margin({ bottom: 4 })
  }

  /// 继续收听:横滑卡片,点按续播;长按出菜单(从这条横里去掉 = 标记已播完)。
  @Builder
  continueStrip() {
    Column({ space: 6 }) {
      // 小标题用灰色常规体(对齐 Android 的 labelMedium / onSurfaceVariant)——
      // 它是"这一条横滑是什么"的注脚,不该跟「最新更新」那种分节标题一样重。
      Text(L.s('continue_listening'))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
        .padding({ left: Metrics.pagePadding })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.continueEntries(), (h: HistoryEntry) => {
            ContinueCard({
              scheme: this.scheme,
              fontScale: this.fontScale,
              episode: h.episode,
              positionMs: h.positionMs,
              durationMs: h.durationMs,
              onPlay: () => this.onPlayEpisode(h.episode, this.continueEntries().map((x: HistoryEntry) => x.episode), ''),
              onPlayNext: () => { this.app.player.playNext(h.episode); },
              onEnqueue: () => { this.app.player.enqueue(h.episode); },
              onMarkPlayed: () => { this.history.markPlayed(h.episode.id, true); }
            })
          }, (h: HistoryEntry) => `${h.episode.id}|${Math.round(h.positionMs / h.durationMs * 100)}`)
          /**
           * 键值里带**百分数进度**,否则这张卡的进度条整场都不动:进度每 5 秒写回 store,
           * 数组换了新的、键没换,ForEach 就不重跑 itemGenerator,卡上的 `positionMs`
           * 停在卡片创建那一刻(实测:拖到 79.6% 再切走切回,绿点仍在最左边,见 H154)。
           *
           * 为什么按 1% 取整而不是直接放 `positionMs`:进度是每 5 秒一跳的高频量,
           * 键每跳一次就重建一次卡片(硬规矩 7 的反面)。条子本身只有 1% 的分辨率,
           * 再细的变化界面根本画不出来 —— 90 分钟的集取整后大约一分钟才重建一次,
           * 而且只有正在播的那一张会变。
           */
        }
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 4, bottom: 10 })
  }

  @Builder
  searchResults() {
    Column() {
      // 分段:节目 / 单集
      Row({ space: 8 }) {
        this.searchTabChip(L.s('tab_shows'), this.searchPodcasts.length, 0)
        this.searchTabChip(L.s('tab_episodes'), this.searchEpisodes.length, 1)
        Blank()
        if (this.searchLabel.length > 0) {
          Text(L.f('search_from', this.searchLabel))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
        }
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      if (this.searchTab === 0) {
        if (this.searchingPodcasts && this.searchPodcasts.length === 0) {
          LoadingBox({ scheme: this.scheme, fontScale: this.fontScale }).layoutWeight(1)
        } else if (this.searchPodcasts.length === 0) {
          EmptyHint({
            scheme: this.scheme,
            fontScale: this.fontScale,
            text: this.searchRssFailed ? L.s('search_rss_failed') : L.s('search_no_shows')
          }).layoutWeight(1)
        } else {
          List() {
            ForEach(this.searchPodcasts, (p: Podcast, idx: number) => {
              ListItem() {
                PodcastListItem({
                  scheme: this.scheme,
                  fontScale: this.fontScale,
                  podcast: p,
                  status: this.searchProbeLabel(idx),
                  statusError: this.searchProbeState(idx) === FeedProbeState.UNREACHABLE,
                  tapEnabled: this.searchProbeState(idx) === FeedProbeState.UNCHECKED
                    || this.searchProbeState(idx) === FeedProbeState.AVAILABLE,
                  onTap: () => this.onOpenPodcast(p)
                })
              }
            }, (p: Podcast) => p.id)
          }
          .scrollBar(BarState.Off)
          .contentEndOffset(this.bottomPad)
          .onDidScroll((dy: number, st: ScrollState): void => this.onScrollDy(dy, st))
          .layoutWeight(1)
        }
      } else {
        if (this.searchingEpisodes && this.searchEpisodes.length === 0) {
          LoadingBox({ scheme: this.scheme, fontScale: this.fontScale }).layoutWeight(1)
        } else if (this.searchEpisodes.length === 0) {
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('search_no_episodes') }).layoutWeight(1)
        } else {
          List() {
            ForEach(this.searchEpisodes, (e: Episode) => {
              ListItem() {
                EpisodeListItem({
                  scheme: this.scheme, fontScale: this.fontScale, episode: e,
                  showPodcastTitle: true,
                  // 正在播的那一集要高亮(标题转强调色、封面上的图标变暂停)。
                  // 这两个此前漏传,搜索结果里点播后看不出播的是哪一条 —— Android 一直是传的。
                  isCurrent: this.player.current !== null && this.player.current.id === e.id,
                  isPlaying: this.player.isPlaying,
                  played: this.history.isPlayed(e.id),
                  onPlay: () => this.onPlayEpisode(e, this.searchEpisodes, ''),
                  // 2026-10-17 起不给「标记已播完」(与 Android 同批摘掉):这一列是临时视图,
                  // 标完不重排、看不出归属变化,而没播过的集在 HistoryStore 里没有条目、
                  // markPlayed 当场 return ⇒ 大多数结果是**静默空操作**。
                  // `played` 的显示(标题压暗 + 打勾)保留。口径见 Components.ets 的 showPlayedToggle。
                  // 这两个只是**写**操作,不参与本页渲染,故可直接用容器里的单例;
                  // H26 说的"必须 @ObjectLink"针对的是**渲染读取**,不是这种纯动作。
                  onPlayNext: () => { this.app.player.playNext(e); },
                  onEnqueue: () => { this.app.player.enqueue(e); },
                  // 搜索结果里的每一条都来自**别的频道**,而显示频道名不等于能进那个频道。
                  // 多选同样不开(与首页那一节同口径:结果列表是临时视图,批量入口在四个常驻列)。
                  showChannelJump: true, onOpenChannel: this.onOpenChannel
                })
              }
            }, (e: Episode) => e.id)
          }
          .scrollBar(BarState.Off)
          .contentEndOffset(this.bottomPad)
          .onDidScroll((dy: number, st: ScrollState): void => this.onScrollDy(dy, st))
          .layoutWeight(1)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  searchTabChip(label: string, count: number, idx: number) {
    Text(count > 0 ? `${label} ${count}` : label)
      .fontSize(TypeScale.labelLarge * this.fontScale)
      .fontColor(this.searchTab === idx ? this.scheme.onPrimary : this.scheme.onSurfaceVariant)
      .backgroundColor(this.searchTab === idx ? this.scheme.primary : withAlpha(this.scheme.onSurfaceVariant, 0.10))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(14)
      .onClick(() => { this.searchTab = idx; })
  }
}

/**
 * 「继续收听」的一张卡:封面 + 两行标题 + 细进度条。点按续播,长按出菜单。
 *
 * **为什么单独成一个组件**:与 Android 的 `ContinueCard` 对齐 —— 同一张卡在两个端
 * 有着陆在同一个粒度的节点上,菜单/按压态这类交互才不会一端改一端漏。
 *
 * **不像是因为"页面 @Builder 里的裸节点弹不出菜单"** —— 那个结论是我早先误判的,
 * 撤回。当时"怎么都不弹"的真实原因有两条,都在下面这两处修掉了(取证与规律见 H100):
 * ① 卡片里 `SquareArtwork` 的 `Image` 自带长按-拖拽识别器,按在封面上那一下被它吃掉;
 * ② 同一节点上另挂 `.gesture(LongPressGesture())` 会抢走 `bindContextMenu` 的长按。
 */
@Component
struct ContinueCard {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop episode: Episode;
  @Prop positionMs: number;
  @Prop durationMs: number;
  onPlay: () => void = () => {};
  onPlayNext: () => void = () => {};
  onEnqueue: () => void = () => {};
  /// 从这条横里去掉 —— 就是「标记已播完」,见 contextMenu 注释。
  onMarkPlayed: () => void = () => {};

  /// 长按菜单的显示位 + 按下点在卡内的位置(x 与 y)。走 `bindContextMenu(isShown, …)`
  /// 的状态驱动重载,触发时长才归应用管(旧重载的识别在框架内部,装机反馈「长按阈值太长」)——
  /// 完整理由见 `Components.ets` 的 `LIST_MENU_LONG_PRESS_MS` 与 `EpisodeListItem`。
  ///
  /// 这两个值喂给锚点的 `.position()`,不是喂给 `options.offset` —— 后者在这个重载上
  /// 实测**根本不生效**(证据与推导写在 build 里锚点那段注释,装机反馈「菜单太靠下了」)。
  @State menuShown: boolean = false;
  @State pressX: number = 0;
  @State pressY: number = 0;

  /// 菜单项字体:labelLarge(14) 常规体。与 Components.ets 的 EpisodeListItem 同档 ——
  /// ArkUI 菜单默认字号偏大且不跟主题,全应用的菜单要长一个样。
  private menuFont(): Font {
    return { size: TypeScale.labelLarge * this.fontScale, weight: FontWeight.Normal };
  }

  /**
   * 长按菜单。**三项与 macOS 的 `EpisodeContextMenu` 一一对应**(macOS 上这张卡
   * 早就挂了右键菜单),鸿蒙与 Android 补齐才算同构 —— 同一张卡在三个端给不同的动作,
   * 是这张卡最容易漂的地方。
   *
   * 「删除」在这里的措辞就是「标记已播完」:这一条的数据源**就是历史列表**
   * (进度 10s~95% 且未播完),所以 markPlayed 一置它当场从横条消失,而进度仍留在
   * 音阁 · 历史里,从那里「标记未播完」即可复原(那一项是本轮补的 —— 历史页此前
   * 没开这个开关,「可逆」就只是纸面上的,见 H101)。
   * 为什么不叫"删除"、也不给 HistoryStore 加 remove:①"删除"字面上指向历史条目本身,
   * 而用户要的只是"这条别再占着首屏";②真删历史三端各要加一个 API 且不可反悔,
   * 按本仓库惯例就得配确认弹窗 —— 而 app 里没有撤销先例。用现成的可逆语义绕开这一整串。
   */
  @Builder
  contextMenu() {
    Menu() {
      MenuItem({ content: L.s('queue_play_next') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.onPlayNext())
      MenuItem({ content: L.s('queue_add') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => {
          this.onEnqueue();
          // 入队结果在别页,这里界面上没有任何变化 —— 不提示等于没按上(同 Components.ets)
          this.getUIContext().getPromptAction().showToast({ message: L.s('queue_added') });
        })
      // 卡片能出现在这条横里就说明它未播完(过滤条件如此),所以只给单向的
      // 「标记已播完」,不做行组件那个 已播/未播 来回切换。
      MenuItem({ content: L.s('mark_played') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.onMarkPlayed())
    }
    .backgroundColor(this.scheme.surface)
    .radius(12)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 6 }) {
        SquareArtwork({ scheme: this.scheme, url: this.episode.artworkUrl, corner: 12 })
        Text(this.episode.title)
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onBackground)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        /**
         * 细进度条。轨道用 surfaceVariant(与 Android 的 trackColor 同),
         * **不要用 onSurfaceVariant 加透明度** —— 那样轨道在深色底上几乎看不见,
         * 于是刚开始听(进度 1%~15%)时整条进度条只剩左端一个绿点,像屏幕上落了灰,
         * 读不出"这集听到哪了"。有底槽才有进度可读。
         */
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(3)
            .backgroundColor(this.scheme.surfaceVariant).borderRadius(2)
          Row().width(`${Math.min(100, this.positionMs / this.durationMs * 100)}%`).height(3)
            .backgroundColor(this.scheme.primary).borderRadius(2)
        }
        .width('100%').height(3)
      }
      // 132 而非 112:与 Android 卡宽一致。112 太窄,两行标题基本只够放七八个字,
      // 每张卡都以省略号收尾。
      .width(132)
      .onClick(() => this.onPlay())
      /**
       * 长按识别。**自己识别长按 + 状态驱动弹出**(与 Components.ets 的单集行同一套):
       * `ResponseType.LongPress` 那个重载的触发时长在框架里改不动,装机反馈
       * 「长按弹出菜单的触发阈值太长」,换成 `bindContextMenu(isShown, …)` 之后
       * 时长由 `LIST_MENU_LONG_PRESS_MS` 决定(取 500ms,与 Android 同值)。
       * 这里只负责**记下按下点并置位**,菜单不绑在卡上(绑在下面的锚点上)。
       */
      .gesture(LongPressGesture({ duration: LIST_MENU_LONG_PRESS_MS })
        .onAction((event: GestureEvent) => {
          const f = event.fingerList.length > 0 ? event.fingerList[0] : null;
          this.pressX = f === null ? 0 : f.localX;
          this.pressY = f === null ? 0 : f.localY;
          this.menuShown = true;
        }))

      /**
       * 菜单的锚点:一个 1×1 的透明节点,`.position()` 挪到按下点,菜单绑在它身上。
       *
       * **为什么不用 `options.offset` 直接挪菜单**:装机实测 —— 状态驱动的
       * `bindContextMenu(isShown, …)` **完全不读 `offset`**。把按下点算进去(局部坐标
       * 与卡高都取对了,`onAreaChange` 报 172.85vp 与 dumpLayout 的卡高 562px/3.25 一致)
       * 菜单分毫不动;再退一步把 offset 写成常量 `{x:30, y:-50}`,位置仍然一模一样。
       * 于是"菜单永远贴着卡片下沿"(默认 `Placement.BottomLeft`),这就是装机反馈的
       * 「长按菜单太靠下了」。
       *
       * 改成挪**节点**而不是挪**菜单**:`.position()` 是常规布局属性,状态变了确实会重排,
       * 而菜单相对锚点的位置由框架算 —— 与 Android 那边把零尺寸 Box 挪到 `pressPoint`
       * 是同一个做法(见 `DiscoverScreen.kt` 的 ContinueCard)。
       * 顺带把横向也修好了:原先 offset 不生效,菜单永远贴卡的左缘,按在最右那张卡上
       * 时整块菜单会被挤出屏幕右侧。
       *
       * `hitTestBehavior(None)` 是必须的:锚点画在卡之上,不关掉命中就会在手指处
       * 挡出一个 1×1 的死区(而且它跟着手指跑,死区会留在上一次按下的地方)。
       *
       * ✅ 装机验过的一条(2026-09-29,BRA-AL00):按下点太低、菜单放不下时框架会**自动翻到
       * 上方**,而横向**仍然跟着手指**(整宽行按 (600,2500) → 菜单 `[600,2136][1091,2474]`,
       * 左缘正好 600)。SDK 那句"翻转之后位置由框架定"说的是 `offset` 失效,不是节点位置 ——
       * 这正是要挪**节点**而不是挪**菜单**的另一条理由。
       * 菜单顶边实测恒在按下点下方 29px(≈9vp),是框架给锚点留的间距,不是误差累积;
       * 与 Android 一样"贴着手指下方弹",不再盖住手指按的那一行。
       */
      Column()
        .width(1).height(1)
        .position({ x: this.pressX, y: this.pressY })
        .hitTestBehavior(HitTestMode.None)
        .bindContextMenu(this.menuShown, this.contextMenu(), {
          // enableArrow 必须是 false:带箭头时 ArkUI 把菜单**锚到组件横向正中**,
          // 挪不动不说,还和"贴着手指弹"这件事互相矛盾。
          enableArrow: false,
          aboutToAppear: () => TapGuard.raise(),
          aboutToDisappear: () => { TapGuard.lowerSoon(); this.menuShown = false; }
        })
    }
    .width(132)
  }
}
