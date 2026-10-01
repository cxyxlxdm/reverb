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
import { PodcastDetailPage } from '../view/PodcastDetailPage';
import { NoteStore, EpisodeNote } from '../store/NoteStore';
import { PlayerPage } from '../view/PlayerPage';
import { MiniPlayerBar } from '../view/MiniPlayerBar';
import { GlassTabBar, barFootprint } from '../view/GlassTabBar';
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

/// 顶层外壳:Navigation 承载全屏页(频道详情等),内页是「发现 / 音阁」两 tab。
/// 与 Android 一致的取舍:全屏页整体转场,底部栏不产生占位跳动。
@Entry
@Component
struct Index {
  /**
   * 各 store 一律由外壳以 `@State` 持有、再以 `@ObjectLink` 下发给页面。
   *
   * 为什么不让页面自己 `AppContainer.get().xxx` 取(那样代码更短):那样拿到的是
   * **未被 ArkUI 观察**的裸对象,改了字段页面不会重渲。音阁的宫格切换/清空历史/删除下载、
   * 「最新」刷新结果上屏,以及设置页的配色,都曾因此点了没反应 —— 有些看着正常,
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
  @State tab: number = 0;
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

  /// 页面滚动内容需为玻璃悬浮层让出的底部空间:
  /// 栏的落点(`barFootprint` = 栏高 + 手势区的那一道留白)+ 迷你条(2 细线 + 42 封面 +
  /// 上下 8 = 60)+ 分隔线 0.5。
  /// 迷你条的出现/消失经 onStateChanged → tick 触发重渲,这里随之重算并经 @Prop 传下去。
  /// 式子必须与 GlassTabBar 里那个 Column 的高度同源(所以导入 `barFootprint` 而不是
  /// 自己拼 `bottomInset + BAR_H`)—— 收小留白时最容易漏这一处,漏了列表末尾多出一条空白。
  private underBarPad(): number {
    const mini = this.player.current !== null ? 60.5 : 0;
    return barFootprint(this.bottomInset) + mini;
  }

  @Builder
  shell() {
    // Stack 叠层:内容在下、撑满全屏(**延伸到玻璃栏与手势条底下**),迷你条 +
    // 玻璃 tab 栏悬浮在上。旧结构是「Tabs → 迷你条 → 栏」纵向排开互不重叠;
    // 改玻璃栏后必须让内容从栏下滚过,模糊才有东西可糊。
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
              onOpenPodcast: (p: Podcast) => this.openPodcast(p),
              onPlayEpisode: (e: Episode, q: Episode[], tag: string) => this.playEpisode(e, q, tag)
            })
          }


          TabContent() {
            LibraryPage({
              scheme: this.scheme(),
              fontScale: this.fontScale(),
              player: this.player,
              settings: this.settings,
              subscriptions: this.subscriptions,
              inbox: this.inbox,
              favorites: this.favorites,
              downloads: this.downloads,
              history: this.history,
              downloadManager: this.downloadManager,
              bottomPad: this.underBarPad(),
              onOpenPodcast: (p: Podcast) => this.openPodcast(p),
              notes: this.notes,
              onPlayEpisode: (e: Episode, q: Episode[], tag: string) => this.playEpisode(e, q, tag),
              onPlayNote: (n: EpisodeNote) => this.playNote(n),
              onOpenSettings: () => { this.stack.pushPathByName('settings', null); },
              onOpenListenStats: () => { this.stack.pushPathByName('listen_stats', null); }
            })
          }

        }
        // 依旧隐掉 Tabs 自带 bar(barHeight(0)),底部栏用 GlassTabBar。
        // 迷你条在栏**上方**的顺序与 Android 一致 —— 两者同处悬浮层,顺序天然成立。
        .barHeight(0)
        .barMode(BarMode.Fixed)
        .scrollable(false)
        .onChange((i: number) => { this.tab = i; })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })
      /**
       * 玻璃栏的**折射取源**:栏要折射的是"自己背后那块内容",而内容恰好就是这一层。
       * 挂在 Column(而不是 Navigation)上 —— 悬浮的迷你条与栏都是它的兄弟节点,
       * 截这一层天然不含栏自己,镜内不会套一份"栏的副本"。
       */
      .id('glassBackdrop')

      Column() {
        if (this.player.current !== null) {
          MiniPlayerBar({
            scheme: this.scheme(),
            fontScale: this.fontScale(),
            player: this.player,
            onExpand: () => { this.stack.pushPathByName('player', null); },
            onOpenQueue: () => { this.stack.pushPathByName('queue', null); }
          })
          // 仅在迷你条出现时画分隔线(与 Android 一致)
          Divider()
            .strokeWidth(0.5)
            .color(withAlpha(this.scheme().outline, 0.6))
        }
        GlassTabBar({
          scheme: this.scheme(),
          fontScale: this.fontScale(),
          tab: this.tab,
          inset: this.bottomInset,
          items: [
            { label: $r('app.string.nav_discover'), icon: $r('app.media.ic_tab_discover') },
            { label: $r('app.string.nav_library'), icon: $r('app.media.ic_tab_library') }
          ],
          onSelect: (i: number) => { this.tab = i; }
        })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.scheme().background)
  }
}
