import { Theme, Scheme, TypeScale, Tracking, Metrics, withAlpha } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { SubscriptionStore, FavoriteStore, HistoryStore } from '../store/Stores';
import { InboxStore } from '../store/InboxStore';
import { DownloadStore } from '../store/DownloadStore';
import { StampStore } from '../store/StampStore';
import { ListenStatsStore } from '../store/ListenStatsStore';
import { DownloadManager } from '../playback/DownloadManager';
import { RadioStation } from '../playback/RadioStation';
import { AppContainer } from '../AppContainer';
import { ScreenHeader, EmptyHint, Glyph, Sym } from '../view/Widgets';
import { DiscoverPage } from '../view/DiscoverPage';
import { FeedPage } from '../view/FeedPage';
import { PodcastDetailPage } from '../view/PodcastDetailPage';
import { NoteStore, EpisodeNote } from '../store/NoteStore';
import { PlayerPage } from '../view/PlayerPage';
import { MiniPlayerBar } from '../view/MiniPlayerBar';
import {
  SystemTabItem, TAB_BAR_H, TAB_KEY, MORPH_KEY, MORPH_SLOPE,
  MINI_H, MINI_GAP, morphSpring, barReserve
} from '../view/BottomBar';
import { LibraryPage } from '../view/LibraryPage';
import { SettingsPage } from '../view/SettingsPage';
import { PrivacyConsentPage } from '../view/PrivacyConsentPage';
import { ListenStatsPage } from '../view/ListenStatsPage';
import { QueuePage } from '../view/QueuePage';
import { FootprintPage } from '../view/FootprintPage';
import { AboutPage } from '../view/AboutPage';
import { LicensesPage } from '../view/LicensesPage';
import { PlayerController } from '../playback/PlayerController';
import { Podcast, Episode, emptyPodcast } from '../model/Models';
import { Log } from '../util/Logger';
import type common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { TapGuard } from '../util/TapGuard';

/// 顶层外壳:Navigation 承载全屏页(频道详情等),内页是「发现 / 追更 / 音阁」三 tab。
/// 与 Android 一致的取舍:全屏页整体转场,底部栏不产生占位跳动。
@Entry
@Component
struct Index {
  /**
   * 各 store 一律由外壳以 `@State` 持有、再以 `@ObjectLink` 下发给页面。
   *
   * 为什么不让页面自己 `AppContainer.get().xxx` 取(那样代码更短):那样拿到的是
   * **未被 ArkUI 观察**的裸对象,改了字段页面不会重渲。音阁的宫格切换/清空历史/删除下载、
   * 「追更」(2026-10-08 之前它是音阁的「最新」段)刷新结果上屏,以及设置页的配色,都曾因此
   * 点了没反应 —— 有些看着正常,
   * 只是恰好被别的 `@State` 变化(切分段、关对话框、播放状态 tick)顺带刷新了,属偶然。
   * 详见 TROUBLESHOOTING H26 / H27。
   */
  @State settings: SettingsStore = AppContainer.get().settings;
  @State subscriptions: SubscriptionStore = AppContainer.get().subscriptions;
  @State favorites: FavoriteStore = AppContainer.get().favorites;
  @State history: HistoryStore = AppContainer.get().history;
  @State inbox: InboxStore = AppContainer.get().inbox;
  @State downloads: DownloadStore = AppContainer.get().downloads;
  @State stamps: StampStore = AppContainer.get().stamps;
  /// 批注(音阁第 6 段的数据源)。必须是 @State:它在 播放页写、音阁列表读,
  /// 裸对象赋值观察不到(H27)。
  @State notes: NoteStore = AppContainer.get().notes;
  @State listenStats: ListenStatsStore = AppContainer.get().listenStats;
  @State downloadManager: DownloadManager = AppContainer.get().downloadManager;
  @State radio: RadioStation = AppContainer.get().radio;
  /**
   * 当前 tab。**放 AppStorage 而不是 @State**:底部栏的三项是 Tabs 用 CustomBuilder 生成的,
   * 它们自己订阅这个键(见 `BottomBar.SystemTabItem`),不依赖"父级 build 有没有重跑"。
   */
  @StorageLink(TAB_KEY) tab: number = 0;
  /**
   * 播放条是否收束进底部栏。同样走 AppStorage(栏项要读),这里 @StorageLink 是**写的一侧**:
   * 滚动累计量到阈值就翻它,见 [feedScroll]。
   */
  @StorageLink(MORPH_KEY) collapsed: boolean = false;
  /// 收/展的累计滚动量(vp)。只在 [feedScroll] 里读写,不进状态、不触发重渲。
  private morphAcc: number = 0;
  /**
   * 设备此刻是否深色。**由 EntryAbility 写 AppStorage**(启动种一次,系统切深浅时在
   * `onConfigurationUpdate` 里再写),这里只 @StorageLink 读 —— 理由见 `Theme.SYSTEM_DARK_KEY`。
   * @Watch 那一下是给状态栏/导航条的:它们不在组件树里,主题跟着翻了、图标色不会自己翻。
   */
  @StorageLink(Theme.SYSTEM_DARK_KEY) @Watch('onSystemDarkChanged') systemDark: boolean = false;
  @State stack: NavPathStack = new NavPathStack();
  /// 当前要展示的频道(进详情页前设置;ArkTS 的 NavPathStack 传参用 param,这里用状态更直观)
  @State detailSeed: Podcast = emptyPodcast();
  /// 状态栏 / 导航条避让高度(px→vp)。窗口设了全屏布局,故需自行避让。
  @State topInset: number = 0;
  @State bottomInset: number = 0;
  @State player: PlayerController = PlayerController.get();
  /// 播放状态变化触发重渲的计数(PlayerController 非 @Observed 字段级追踪,用它兜底刷新)
  @State tick: number = 0;
  /// 长按菜单开着(以及刚关掉那一瞬)—— 整屏盖一层「误触盾」,见 TapGuard。
  @StorageLink('tapShield') tapShield: boolean = false;

  aboutToAppear(): void {
    // getContext() 已废弃,API 12+ 用 UIContext 取宿主 context
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const app = AppContainer.get();
    app.boot(ctx);
    this.player = app.player;
    // 播放状态变化时驱动界面刷新
    const prev = app.player.onStateChanged;
    app.player.onStateChanged = () => {
      if (prev !== null) prev();
      this.tick = this.tick + 1;
      // 已经没有播放条了,收束标志必须跟着清:否则下次起播时栏项一上来就是淡没状态,
      // 界面上看就是"底部栏空了半条"
      if (this.collapsed && this.player.current === null) this.collapsed = false;
    };
    this.readInsets();
    this.applySystemBar();
    Log.i('UI', `外壳就绪 systemDark=${this.systemDark}`);
  }

  /**
   * 系统深浅色翻转(经 AppStorage 传过来)之后要补的一件事。
   * 主题本身是 `scheme()` 现算的,整树重建会跟着翻;唯一不在组件树里的是状态栏与
   * 导航条的**图标颜色**,它不会自己翻,必须重设(否则深色图标压在水墨底上糊成一团)。
   */
  private onSystemDarkChanged(): void {
    this.applySystemBar();
  }

  /// 读状态栏与手势导航条高度,换算为 vp 作内边距(避免页头压住状态栏)。
  private readInsets(): void {
    try {
      const win = window.getLastWindow(this.getUIContext().getHostContext());
      win.then((w: window.Window) => {
        const ui = this.getUIContext();
        const top = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const nav = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.topInset = ui.px2vp(top.topRect.height);
        this.bottomInset = ui.px2vp(nav.bottomRect.height);
        Log.i('UI', `避让 top=${this.topInset} bottom=${this.bottomInset}`);
      }).catch((e: Error) => {
        Log.w('UI', `读取避让区失败 ${e.message}`);
      });
    } catch (e) {
      Log.w('UI', '读取避让区异常');
    }
  }

  /**
   * 把状态栏/导航条的**内容色**调成与当前主题相反,否则在沉浸式下看不见。
   *
   * 应用开了 `setWindowLayoutFullScreen(true)`,内容铺到状态栏底下;但系统栏图标的颜色
   * **不会跟着应用背景自动变** —— 默认是为浅色背景准备的深色图标,压在水墨深色底上
   * 几乎不可见(时间/WiFi/电量全糊成一团)。必须显式声明:深色主题用白色内容,浅色用黑色。
   *
   * 主题可在设置里随时改,所以除了启动,`onChanged` 里也要再调一次。
   */
  private applySystemBar(): void {
    const light = this.scheme().isDark ? '#FFFFFF' : '#000000';
    try {
      window.getLastWindow(this.getUIContext().getHostContext()).then((w: window.Window) => {
        w.setWindowSystemBarProperties({
          statusBarContentColor: light,
          navigationBarContentColor: light
        }).catch((e: Error) => {
          Log.w('UI', `设置系统栏内容色失败 ${e.message}`);
        });
      }).catch((e: Error) => {
        Log.w('UI', `取窗口失败 ${e.message}`);
      });
    } catch (e) {
      Log.w('UI', '设置系统栏内容色异常');
    }
  }

  private scheme(): Scheme {
    return Theme.scheme(this.settings.themeMode, this.settings.accentIndex, this.systemDark);
  }

  private fontScale(): number {
    return Theme.fontScale(this.settings.fontIndex);
  }

  private openPodcast(p: Podcast): void {
    this.detailSeed = p;
    this.stack.pushPathByName('podcast', null);
  }

  /**
   * 从播放页跳频道主页。播放中的单集只带 `feedUrl`,这里把它还原成一个 Podcast 种子。
   *
   * 先在订阅里找现成的 —— 已订阅的频道能立刻显示作者与简介,不必等 RSS 回来。
   * 找不到(从「最新」或电台播的、还没订阅的频道)就用单集信息拼一个最小种子:
   * **详情页只依赖 `seed.feedUrl` 去取 RSS**,其余字段拉到之后会被 `loaded` 整体覆盖,
   * 所以这个种子只需要够撑住第一帧不空白。
   */
  private openPodcastByFeed(feedUrl: string): void {
    if (feedUrl.length === 0) return;
    const subs: Podcast[] = this.subscriptions.subscriptions;
    const idx: number = subs.findIndex((p: Podcast) => p.feedUrl === feedUrl);
    if (idx >= 0) {
      this.openPodcast(subs[idx]);
      return;
    }
    const seed: Podcast = emptyPodcast();
    seed.feedUrl = feedUrl;
    seed.id = feedUrl;
    const e: Episode | null = this.player.current;
    if (e !== null) {
      seed.title = e.podcastTitle;
      seed.artworkUrl = e.artworkUrl;
    }
    this.openPodcast(seed);
  }

  /**
   * 列表行内点某一集起播。
   *
   * @param tag 这一列的身份("inbox" / "fav" / "dl" / "podcast:<feedUrl>"),不属于任何
   *   可见列表的入口传空串。**必须一路传到 `playOrToggle`** —— 少了它,从某一集起播之后
   *   分段条/频道主页那颗播放按钮认不出「这颗按钮管的就是正在播的这一段」,
   *   点它会回到「从头播这一段」而不是切播放模式(Android 侧同一处踩过,
   *   见 `PlayerController.playOrToggle` 的注释)。
   */
  private playEpisode(e: Episode, queue: Episode[], tag: string): void {
    Log.i('UI', `播放 "${e.title}" 队列=${queue.length} tag='${tag}'`);
    this.player.playOrToggle(e, queue, tag);
  }

  /**
   * 音阁 · 批注那一行:从**批注记下的那一秒**起播,不是从上次听到的位置。
   *
   * 走 `playAt` 而不是 `playOrToggle`:后者第一句就是"同一集则暂停/继续" ——
   * 正在播这一集时点批注会被判成按了暂停。与 Android 侧同一分岔(那边是 `playAt` vs `play`)。
   */
  private playNote(n: EpisodeNote): void {
    Log.i('UI', `播放批注 @${n.positionMs}ms "${n.episode.title}"`);
    this.player.playAt(n.episode, n.positionMs);
  }

  build() {
    // 未同意隐私政策时**整棵界面树只有同意页** —— 发现页一进来就会拉榜单,
    // 只要它没被渲染,同意前就一个网络请求都不会发生(平台合规指引)。
    if (!this.settings.privacyAccepted) {
      PrivacyConsentPage({
        scheme: this.scheme(),
        fontScale: this.fontScale(),
        // 本页在 shell() 之外,吃不到那里的避让内边距,只能把 inset 传进去自己让
        topInset: this.topInset,
        bottomInset: this.bottomInset,
        onAccept: () => this.acceptPrivacy(),
        onDecline: () => this.exitApp()
      })
    } else {
      // Stack 的作用只有一个:让「误触盾」盖在 Navigation **之上** ——
      // 这样连 NavDestination(频道详情、播放页、队列)一起罩住,盾只需这一处。
      Stack() {
        Navigation(this.stack) {
          this.shell()
        }
        .navDestination(this.destination)
        .mode(NavigationMode.Stack)
        .hideTitleBar(true)
        .width('100%')
        .height('100%')
        .backgroundColor(this.scheme().background)

        if (this.tapShield) {
          // 全透明、只吃事件。`HitTestMode.Block` = 自己响应,兄弟节点(Navigation)不响应。
          // 接到那一下就立刻自我撤除,免得某条路径漏了 lowerSoon 把界面点死(见 TapGuard)。
          Row()
            .width('100%').height('100%')
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { TapGuard.lower(); })
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /// 同意:落盘后立刻装配此前被门控的组件,再让界面切到主树。
  private acceptPrivacy(): void {
    this.settings.acceptPrivacy();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppContainer.get().startGated(ctx);
    // settings 是 @State 持有的 @Observed 对象,acceptPrivacy 改了字段即触发重渲
  }

  /// 不同意:退出应用。本应用没有可脱离网络使用的核心功能,不提供残缺状态。
  private exitApp(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.terminateSelf();
    } catch (e) {
      Log.w('App', `退出失败 ${(e as Error).message}`);
    }
  }

  @Builder
  destination(name: string, _param: object) {
    if (name === 'settings') {
      NavDestination() {
        SettingsPage({
          scheme: this.scheme(),
          fontScale: this.fontScale(),
          // 传对象本体:设置页以 @ObjectLink 观察它,改了字段本页才会重渲(见 SettingsPage 注释)
          settings: this.settings,
          onBack: () => { this.stack.pop(); },
          onChanged: () => {
            this.tick = this.tick + 1;
            // 主题可能刚被改过,系统栏内容色要跟着翻
            this.applySystemBar();
          },
          onOpenAbout: () => { this.stack.pushPathByName('about', null); },
          onOpenLicenses: () => { this.stack.pushPathByName('licenses', null); },
          // 听觉足迹入口移到设置页(与 Android 一致),音阁页头不再放
          onOpenFootprint: () => { this.stack.pushPathByName('footprint', null); }
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'player') {
      NavDestination() {
        PlayerPage({
          scheme: this.scheme(),
          fontScale: this.fontScale(),
          player: this.player,
          favorites: this.favorites,
          stamps: this.stamps,
          settings: this.settings,
          onBack: () => { this.stack.pop(); },
          onOpenQueue: () => { this.stack.pushPathByName('queue', null); },
          onOpenPodcast: (feedUrl: string) => { this.openPodcastByFeed(feedUrl); }
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'listen_stats') {
      NavDestination() {
        ListenStatsPage({
          scheme: this.scheme(), fontScale: this.fontScale(),
          listenStats: this.listenStats,
          onBack: () => { this.stack.pop(); }
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'about') {
      NavDestination() {
        AboutPage({
          scheme: this.scheme(), fontScale: this.fontScale(),
          onBack: () => { this.stack.pop(); }
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'licenses') {
      NavDestination() {
        LicensesPage({
          scheme: this.scheme(), fontScale: this.fontScale(),
          onBack: () => { this.stack.pop(); }
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'footprint') {
      NavDestination() {
        FootprintPage({
          scheme: this.scheme(), fontScale: this.fontScale(),
          stamps: this.stamps,
          onBack: () => { this.stack.pop(); }
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'queue') {
      NavDestination() {
        QueuePage({
          scheme: this.scheme(), fontScale: this.fontScale(),
          player: this.player,
          onBack: () => { this.stack.pop(); }
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'podcast') {
      NavDestination() {
        Column() {
          PodcastDetailPage({
            scheme: this.scheme(),
            fontScale: this.fontScale(),
            seed: this.detailSeed,
            subscriptions: this.subscriptions,
            downloadManager: this.downloadManager,
            history: this.history,
            listenStats: this.listenStats,
            // 单集行的「正在播放」高亮要读播放态
            player: this.player,
            onBack: () => { this.stack.pop(); },
            onPlayEpisode: (e: Episode, q: Episode[], tag: string) => this.playEpisode(e, q, tag)
          })
            .layoutWeight(1)
          if (this.player.current !== null) {
            MiniPlayerBar({
              scheme: this.scheme(),
              fontScale: this.fontScale(),
              player: this.player,
              onExpand: () => { this.stack.pushPathByName('player', null); },
              onOpenQueue: () => { this.stack.pushPathByName('queue', null); }
            })
          }
        }
        .width('100%').height('100%')
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
  }

  /**
   * 三个 tab 页的滚动都汇到这里(页面各自在滚动容器上挂 `.onDidScroll` 再传上来)。
   *
   * 口径与参考对象一致:**往下滚(看后面的内容)收束,往上滚展开**。
   * 判据用**累计量**而不是单帧量 —— `onDidScroll` 每帧给的是这一帧滚了多少,
   * 惯性滑动里一帧只有 1–8vp,按单帧判阈值要么一碰就翻、要么永远不翻。
   * 每次翻转后清零,所以"往回滚 40vp"要重新攒满,不会在临界点来回抖。
   *
   * ⚠️ 这个回调**每帧都跑**,所以里面只许有加减法和一次布尔比较(硬规矩 6)。
   * 真正被改的状态只有 `collapsed`,而它只让栏项的 opacity 与播放条的四个几何量重算,
   * 不动列表数据、也不让页面重新 measure(让位量按展开态恒定,见 [underBarPad])。
   */
  private feedScroll(dy: number): void {
    if (this.player.current === null) return;
    this.morphAcc += dy;
    if (this.morphAcc >= MORPH_SLOPE) {
      this.morphAcc = 0;
      // 显式判重再赋值:连续往下滚会反复越过阈值,而"同值也要写进 AppStorage"会让三个
      // 栏项和播放条每攒满 40vp 就白重算一遍
      if (!this.collapsed) this.collapsed = true;
    } else if (this.morphAcc <= -MORPH_SLOPE) {
      this.morphAcc = 0;
      if (this.collapsed) this.collapsed = false;
    }
  }

  /// 收束态左端那颗回主页:只把播放条放回两行共存,不改当前 tab(它不是"回发现页")。
  private expandMini(): void {
    this.morphAcc = 0;
    this.collapsed = false;
  }

  /**
   * 播放条这一整块距屏底的落点。
   *
   * - 展开:抬到栏**上方**再留 8vp 缝(参考片实测那两道 26px);
   * - 收束:落进栏那 56vp 里,于是只剩手势区那一道。
   *
   * 栏本体由 Tabs 画,它下面垫的是 `padding({bottom: bottomInset})`
   * (见 [shell] 里那句注释),所以两种落点都以"屏底往上 bottomInset"为基准,不用自己算栏高。
   */
  private miniBottom(): number {
    return this.collapsed ? this.bottomInset : this.bottomInset + TAB_BAR_H + MINI_GAP;
  }

  /**
   * 页面滚动内容需为底部悬浮层让出的空间 = 栏高 + 手势区 + 播放条(展开态那一档)。
   *
   * 式子收在 `BottomBar.barReserve` 里,和栏自己的几何同源 —— 收小留白时最容易漏这一处,
   * 漏了列表末尾多出一条空白(或者末项被栏压住)。
   *
   * ⚠️ **不含 collapsed**:收束时播放条整块落进栏里,本可以少让 68vp,但那样每次翻转都要
   * 重排整条列表,而翻转恰恰发生在滚动中。宁可末尾多一条空白。
   */
  private underBarPad(): number {
    return barReserve(this.bottomInset, this.player.current !== null);
  }

  /// 三个 tab 项的栏内容。@Builder 只负责"挂上组件",**所有会变的量都由组件自己订阅**
  /// (见 `BottomBar.SystemTabItem` 的注释),这里不按值传选中态。
  @Builder
  slotDiscover() {
    SystemTabItem({
      index: 0,
      label: $r('app.string.nav_discover'),
      icon: Sym.discover,
      iconFill: Sym.discoverFill,
      settings: this.settings
    })
  }

  @Builder
  slotFeed() {
    SystemTabItem({
      index: 1,
      label: $r('app.string.nav_feed'),
      // 追更那枚在 symbol 表里**没有实心变体**(radiowaves 家族全量只有 `dot_radiowaves` /
      // `dot_radiowaves_message(_fill)` / `music_note_radiowaves_left_and_right` 等,
      // `dot_radiowaves_left_and_right_fill` 不存在),选中态改由"换色 + 加粗"表达(见 Sym.feed)
      icon: Sym.feed,
      iconFill: Sym.feed,
      hasFill: false,
      settings: this.settings
    })
  }

  @Builder
  slotLibrary() {
    SystemTabItem({
      index: 2,
      label: $r('app.string.nav_library'),
      icon: Sym.library,
      iconFill: Sym.libraryFill,
      settings: this.settings
    })
  }

  @Builder
  shell() {
    // Stack 叠层:内容(Tabs)在下、撑满全屏,播放条在上。
    // 之所以还要这一层 Stack:播放条要能**落进**系统 tab 栏那 56vp 里(收束态),
    // 而栏是 Tabs 自己画的,页面内容进不去 —— 只能盖在上面。
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Tabs({ barPosition: BarPosition.End, index: this.tab }) {
          TabContent() {
            DiscoverPage({
              scheme: this.scheme(),
              fontScale: this.fontScale(),
              settings: this.settings,
              history: this.history,
              subscriptions: this.subscriptions,
              radio: this.radio,
              // `CATALOG=false` 的降级渠道下,有订阅的人首屏主体就是「最新」+ 播放态高亮(见 subscribeStarter)
              inbox: this.inbox,
              player: this.player,
              bottomPad: this.underBarPad(),
              onScrollDy: (dy: number) => this.feedScroll(dy),
              onOpenPodcast: (p: Podcast) => this.openPodcast(p),
              onPlayEpisode: (e: Episode, q: Episode[], tag: string) => this.playEpisode(e, q, tag)
            })
          }
          .tabBar(this.slotDiscover())


          TabContent() {
            FeedPage({
              scheme: this.scheme(),
              fontScale: this.fontScale(),
              player: this.player,
              inbox: this.inbox,
              subscriptions: this.subscriptions,
              history: this.history,
              bottomPad: this.underBarPad(),
              onScrollDy: (dy: number) => this.feedScroll(dy),
              onPlayEpisode: (e: Episode, q: Episode[], tag: string) => this.playEpisode(e, q, tag)
            })
          }
          .tabBar(this.slotFeed())


          TabContent() {
            LibraryPage({
              scheme: this.scheme(),
              fontScale: this.fontScale(),
              player: this.player,
              settings: this.settings,
              subscriptions: this.subscriptions,
              favorites: this.favorites,
              downloads: this.downloads,
              history: this.history,
              downloadManager: this.downloadManager,
              bottomPad: this.underBarPad(),
              onScrollDy: (dy: number) => this.feedScroll(dy),
              onOpenPodcast: (p: Podcast) => this.openPodcast(p),
              notes: this.notes,
              onPlayEpisode: (e: Episode, q: Episode[], tag: string) => this.playEpisode(e, q, tag),
              onPlayNote: (n: EpisodeNote) => this.playNote(n),
              onOpenSettings: () => { this.stack.pushPathByName('settings', null); },
              onOpenListenStats: () => { this.stack.pushPathByName('listen_stats', null); }
            })
          }
          .tabBar(this.slotLibrary())

        }
        /**
         * 栏交给系统画(自绘的玻璃透镜栏已退役进 `harmony/shelved/`)。
         *
         * - `barHeight(56)`:系统默认也是 56,显式写出来免得以后有人以为它跟着内容自适应;
         * - `barOverlap(true)` + `barBackgroundBlurStyle`:栏**透**——糊的是它背后那行列表内容。
         *   这要求页面给底部让出余量([underBarPad]),否则滚到底末项被栏压住;
         * - `barBackgroundColor` 那层 0.86 的 surface 是**必需的**:磨砂本身跟随**系统**深浅色,
         *   而本应用的深浅可以在设置里独立选(见 Theme.scheme 的三个入参)。系统浅色 + 应用深色
         *   时,光有磨砂会是一块亮底,深色文字压上去就读不清 —— 压一层应用自己的 surface 才随主题走。
         *   0.86 是"盖得住磨砂、又还留得见内容在动"那一档,装机后按观感再调;
         * - `divider`:栏与内容之间那道发丝线(自绘版是手写的 0.5 Divider,系统这版有原生入口)。
         */
        .barHeight(TAB_BAR_H)
        .barMode(BarMode.Fixed)
        .scrollable(false)
        .barOverlap(true)
        .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .barBackgroundColor(withAlpha(this.scheme().surface, 0.86))
        .divider({ strokeWidth: 0.5, color: withAlpha(this.scheme().outline, 0.6) })
        .onChange((i: number) => { this.tab = i; })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      /**
       * 上下各避开系统栏。**bottom 这一项就是"靠下"那两条反馈的正解**:
       * 自绘版把整条栏压在手势避让区里(只留 0.62 倍,栏底几乎贴着小白条),
       * 现在栏整体抬到手势区上方 —— 栏底到屏底恰好是完整的避让区,
       * 与参考片实测的 91px = 28vp 对上。
       */
      .padding({ top: this.topInset, bottom: this.bottomInset })

      if (this.player.current !== null) {
        Column() {
          MiniPlayerBar({
            scheme: this.scheme(),
            fontScale: this.fontScale(),
            player: this.player,
            collapsed: this.collapsed,
            onExpand: () => { this.stack.pushPathByName('player', null); },
            onOpenQueue: () => { this.stack.pushPathByName('queue', null); },
            onHome: () => this.expandMini()
          })
        }
        .width('100%')
        /**
         * 落点随收束态在 `bottomInset` 与 `bottomInset + 56 + 8` 之间弹簧过去,
         * 曲线与播放条内部那几个几何量同源([morphSpring])—— 两处不同步就是"散架"。
         */
        .padding({ bottom: this.miniBottom() })
        .animation({ curve: morphSpring() })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.scheme().background)
  }
}
