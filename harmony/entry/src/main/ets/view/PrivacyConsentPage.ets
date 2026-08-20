import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { L } from '../util/L';

/**
 * 首次启动的隐私政策告知与同意页。
 *
 * 为什么必须有:《平台合规指引》7.5 要求首次启动即以显著方式提示用户阅读隐私政策,
 * 且**在用户同意之前不得申请任何个人信息或权限**。Android 端就是因为在同意前
 * 连了播放服务(→ 创建 ExoPlayer → 读系统网络信息)被判「同意前获取 SSID」而不通过。
 *
 * 所以这一页是**硬门**:未同意时整棵界面树只有它 —— 发现页一进来就会拉榜单,
 * 只要它没被渲染,就一个网络请求都不会发生。
 *
 * 「不同意」直接退出:本应用没有可以脱离网络使用的核心功能可退让,
 * 与其给一个残缺状态,不如说清楚。
 */
@Component
export struct PrivacyConsentPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onAccept: () => void = () => {};
  onDecline: () => void = () => {};

  build() {
    Column() {
      Text(L.s('privacy_consent_title'))
        .fontSize(TypeScale.headlineMedium * this.fontScale)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.scheme.onBackground)
        .width('100%')
      Scroll() {
        Text(L.s('privacy_consent_body'))
          .fontSize(TypeScale.body * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .lineHeight(TypeScale.body * this.fontScale * 1.7)
          .width('100%')
      }
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .layoutWeight(1)
      .margin({ top: 18, bottom: 12 })

      // 完整政策挂在官网,用系统浏览器打开(不内置 WebView)
      Text(L.s('privacy_read_full'))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.primary)
        .width('100%')
        .padding({ top: 4, bottom: 10 })
        .onClick(() => this.openPolicy())

      Row({ space: 12 }) {
        Button(L.s('privacy_decline'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onClick(() => this.onDecline())
        Button(L.s('privacy_accept'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onPrimary)
          .backgroundColor(this.scheme.primary)
          .layoutWeight(2)
          .onClick(() => this.onAccept())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.scheme.background)
    .padding({ left: 28, right: 28, top: Metrics.topPadding + 24, bottom: 32 })
    .alignItems(HorizontalAlign.Start)
  }

  private openPolicy(): void {
    // 用隐式 Want 交给系统浏览器;取不到上下文或没有可用浏览器时静默失败
    // (政策正文已经完整展示在本页,外链只是补充)。
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === null || ctx === undefined) return;
      (ctx as ESObject).startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: L.s('privacy_url')
      });
    } catch (e) {
      // 忽略:不影响同意流程
    }
  }
}
