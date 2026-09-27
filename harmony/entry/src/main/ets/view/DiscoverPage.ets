import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { GuideEpisode } from '../store/GuideEpisode';
import { Features } from '../Features';
import { Recommended } from '../net/Recommended';
import { Podcast, Episode, SearchOutcome, HistoryEntry } from '../model/Models';
import { DISCOVER_CATEGORIES, DiscoverCategory, categoryLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { FeedProbeState } from '../net/PodcastRepository';
import { ScreenHeader, EmptyHint, LoadingBox, SquareArtwork, Glyph, GlyphImage, Sym } from './Widgets';
import { PodcastListItem, EpisodeListItem, ChipsRow, CHIPS_RESERVE_H, ChipsSwipeSync, LIST_MENU_LONG_PRESS_MS } from './Components';
import { RadioStation, RadioMode } from '../playback/RadioStation';
import { PlayerController } from '../playback/PlayerController';
import { SettingsStore } from '../store/SettingsStore';
import { SubscriptionStore, HistoryStore } from '../store/Stores';
import { InboxStore } from '../store/InboxStore';
import { TapGuard } from '../util/TapGuard';
import { Log } from '../util/Logger';

/// 发现页:分类热门榜(缓存秒开 + 后台刷新 + 下拉刷新)+ 搜索(节目/单集双分段)
/// + RSS 地址直接导入。对应 Android `DiscoverScreen.kt`。
@Component
export struct DiscoverPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 玻璃 tab 栏悬浮后,滚动内容需让出的底部空间(手势条+栏+迷你条,Index 算好传入)。
  /// 只用于各 List 的 contentEndOffset —— 最后一项要能滚出栏底、取得到,内容又要
  /// 从栏下经过玻璃才糊得出来。
  @Prop bottomPad: number = 0;
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
   * 与「音阁 · 最新」是同一份数据、两个入口 —— 不是各存一份。
   */
  @ObjectLink inbox: InboxStore;
  /// 单集行要显示"正在播放"高亮,故需观察播放态(只做渲染;playNext/enqueue 那种纯写走 app.player)
  @ObjectLink player: PlayerController;
  onOpenPodcast: (p: Podcast) => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[], tag: string) => void = () => {};

  @State catIndex: number = 0;
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
    const n = DISCOVER_CATEGORIES.length;
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
    // `CATALOG=false` 的降级渠道**不拉榜单** —— 那是内容目录请求,而且界面上压根不展示它。
    // 漏了这一句的后果不是报错,是"看不见的目录请求"仍然在发,抓包一看就露。
    if (Features.CATALOG) this.loadCategory(0, false);
    // 反过来,`CATALOG=false` 的降级渠道的首屏主体是「最新」,进页就得按需刷一次。
    // refreshIfStale 自带订阅集签名判断与防重入,和音阁那边同时调用不会重复拉。
    else this.refreshInbox(false);
  }

  /// 刷新「最新」。转圈状态一律读 store 的 inbox.refreshing —— 若在本页另置一个标志,
  /// 被重入拒绝的那次调用会把转圈提前关掉(Android 与音阁页都踩过,见 LibraryPage 同名方法)。
  private async refreshInbox(force: boolean): Promise<void> {
    const subs = this.subscriptions.subscriptions;
    if (subs.length === 0) return;
    if (force) await this.inbox.refresh(subs, this.app.repository);
    else await this.inbox.refreshIfStale(subs, this.app.repository);
    Log.i('Discover', `最新:当前 ${this.inbox.episodes.length} 条`);
  }

  /// 先取缓存秒显,再后台刷新。force=true 为下拉刷新(跳过缓存直接刷)。
  private async loadCategory(idx: number, force: boolean): Promise<void> {
    const cat: DiscoverCategory = DISCOVER_CATEGORIES[idx];
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
    // CATALOG=false 的降级包只接受 RSS 地址;输入别的就提示一句,不发请求。
    if (!Features.CATALOG && q.length > 0
      && !q.startsWith('http://') && !q.startsWith('https://')) {
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
    this.searchRssFailed = outcome.failed && (q.startsWith('http://') || q.startsWith('https://'));
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
            ForEach(DISCOVER_CATEGORIES, (cat: DiscoverCategory, idx: number) => {
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
            if (to < 0 || to >= DISCOVER_CATEGORIES.length) return;
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
            labels: DISCOVER_CATEGORIES.map((c: DiscoverCategory) => categoryLabel(c)),
            selected: this.chipSel,
            sync: this.chipSync,
            onSelect: (i: number) => {
              this.catIndex = i;
              this.chipSel = i;
              if (this.lists[i].length === 0) this.loadCategory(i, false);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
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
    return Math.max(0, Math.min(DISCOVER_CATEGORIES.length - 1, next));
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
   * 「最新」与「音阁 · 最新」是同一份 InboxStore,两个入口指向同一份数据 —— 有意保留,
   * 首屏看新内容、音阁做管理,各有其用。
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
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * 有订阅时的首屏:继续收听 + 最新更新 + 底部导入入口。
   *
   * 整屏是**一个 List**,继续收听横条与底部入口都作为列表项一起滚 ——
   * 分成"固定头 + 可滚列表"会在小屏上把最新更新压成一条缝。
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
          ForEach(this.inbox.episodes, (e: Episode) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: e,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === e.id,
                isPlaying: this.player.isPlaying,
                played: this.history.isPlayed(e.id),
                onPlay: () => this.onPlayEpisode(e, this.inbox.episodes, ''),
                onPlayNext: () => { this.app.player.playNext(e); },
                onEnqueue: () => { this.app.player.enqueue(e); }
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
                categoryLabel(DISCOVER_CATEGORIES[idx])))
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
          }, (h: HistoryEntry) => h.episode.id)
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
                  showPlayedToggle: true,
                  onTogglePlayed: () => { this.history.markPlayed(e.id, !this.history.isPlayed(e.id)); },
                  // 这两个只是**写**操作,不参与本页渲染,故可直接用容器里的单例;
                  // H26 说的"必须 @ObjectLink"针对的是**渲染读取**,不是这种纯动作。
                  onPlayNext: () => { this.app.player.playNext(e); },
                  onEnqueue: () => { this.app.player.enqueue(e); }
                })
              }
            }, (e: Episode) => e.id)
          }
          .scrollBar(BarState.Off)
          .contentEndOffset(this.bottomPad)
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

  /// 长按菜单的显示位 + 按下点在卡内的 x。走 `bindContextMenu(isShown, …)` 的状态驱动
  /// 重载,触发时长才归应用管(旧重载的识别在框架内部,装机反馈「长按阈值太长」)——
  /// 完整理由见 `Components.ets` 的 `LIST_MENU_LONG_PRESS_MS` 与 `EpisodeListItem`。
  @State menuShown: boolean = false;
  @State pressX: number = 0;

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
     * 长按菜单。**自己识别长按 + 状态驱动弹出**(与 Components.ets 的单集行同一套,
     * 理由与参数说明见彼处):`ResponseType.LongPress` 那个重载的触发时长在框架里改不动,
     * 装机反馈「长按弹出菜单的触发阈值太长」,换成 `bindContextMenu(isShown, …)` 之后
     * 时长由 `LIST_MENU_LONG_PRESS_MS` 决定(取 500ms,与 Android 同值)。
     *
     * `enableArrow: false` 才走"贴着锚点弹",带箭头会锚到组件横向正中;
     * `aboutToAppear/Disappear` 升降误触盾,挡掉"点外部关菜单"穿透下来的那一下;
     * Disappear 里同时把 `menuShown` 收回 false,否则下一次置 true 不产生状态变化。
     */
    .gesture(LongPressGesture({ duration: LIST_MENU_LONG_PRESS_MS })
      .onAction((event: GestureEvent) => {
        const f = event.fingerList.length > 0 ? event.fingerList[0] : null;
        this.pressX = f === null ? 0 : f.localX;
        this.menuShown = true;
      }))
    .bindContextMenu(this.menuShown, this.contextMenu(), {
      enableArrow: false,
      offset: { x: this.pressX, y: 0 },
      aboutToAppear: () => TapGuard.raise(),
      aboutToDisappear: () => { TapGuard.lowerSoon(); this.menuShown = false; }
    })
  }
}
