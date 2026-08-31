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
import { PlayerPage } from '../view/PlayerPage';
import { MiniPlayerBar } from '../view/MiniPlayerBar';
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
  @State listenStats: ListenStatsStore = AppContainer.get().listenStats;
  @State downloadManager: DownloadManager = AppContainer.get().downloadManager;
  @State radio: RadioStation = AppContainer.get().radio;
  @State tab: number = 0;
  @State systemDark: boolean = false;
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
    const cfgMode: number | undefined = ctx.config?.colorMode;
    this.systemDark = cfgMode === 0;   // ColorMode.COLOR_MODE_DARK = 0
    this.readInsets();
    this.applySystemBar();
    Log.i('UI', `外壳就绪 systemDark=${this.systemDark}`);
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

  private playEpisode(e: Episode, queue: Episode[]): void {
    Log.i('UI', `播放 "${e.title}" 队列=${queue.length}`);
    this.player.playOrToggle(e, queue);
  }

  build() {
    // 未同意隐私政策时**整棵界面树只有同意页** —— 发现页一进来就会拉榜单,
    // 只要它没被渲染,同意前就一个网络请求都不会发生(平台合规指引 7.5)。
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
            onPlayEpisode: (e: Episode, q: Episode[]) => this.playEpisode(e, q)
          })
            .layoutWeight(1)
          if (this.player.current !== null) {
            MiniPlayerBar({
              scheme: this.scheme(),
              fontScale: this.fontScale(),
              player: this.player,
              onExpand: () => { this.stack.pushPathByName('player', null); }
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

  @Builder
  shell() {
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
            onOpenPodcast: (p: Podcast) => this.openPodcast(p),
            onPlayEpisode: (e: Episode, q: Episode[]) => this.playEpisode(e, q)
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
            onOpenPodcast: (p: Podcast) => this.openPodcast(p),
            onPlayEpisode: (e: Episode, q: Episode[]) => this.playEpisode(e, q),
            onOpenSettings: () => { this.stack.pushPathByName('settings', null); },
            onOpenListenStats: () => { this.stack.pushPathByName('listen_stats', null); }
          })
        }

      }
      // 隐掉 Tabs 自带的 bar,底部栏自绘。
      // 为什么:迷你播放条必须在 tab 栏**上方**(与 Android 的 bottomBar 顺序一致:
      // 迷你条 → 分隔线 → NavigationBar)。而 Tabs 自带的 bar 属于 Tabs 组件自身、
      // 固定在它的底边,任何作为 Tabs **兄弟节点**排在其后的东西都只能落到 tab 栏下面 ——
      // 原先迷你条就是这么跑到 tab 下面去的。
      .barHeight(0)
      .barMode(BarMode.Fixed)
      .scrollable(false)
      .onChange((i: number) => { this.tab = i; })
      .layoutWeight(1)

      if (this.player.current !== null) {
        MiniPlayerBar({
          scheme: this.scheme(),
          fontScale: this.fontScale(),
          player: this.player,
          onExpand: () => { this.stack.pushPathByName('player', null); }
        })
        // 仅在迷你条出现时画分隔线(与 Android 一致)
        Divider()
          .strokeWidth(0.5)
          .color(withAlpha(this.scheme().outline, 0.6))
      }

      this.bottomBar()
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset, bottom: this.bottomInset })
    .backgroundColor(this.scheme().background)
  }

  /// 自绘底部 tab 栏(替代 Tabs 自带 bar,理由见 shell() 注释)。
  @Builder
  bottomBar() {
    Row() {
      // 图标用**与 Android 完全相同的两枚 Material Rounded 矢量**(见 tabBarItem 注释)
      this.tabBarItem($r('app.string.nav_discover'), $r('app.media.ic_tab_discover'), 0)
      this.tabBarItem($r('app.string.nav_library'), $r('app.media.ic_tab_library'), 1)
    }
    .width('100%')
    /**
     * 64 —— 落在鸿蒙规范值(56)与 Material NavigationBar(80)之间,两头都试过:
     *  - **80 太笨重**:那是 Material 给 Android 的规范;而本机逻辑宽度约 376vp、
     *    Android 那台 427dp,**同一个绝对值在鸿蒙上占屏比例大 14%**,照抄像素必然显大。
     *  - **56 又挤不开**:药丸只能给到 48×26,图标四周、药丸与文字、药丸与栏上沿
     *    三处留白都不够,而这三处留白正是 Android 那枚药丸好看的原因。
     *
     * 64 的内部分配:约 7 上边距 + 30 药丸 + 4 间隙 + 15 文字 + 约 8 下边距。
     *
     * 判据分两类,别混:**字号**按绝对物理尺寸对齐(16sp 的字两端就该一样大,是可读性常量);
     * **外壳尺寸**(栏高/图标/内边距)不照抄像素,按平台规范 + 实机观感取值。
     */
    .height(64)
    .backgroundColor(this.scheme().surface)
  }

  /// 底部 tab 项。图标与 Android 对齐:发现 = Explore(罗盘/发现),音阁 = LibraryMusic(音乐列表)。
  /// 原先误用了放大镜与相册 —— `sys.media.*` 里没有这两个形状,只能拿近似的凑;
  /// 换成 Symbol 字体后有正主(见 Sym)。
  @Builder
  tabBarItem(label: Resource, icon: Resource, index: number) {
    Column({ space: 4 }) {
      /**
       * 选中项衬一枚药丸底。**64×30,图标 20** —— 三处留白是这枚药丸好看的关键,
       * 也正是先前 48×26 缺的:
       *   图标到药丸左右   (64-20)/2 = 22
       *   图标到药丸上下   (30-20)/2 = 5
       *   药丸到下方文字   4
       *   药丸到栏上沿     约 7(由 64 栏高居中得出)
       * 宽度取满 64:窄药丸裹着图标像个按钮,宽一些才像"这一栏被选中了"。
       *
       * **图标是从 Android 搬过来的同两枚 Material Rounded 矢量**
       * (`Icons.Rounded.Explore` / `Icons.Rounded.LibraryMusic`,Apache-2.0),
       * 以 SVG 放在 `resources/base/media/ic_tab_*.svg`,用 `Image + fillColor` 染色。
       *
       * 为什么不继续用 Symbol 字体:两端底部 tab 是**并排截图最先被看到的地方**,
       * 而 Symbol 里没有形状对得上的对等件 —— `discover` 是个细描边大圆环、
       * `music_note_list` 是三横线加符号,与 Material 的罗盘/唱片盒差得远,
       * 发布截图放在一起就是两个应用。图标形状属于品牌一致性,不属于"平台惯例"那一类,
       * 所以这里取一致而不取各自平台形态。
       *
       * 也因此**不再做"选中实心 / 未选中描边"的切换** —— Android 侧两个状态用的是同一枚图标,
       * 靠药丸底与颜色表示选中,鸿蒙照此对齐。
       *
       * 尺寸 22 而非 Android 的 24:22 是先前用 Symbol 时调好的观感值,换成同一批矢量后
       * 22 与 Android 的 24 视觉相当(本机逻辑宽度更窄,见 bottomBar 注释)。
       *
       * 药丸本身值得有:原先只靠图标与文字变色表示选中,"当前在哪一栏"太弱。
       */
      Stack() {
        if (this.tab === index) {
          Row()
            .width(64).height(30)
            .borderRadius(15)
            .backgroundColor(withAlpha(this.scheme().primary, 0.18))
        }
        // 用 Image 而非 SymbolGlyph:这两枚是从 Material 取来的 SVG(见下方注释)。
        // SVG 走 fillColor 染色,与 Symbol 的 fontColor 等效。
        Image(icon)
          .width(22).height(22)
          .fillColor(this.tab === index ? this.scheme().primary : this.scheme().onSurfaceVariant)
      }
      .width(64).height(30)
      Text(label)
        .fontSize(TypeScale.caption * this.fontScale())
        .letterSpacing(Tracking.caption)
        .fontColor(this.tab === index ? this.scheme().primary : this.scheme().onSurfaceVariant)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.tab = index; })
  }

}
