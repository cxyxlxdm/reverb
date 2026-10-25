import { Theme, Scheme, TypeScale, Tracking, Metrics } from '../theme/Theme';
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
  SystemTabItem, barFloating, pickMaterialType, TAB_BAR_H, TAB_KEY, MORPH_KEY, MORPH_SLOPE,
  MINI_H, MINI_GAP, MINI_SIDE_MARGIN, morphSpring, barReserve, channelMiniBottom
} from '../view/BottomBar';
import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit';
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
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
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
   * 当前 tab。**放 AppStorage 而不是 @State**:栏项的选中色由 `SystemTabItem` 自己订阅这个键
   * (见 `BottomBar.TAB_KEY`),不依赖"父级 build 有没有重跑"。
   * 提交只有两个来源:栏的点按(`.onChange` 回写)与系统回退等处的程序化改值,都写这一个键。
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
   * **手指按住屏幕那一段**的滚动方向(0 未定 / +1 往后翻 / −1 往前翻)。只在 [feedScroll] 里读写。
   *
   * 存在的理由:列表撞到边界之后的**回弹**也走 `onDidScroll`,而且符号与刚才那一下相反
   * —— 一路往下滑到底会被回弹掀回展开态(装机逐帧取证见 [feedScroll] 那段 ⚠️)。
   * 回弹是 `ScrollState.Fling`,而"手指真的在往回划"必先经过 `ScrollState.Scroll`,
   * 所以方向记忆只在 Scroll 帧更新,Fling 帧只许延续、不许反悔。
   */
  private morphDir: number = 0;
  /**
   * 悬浮栏的材质档位。**冷启动探测一次**,不进 build 重算(见 `BottomBar.pickMaterialType`)。
   * 探测是必需的:直接写 IMMERSIVE 在不支持的机器上会得到**透明栏**(官方示例明确点过这一条)。
   */
  private readonly materialType: hdsMaterial.MaterialType = pickMaterialType();
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
  /**
   * 当前窗口宽(vp)。悬浮栏的 `barWidth` 要用它 —— 见 `BottomBar.barFloating` 里那条
   * 「不要给 '100%'」:百分比顶掉侧边距,宽度必须是"窗口宽 − 2×23vp"这个绝对量。
   * 和避让区同一次异步读取带回来,所以首帧是 0(那一帧不给 barWidth)。
   */
  @State windowWVp: number = 0;
  @State player: PlayerController = PlayerController.get();
  /// 播放状态变化触发重渲的计数(PlayerController 非 @Observed 字段级追踪,用它兜底刷新)
  @State tick: number = 0;
  /**
   * 本实例挂到 `player.onStateChanged` 上的**那一层**,以及进来时链上已有的**上一层**。
   *
   * 为什么要存成实例字段(见 REVIEW-2026-10-25 低·族D D1):`player` 是进程级单例,链子跨
   * 组件树存活;而语言切换会让 EntryAbility **整体重建**这棵 `@Entry` 树。原先每次
   * `aboutToAppear` 都无条件再链一层、又从不退 —— 换几次语言链上就叠几层,每层闭包抓住的是
   * **已销毁的旧实例**,播放状态每次变化它们都照常执行并往死树上写 `@State tick` 与
   * `@StorageLink(MORPH_KEY)`(泄漏 + 无谓的 AppStorage 写)。存下来才能在
   * `aboutToDisappear` 里精确退掉自己那一层。
   *
   * ⚠️ 硬规矩 7:加这两个字段只为"能摘下来"。**不要**顺手把 tick / 播放态挪到
   * PlayerController 这类被整体观察的对象上 —— 那是秒级高频变化,会让整棵树重渲。
   */
  private myStateHandler: (() => void) | null = null;
  private chainedStateHandler: (() => void) | null = null;
  /// 长按菜单开着(以及刚关掉那一瞬)—— 整屏盖一层「误触盾」,见 TapGuard。
  @StorageLink('tapShield') tapShield: boolean = false;

  aboutToAppear(): void {
    // getContext() 已废弃,API 12+ 用 UIContext 取宿主 context
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const app = AppContainer.get();
    app.boot(ctx);
    this.player = app.player;
    // 播放状态变化时驱动界面刷新。挂法见 [myStateHandler]:这一层必须能在 aboutToDisappear 里退掉。
    const prev = app.player.onStateChanged;
    this.chainedStateHandler = prev;
    const handler: () => void = (): void => {
      if (prev !== null) prev();
      this.tick = this.tick + 1;
      // 已经没有播放条了,收束标志必须跟着清:否则下次起播时栏项一上来就是淡没状态,
      // 界面上看就是"底部栏空了半条"
      if (this.collapsed && this.player.current === null) this.collapsed = false;
    };
    this.myStateHandler = handler;
    app.player.onStateChanged = handler;
    this.readInsets();
    this.applySystemBar();
    this.applyColorMode();
    Log.i('UI', `外壳就绪 systemDark=${this.systemDark}`);
  }

  /**
   * 树被销毁(换语言 / 换深浅色这类 EntryAbility 重载)时退掉**自己这一层**监听。
   *
   * 判据是**身份比较**:只有链头仍是本实例挂上去的那个函数时才摘,并把上一层原样接回去。
   * 若时序上已有新实例往链上叠过(旧树销毁晚于新树构建),这里什么都不动 ——
   * 多留一层是可回收的账,把别人的链拦腰截断则是把界面刷新弄坏,两害取轻。
   *
   * 为什么不在这里置 `null`:`startGated` 里 `AvSessionBridge` 那一层是全局的
   * (锁屏 / 控制中心的播控同步靠它),清空会连带把它关掉。
   */
  aboutToDisappear(): void {
    const p = this.player;
    if (this.myStateHandler !== null && p.onStateChanged === this.myStateHandler) {
      p.onStateChanged = this.chainedStateHandler;
      Log.i('UI', '外壳销毁,退掉刷界面那一层播放状态监听');
    }
    this.myStateHandler = null;
  }

  /**
   * 系统深浅色翻转(经 AppStorage 传过来)之后要补的一件事。
   * 主题本身是 `scheme()` 现算的,整树重建会跟着翻;唯一不在组件树里的是状态栏与
   * 导航条的**图标颜色**,它不会自己翻,必须重设(否则深色图标压在水墨底上糊成一团)。
   */
  private onSystemDarkChanged(): void {
    this.applySystemBar();
  }

  /// 读状态栏/手势导航条避让高度与**窗口宽**(px→vp)。窗口设了全屏布局,故需自行避让;
  /// 窗口宽是给悬浮栏算 `barWidth` 用的(见 [windowWVp])。
  private readInsets(): void {
    try {
      const win = window.getLastWindow(this.getUIContext().getHostContext());
      win.then((w: window.Window) => {
        const ui = this.getUIContext();
        const top = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const nav = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.topInset = ui.px2vp(top.topRect.height);
        this.bottomInset = ui.px2vp(nav.bottomRect.height);
        // 全屏布局下窗口宽 == 屏宽。用窗口而不是 display:旋转 / 分屏时跟着窗口走。
        this.windowWVp = ui.px2vp(w.getWindowProperties().windowRect.width);
        Log.i('UI', `避让 top=${this.topInset} bottom=${this.bottomInset} winW=${this.windowWVp}`);
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

  /**
   * 把应用内主题档位**告诉系统**,和上面那句 `setWindowSystemBarProperties` 是同一类事:
   * 主题不是只有组件树那一半。
   *
   * 底部栏用的是系统材质 `BlurStyle.COMPONENT_THICK`,它取的是「**应用生效深浅态**」——
   * 而我们从不声明,于是它等于**设备**的深浅态。默认主题是水墨(2),设备在浅色模式时
   * 装机实测到的是**一块白磨砂压在水墨界面上**;同一块磨砂在收束态还是播放条的背景。
   * 系统弹窗、半屏面板、键盘同理。
   *
   * 档位 3「纯白」是浅色的一种,所以只有 2 映射 DARK、0 映射 NOT_SET,其余走 LIGHT。
   */
  private applyColorMode(): void {
    const mode: number = this.settings.themeMode;
    const cm: ConfigurationConstant.ColorMode = mode === 2
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : (mode === 0 ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.getApplicationContext().setColorMode(cm);
    } catch (e) {
      Log.w('UI', `设置应用深浅态失败 ${(e as Error).message}`);
    }
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
            // 系统材质那一半也要翻(底部栏那块磨砂不读我们的 Scheme)
            this.applyColorMode();
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
          onBack: () => { this.stack.pop(); },
          onOpenChannel: (feedUrl: string) => this.openPodcastByFeed(feedUrl)
        })
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset, bottom: this.bottomInset })
      .backgroundColor(this.scheme().background)
    }
    else if (name === 'podcast') {
      NavDestination() {
        /**
         * 频道页的播放条是**悬浮层**,不是 Column 的末行(2026-10-15 改)。
         *
         * 旧写法它自己占一行、底边正好贴在避让区上沿 —— 于是胶囊下半截的两个圆角
         * 吃在屏幕边里,读出来就是"底部一块不透明的长方形板",和三个 tab 页上那颗
         * 悬浮椭圆不是同一个东西。现在两页同一口径:左右同那道 23vp 缝(在组件内部的
         * [MINI_SIDE_MARGIN])、列表侧用 `contentEndOffset` 让出「落点 + 条高」,
         * 否则末项永远滚不出条子底下。
         * 这一页没有 tab 栏,所以**永不收束**(`collapsed` 用组件默认值 false)。
         *
         * ⚠️ **但只改成悬浮还不够**(2026-10-16 用户第二次指出「底部依然有一小段不透明」,
         * 并确认说的不是胶囊):那块板是这一支的 `padding({ bottom: bottomInset })` 留下的 ——
         * 避让区那一条被 `backgroundColor` 铺成纯色,列表滚到边就截断,胶囊坐在板上方,
         * 整页底部读起来就是"内容里嵌了一块不透明的东西"。三个 tab 页没有这一条:
         * 外壳只垫 `top`(见下面 `.padding({ top: this.topInset })`),底部由 `HdsTabs`
         * 自己按 `barBottomMargin = bottomInset` 落。所以这里改成同一口径,**inset 进两处**:
         * 胶囊落点、列表让位 = 落点 + 条高。
         * 只进一处都不成立 —— 只进落点则末行藏进小白条,只进让位量则那条板照旧。
         *
         * ⚠️ **落点不走 tab 页那式子(`inset + 缝`)**,走 [channelMiniBottom] —— 它把基准
         * 钳到 Android 那道 16vp。2026-10-17 用户第三次提这一处:量出来 Android 24dp /
         * 鸿蒙 36vp(占屏 3.06% vs 4.35%),差的全在鸿蒙那道更高的指示器区上。
         */
        Stack({ alignContent: Alignment.Bottom }) {
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
            bottomPad: this.player.current === null
              ? this.bottomInset : this.detailLanding() + MINI_H,
            onBack: () => { this.stack.pop(); },
            onPlayEpisode: (e: Episode, q: Episode[], tag: string) => this.playEpisode(e, q, tag)
          })
          if (this.player.current !== null) {
            MiniPlayerBar({
              scheme: this.scheme(),
              fontScale: this.fontScale(),
              player: this.player,
              onExpand: () => { this.stack.pushPathByName('player', null); },
              onOpenQueue: () => { this.stack.pushPathByName('queue', null); },
              onClose: () => this.closeMini()
            })
              .margin({ bottom: this.detailLanding() })
              /**
               * 塌陷退场:纵向压扁到 0 + 淡出(参考视频里播放条被压成细缝后消失,
               * 不是横滑也不是纯淡出)。出现时同一形状反向弹出。
               * 与 [closeMini] 的 animateTo 配套 —— transition 只管条子自己的形,
               * 列表让位量那条在 animateTo 的隐式动画里。
               */
              .transition(TransitionEffect.scale({ x: 1, y: 0 })
                .combine(TransitionEffect.OPACITY)
                .animation({ curve: morphSpring() }))
          }
        }
        .width('100%').height('100%')
      }
      .hideTitleBar(true)
      .padding({ top: this.topInset })
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
   * ⚠️ 这个回调**每帧都跑**,所以里面只许有加减法和几次布尔比较(硬规矩 6)。
   * 真正被改的状态只有 `collapsed`,而它只让栏项的 opacity、播放条的四个几何量,以及**每翻转一次**
   * 重建一份 `barFloatingStyle`(第五轮起里面多了 `barOpacity`)重算 —— 都是按次而非按帧,
   * 不动列表数据、也不让页面重新 measure(让位量按展开态恒定,见 [underBarPad])。
   *
   * ⚠️ **展开那一支必须按"这一阵动的拖拽方向"过滤,不能只看 dy 的符号**(2026-10-16 装机逐帧取证)。
   * 现象:首页一路往下滑到底,播放条刚收进去就自己弹回展开态,而且**每次划到底都必然发生**。
   * 在发现页那一处真正在滚的容器上挂探针打 `(dy, st)` 之后,结论是
   * **列表撞到边界之后的回弹同样走 `onDidScroll`,而且是 `st=Fling`、符号与刚才那一下相反**:
   * 一次惯性划到底 = 拖拽段 `st=Scroll` 每帧 +1~+5vp(累计过 40 → 收束、清零),
   * 松手后回弹段 `st=Fling` 每帧 −3~−10.6vp、**一整串合计 −45 ~ −48vp** ——
   * 阈值只有 40,所以回弹必然把 `collapsed` 掀回 false。当场 30 次翻转里 15 次是这种"收束后 0.5~1.3 秒被回弹掀翻"。
   * 修法是把方向**锚在手指真的按住屏幕的那一段**:只有 `Scroll` 帧更新 [morphDir],
   * `Fling`/`Idle` 帧只许延续它 —— 回弹与拖拽段反号 ⇒ 不计入 ⇒ **滑到底保持收束**;
   * 而"轻轻一划靠惯性往回滚"这种真意图照旧算(它的拖拽段本身就是负号)。
   * 顺带把硬规矩 9 补上:程序化滚动(`scrollTo` / 换 tab 复位)没有拖拽段,`morphDir` 仍是 0
   * ⇒ 两支都不认,原先那种"进页自动滚一段就把栏掀一下"的路径一并堵掉。
   *
   * 另一端**不需要同构**:Android 那侧读的是 `NestedScrollConnection` 的 `consumed`,
   * 边界回弹不进 `consumed`(它走 overscroll 通道),所以那边装机 10 轮划到底没有这一现象。
   * 按硬规矩 2,这属于"两端滚动回调给的东西本来就不同形",不是可以互相类推的参数。
   */
  private feedScroll(dy: number, st: ScrollState): void {
    if (this.player.current === null) return;
    const dir: number = dy > 0 ? 1 : (dy < 0 ? -1 : 0);
    if (dir === 0) return;
    if (st === ScrollState.Scroll) {
      this.morphDir = dir;
    } else if (this.morphDir !== dir) {
      // 惯性段与方向相反的帧 = 边界回弹,不是用户改主意的证据
      return;
    }
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

  /// 收束态左端那颗小圆球:只把播放条放回两行共存,不改当前 tab(盘上是当前那一格,点它不切页)。
  private expandMini(): void {
    this.morphAcc = 0;
    this.morphDir = 0;
    this.collapsed = false;
  }

  /**
   * 点 X 关掉播放条(停播清场,见 `PlayerController.close`)。
   *
   * `animateTo` 里包的是 `close()` 整个动作:current 置 null 会让**两样东西同时变** ——
   * 条子本体(if 摘除,走各自的 transition)与列表让位量([underBarPad] / 频道页的
   * bottomPad,属性动画)。必须在同一次 animateTo 里,拆开就是"列表先跳上去、
   * 条子随后才没"的两段感;曲线取 [morphSpring],与收束/展开同一手感。
   */
  private closeMini(): void {
    this.getUIContext().animateTo({ curve: morphSpring() }, () => {
      this.player.close();
    });
  }

  /**
   * 播放条这一整块距屏底的落点。
   *
   * - 展开:抬到栏**上方**再留 8vp 缝(参考片实测那两道 26px);
   * - 收束:落进栏那 56vp 里,于是只剩手势区那一道。
   *
   * 栏由 `HdsTabs` 画,它自己按 `barBottomMargin = bottomInset` 浮在避让区上方
   * (见 `BottomBar.barFloating`),所以两种落点都以"屏底往上 bottomInset"为基准,不用自己算栏高。
   */
  private miniBottom(): number {
    return this.collapsed ? this.bottomInset : this.bottomInset + TAB_BAR_H + MINI_GAP;
  }

  /**
   * 频道页(没有 tab 栏那一支)悬浮胶囊的落点。见 [channelMiniBottom] 的账 ——
   * 那一页的落点与列表让位必须同源于此,否则改了落点忘了让位,末行会藏进胶囊底下。
   */
  private detailLanding(): number {
    return channelMiniBottom(this.bottomInset);
  }

  /**
   * 页面滚动内容需为底部悬浮层让出的空间 = 栏高 + 手势区 + 播放条(展开态那一档)。
   *
   * 式子收在 `BottomBar.barReserve` 里,和栏自己的几何同源 —— 收小留白时最容易漏这一处,
   * 漏了列表末尾多出一条空白(或者末项被栏压住)。
   *
   * ⚠️ **不含 collapsed**:收束时播放条整块落进栏里,本可以少让 56vp,但那样每次翻转都要
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
    // Stack 叠层(自上而下两层):内容(HdsTabs,栏由它画)在底、播放条在顶。
    // 之所以还要这层 Stack:播放条要能**落进**栏那 56vp 里(收束态),而栏是悬浮胶囊、
    // 压在页面内容之上,页面内容进不去 —— 只能盖在上面。
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        HdsTabs({ barPosition: BarPosition.End, index: this.tab }) {
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
              onScrollDy: (dy: number, st: ScrollState) => this.feedScroll(dy, st),
              onOpenPodcast: (p: Podcast) => this.openPodcast(p),
              // 封面/头像单独可点 → 频道页。与上面那颗不同:那颗拿整个 Podcast(发现页
              // 手上就有),这颗只拿 feedUrl(列表行只有这一集),由 openPodcastByFeed 查/合成种子。
              onOpenChannel: (feedUrl: string) => this.openPodcastByFeed(feedUrl),
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
              onScrollDy: (dy: number, st: ScrollState) => this.feedScroll(dy, st),
              onOpenChannel: (feedUrl: string) => this.openPodcastByFeed(feedUrl),
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
              onScrollDy: (dy: number, st: ScrollState) => this.feedScroll(dy, st),
              onOpenPodcast: (p: Podcast) => this.openPodcast(p),
              onOpenChannel: (feedUrl: string) => this.openPodcastByFeed(feedUrl),
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
         * 栏交给 **`HdsTabs` 的悬浮样式**画(2026-10-14,路线 A;自绘胶囊退役进
         * `harmony/shelved/PillTabBar.ets`,恢复步骤在那份文件头部)。
         *
         * **悬浮样式要求三条同时成立**(官方示例的硬条件,少一条就画成普通通栏):
         * `barOverlap(true)` + `vertical(false)` + `barPosition(BarPosition.End)`。
         *
         * - `barHeight(56)`:系统默认也是 56,显式写出来免得以后有人以为它跟着内容自适应;
         * - `barOverlap(true)`:栏**透**——糊的是它背后那行列表内容。这要求页面给底部让出
         *   余量([underBarPad]),否则滚到底末项被栏压住;
         * - `barFloatingStyle`:侧边距 23vp、宽度 = 窗口宽 − 2×23vp、距屏底 = 整个手势避让区,
         *   材质档位见 `BottomBar.barFloating`;**其中 `barOpacity` 按 `collapsed` 取**
         *   (2026-10-15 第五轮):收束态整条系统栏淡到 0,因为那一行由播放条自己当容器,
         *   两层胶囊叠着就不是参考片那个形态。代价是**这一行三个 tab 在收束态点不动** —— 那条
         *   现在是设计的必然(先点球展开再切格),不是待修的 bug,口径见 `BottomBar` 头部那一节;
         * - **不再写 `barBackgroundColor` / `barBackgroundBlurStyle` / `divider`**。这三条是
         *   "近似磨砂"那一版的零件,而这一版要验的正是**系统材质自己长什么样** —— 同时压上去
         *   就等于又自绘一层,装机看到的不是系统的东西(深浅态那一侧的坑见 H174);
         * - `scrollable(false)`:左右滑切页仍关着,与自绘版一致(列表里有横滑组件,会抢手势);
         * - **`padding` 只留 top**(见下一层):栏底到屏底那一段由 `barBottomMargin` 给,
         *   所以 Tabs 必须铺到屏底,列表才滚得到栏**背后**。系统栏那版在这里压了
         *   `bottom: bottomInset`,那是"栏贴着手势区上沿"的形状,已经不适用。
         */
        .barHeight(TAB_BAR_H)
        .barMode(BarMode.Fixed)
        .vertical(false)
        .scrollable(false)
        .barOverlap(true)
        .barFloatingStyle(barFloating(this.bottomInset, this.windowWVp, this.materialType, this.collapsed))
        .onChange((i: number) => { this.tab = i; })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })

      /**
       * 播放条。**挂在 Tabs 之后**:两者同处底部对齐的 Stack,后写的在上,
       * 收束态播放条才盖得住悬浮栏那 56vp。
       */
      if (this.player.current !== null) {
        Column() {
          MiniPlayerBar({
            scheme: this.scheme(),
            fontScale: this.fontScale(),
            player: this.player,
            collapsed: this.collapsed,
            // 三个 tab 外壳这一颗**开**封面跳转;频道详情页那处(上面 `podcast` 分支)保持关,
            // 在那里点自己这档的头像等于往栈上再压一份同一个页面。
            coverOpensChannel: true,
            onExpand: () => { this.stack.pushPathByName('player', null); },
            onOpenQueue: () => { this.stack.pushPathByName('queue', null); },
            onOpenChannel: (feedUrl: string) => this.openPodcastByFeed(feedUrl),
            onBallTap: () => this.expandMini(),
            onClose: () => this.closeMini()
          })
        }
        .width('100%')
        /**
         * 落点随收束态在 `bottomInset` 与 `bottomInset + 56 + 8` 之间弹簧过去,
         * 曲线与播放条内部那几个几何量同源([morphSpring])—— 两处不同步就是"散架"。
         */
        .padding({ bottom: this.miniBottom() })
        /**
         * **自身不吃触摸**。这一层是"落点容器",它的 `padding({ bottom })` 一直铺到屏底,
         * 默认命中模式下会把整块透明区域(含 tab 栏那 56vp)的点击全吞掉 —— 于是
         * **"只要播放条在显示,三个 tab 就全部点不动"**(装机实测:点音阁无反应,
         * 而同一坐标在收起态会命中播放条自己的按钮)。
         * `HitTestMode.None` 只放过容器自身,子节点(播放条那一行)照常响应。
         */
        .hitTestBehavior(HitTestMode.None)
        .animation({ curve: morphSpring() })
        /** 塌陷退场与频道页那处同一条(见 podcast 分支的注释)。 */
        .transition(TransitionEffect.scale({ x: 1, y: 0 })
          .combine(TransitionEffect.OPACITY)
          .animation({ curve: morphSpring() }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.scheme().background)
  }
}
