import { Theme, Scheme, TypeScale, Metrics } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { AppContainer } from '../AppContainer';
import { ScreenHeader, EmptyHint } from '../view/Widgets';
import { DiscoverPage } from '../view/DiscoverPage';
import { PodcastDetailPage } from '../view/PodcastDetailPage';
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

  aboutToAppear(): void {
    // getContext() 已废弃,API 12+ 用 UIContext 取宿主 context
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const app = AppContainer.get();
    app.boot(ctx);
    this.settings = app.settings;
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

  /// M4 接入真实播放;当前先记日志,保证链路可点。
  private playEpisode(e: Episode, queue: Episode[]): void {
    Log.i('UI', `请求播放 "${e.title}" 队列=${queue.length}(播放层将于 M4 接入)`);
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
    if (name === 'podcast') {
      NavDestination() {
        PodcastDetailPage({
          scheme: this.scheme(),
          fontScale: this.fontScale(),
          seed: this.detailSeed,
          onBack: () => { this.stack.pop(); },
          onPlayEpisode: (e: Episode, q: Episode[]) => this.playEpisode(e, q)
        })
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
          this.libraryPlaceholder()
        }
        .tabBar(this.tabBarItem($r('app.string.nav_library'), $r('sys.media.ohos_ic_public_albums'), 1))
      }
      .barMode(BarMode.Fixed)
      .barBackgroundColor(this.scheme().surface)
      .scrollable(false)
      .onChange((i: number) => { this.tab = i; })
      .layoutWeight(1)
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

  /// M5 将替换为真实音阁
  @Builder
  libraryPlaceholder() {
    Column() {
      ScreenHeader({
        scheme: this.scheme(),
        fontScale: this.fontScale(),
        title: '音阁'
      })
      EmptyHint({ scheme: this.scheme(), fontScale: this.fontScale(), text: '音阁将于 M5 接入' })
        .layoutWeight(1)
    }
    .width('100%').height('100%')
    .padding({ top: Metrics.topPadding })
  }
}
