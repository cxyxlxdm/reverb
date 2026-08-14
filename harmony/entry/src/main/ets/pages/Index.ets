import { Theme, Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
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

  private playEpisode(e: Episode, queue: Episode[]): void {
    Log.i('UI', `播放 "${e.title}" 队列=${queue.length}`);
    this.player.playOrToggle(e, queue);
  }

  build() {
    Navigation(this.stack) {
      this.shell()
    }
    .navDestination(this.destination)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor(this.scheme().background)
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
          onOpenQueue: () => { this.stack.pushPathByName('queue', null); }
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
            radio: this.radio,
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
      this.tabBarItem($r('app.string.nav_discover'), Sym.discover, 0)
      this.tabBarItem($r('app.string.nav_library'), Sym.library, 1)
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.scheme().surface)
  }

  /// 底部 tab 项。图标与 Android 对齐:发现 = Explore(罗盘/发现),音阁 = LibraryMusic(音乐列表)。
  /// 原先误用了放大镜与相册 —— `sys.media.*` 里没有这两个形状,只能拿近似的凑;
  /// 换成 Symbol 字体后有正主(见 Sym)。
  @Builder
  tabBarItem(label: Resource, icon: Resource, index: number) {
    Column({ space: 3 }) {
      Glyph({
        symbol: icon, dim: 23,
        color: this.tab === index ? this.scheme().primary : this.scheme().onSurfaceVariant
      })
      Text(label)
        .fontSize(TypeScale.caption * this.fontScale())
        .fontColor(this.tab === index ? this.scheme().primary : this.scheme().onSurfaceVariant)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.tab = index; })
  }

}
