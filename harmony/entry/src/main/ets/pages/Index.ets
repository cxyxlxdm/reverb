import { Theme, Scheme, TypeScale, Metrics } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { AppContainer } from '../AppContainer';
import { ScreenHeader, EmptyHint } from '../view/Widgets';
import { Log } from '../util/Logger';
import type common from '@ohos.app.ability.common';

/// 顶层外壳:底部两 tab(发现 / 音阁)。全屏页(频道详情 / 播放页 / 设置)后续用
/// Navigation 承载,保持"整体转场、底部栏不跳动"的既有设计。
@Entry
@Component
struct Index {
  @State settings: SettingsStore = new SettingsStore();
  @State tab: number = 0;
  @State systemDark: boolean = true;

  aboutToAppear(): void {
    // getContext() 已废弃,API 12+ 用 UIContext 取宿主 context
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const app = AppContainer.get();
    app.boot(ctx);
    this.settings = app.settings;
    // 设备深色模式(mode 0 跟随系统时使用)
    const cfgMode: number | undefined = ctx.config?.colorMode;
    this.systemDark = cfgMode === 0;   // ColorMode.COLOR_MODE_DARK = 0
    Log.i('UI', `外壳就绪 systemDark=${this.systemDark}`);
  }

  private scheme(): Scheme {
    return Theme.scheme(this.settings.themeMode, this.settings.accentIndex, this.systemDark);
  }

  private fontScale(): number {
    return Theme.fontScale(this.settings.fontIndex);
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

  build() {
    Column() {
      Tabs({ barPosition: BarPosition.End, index: this.tab }) {
        TabContent() {
          this.discoverPlaceholder()
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
    .backgroundColor(this.scheme().background)
    // 沉浸式下自行避让状态栏/导航栏
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /// M3 将替换为真实发现页
  @Builder
  discoverPlaceholder() {
    Column() {
      ScreenHeader({
        scheme: this.scheme(),
        fontScale: this.fontScale(),
        title: '发现',
        subtitle: '听见余音'
      })
      EmptyHint({ scheme: this.scheme(), fontScale: this.fontScale(), text: '发现页将于 M3 接入' })
        .layoutWeight(1)
    }
    .width('100%').height('100%')
    .padding({ top: Metrics.topPadding })
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
