import { Theme, Scheme, TypeScale, Metrics } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { AppContainer } from '../AppContainer';
import { ScreenHeader, EmptyHint } from '../view/Widgets';
import { DiscoverPage } from '../view/DiscoverPage';
import { PodcastDetailPage } from '../view/PodcastDetailPage';
import { PlayerPage } from '../view/PlayerPage';
import { MiniPlayerBar } from '../view/MiniPlayerBar';
import { LibraryPage } from '../view/LibraryPage';
import { SettingsPage } from '../view/SettingsPage';
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
  @State settings: SettingsStore = new SettingsStore();
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
    this.settings = app.settings;
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
          onBack: () => { this.stack.pop(); },
          onChanged: () => { this.tick = this.tick + 1; }
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
            onOpenPodcast: (p: Podcast) => this.openPodcast(p),
            onPlayEpisode: (e: Episode, q: Episode[]) => this.playEpisode(e, q)
          })
        }
        .tabBar(this.tabBarItem($r('app.string.nav_discover'), $r('sys.media.ohos_ic_public_search_filled'), 0))

        TabContent() {
          LibraryPage({
            scheme: this.scheme(),
            fontScale: this.fontScale(),
            player: this.player,
            onOpenPodcast: (p: Podcast) => this.openPodcast(p),
            onPlayEpisode: (e: Episode, q: Episode[]) => this.playEpisode(e, q),
            onOpenSettings: () => { this.stack.pushPathByName('settings', null); }
          })
        }
        .tabBar(this.tabBarItem($r('app.string.nav_library'), $r('sys.media.ohos_ic_public_albums'), 1))
      }
      .barMode(BarMode.Fixed)
      .barBackgroundColor(this.scheme().surface)
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
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topInset, bottom: this.bottomInset })
    .backgroundColor(this.scheme().background)
  }

  @Builder
  tabBarItem(label: Resource, icon: Resource, index: number) {
    Column({ space: 3 }) {
      Image(icon)
        .width(23).height(23)
        .fillColor(this.tab === index ? this.scheme().primary : this.scheme().onSurfaceVariant)
      Text(label)
        .fontSize(TypeScale.caption * this.fontScale())
        .fontColor(this.tab === index ? this.scheme().primary : this.scheme().onSurfaceVariant)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

}
