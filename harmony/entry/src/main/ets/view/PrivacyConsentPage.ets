import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { L } from '../util/L';

/**
 * 首次启动的隐私政策告知与同意页。
 *
 * 为什么必须有:平台合规指引要求首次启动即以显著方式提示用户阅读隐私政策,
 * 且**在用户同意之前不得申请任何个人信息或权限**。Android 端就是因为在同意前
 * 连了播放服务(→ 创建 ExoPlayer → 读系统网络信息)被判「同意前获取 SSID」不通过。
 *
 * 所以这一页是**硬门**:未同意时整棵界面树只有它 —— 发现页一进来就会拉榜单,
 * 只要它没被渲染,就一个网络请求都不会发生。
 *
 * 「不同意」直接退出:本应用没有可以脱离网络使用的核心功能可退让,
 * 与其给一个残缺状态,不如说清楚。
 *
 * 版式与 Android `PrivacyConsentScreen.kt` 逐项对齐(那边是在真机上逐轮调出来的):
 * 标题居左 + 梁金细线、正文放大一号并可滚动、滚不到底时底部叠渐隐、两个按钮靠右间隔 12。
 */
@Component
export struct PrivacyConsentPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /**
   * 系统栏避让高度,由 Index 传入。
   *
   * **必须自己避让**:本页渲染在 shell() 之外(未同意时不进主界面树),吃不到那里的
   * `padding({ top: topInset, bottom: bottomInset })`。原先这里写的是常量
   * `Metrics.topPadding + 24`(36vp),在状态栏更高的机型上标题就会挤到时间/信号旁边。
   * Android 侧同一处的表现与修法完全一样(那边是漏了 `systemBarsPadding()`)。
   */
  @Prop topInset: number;
  @Prop bottomInset: number;
  onAccept: () => void = () => {};
  onDecline: () => void = () => {};

  /// 正文滚动位置 + 可视高度 + 内容高度,三者合起来判断"还能不能往下滚"(见 canScrollForward)
  private bodyScroller: Scroller = new Scroller();
  @State private scrolled: number = 0;
  @State private viewH: number = 0;
  @State private contentH: number = 0;

  build() {
    Column() {
      // 标题居左 + 下方一道 40×3 的「梁金」细线,与 app 里 ScreenHeader 同一形态。
      //
      // 试过居中,但底部两个按钮是靠右的 —— 那样一页里就有三种对齐
      // (标题居中 / 正文居左 / 按钮居右),反而散。居左只剩内容左、操作右两种。
      Text(L.s('privacy_consent_title'))
        .fontSize(TypeScale.headlineMedium * this.fontScale)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.scheme.onBackground)
        .width('100%')
      Row()
        .width(40)
        .height(3)
        .backgroundColor(this.scheme.secondary)
        .borderRadius(2)
        .margin({ top: 12 })

      // 正文可滚动区。字号放大后正文通常超出一屏,底部叠一层向背景色的渐隐:
      // 既提示"下面还有",也让截断处不至于把半行字生硬切开。
      Stack({ alignContent: Alignment.Bottom }) {
        Scroll(this.bodyScroller) {
          // 逐字稿那段单独一条串再拼上来,与 Android 侧同一结构(那端因为分渠道必须拆开,
          // 本端拆开是为了两端文案能逐段对照,改动时不容易只改一边)
          // 局域网同步那一段是 2026-11-13 补的:之前只写了「六分区/加密/不经服务器」,
          // 没写删除墓碑随后补齐 —— 与 Android `privacy_consent_lan` 同一份文案。
          Text(`${L.s('privacy_consent_body')}\n\n${L.s('privacy_consent_auth')}\n\n${L.s('privacy_consent_video')}\n\n${L.s('privacy_consent_asr')}\n\n${L.s('privacy_consent_lan')}`)
            .fontSize(TypeScale.bodyLarge * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .lineHeight(TypeScale.bodyLarge * this.fontScale * 1.7)
            .width('100%')
            .onAreaChange((_o: Area, n: Area) => { this.contentH = Number(n.height); })
        }
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .width('100%')
        .height('100%')
        .onDidScroll(() => { this.scrolled = this.bodyScroller.currentOffset().yOffset; })

        if (this.canScrollForward()) {
          Row()
            .width('100%')
            .height(40)
            // 起点用**背景色的零透明**而不是 Color.Transparent:后者是 #00000000,
            // 往不透明背景插值时中段会泛出一道灰(浅色主题下尤其明显)。
            .linearGradient({
              angle: 180,
              colors: [[withAlpha(this.scheme.background, 0), 0.0], [this.scheme.background, 1.0]]
            })
            // 渐隐只是装饰,不能把这 40vp 变成滑不动的死区
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 28 })
      .onAreaChange((_o: Area, n: Area) => { this.viewH = Number(n.height); })

      // 正文与这个链接之间要留够 —— 正文是一大段密排文字,贴太近会像是正文的最后一行
      Text(L.s('privacy_read_full'))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.primary)
        .width('100%')
        .margin({ top: 22 })
        .padding({ top: 4, bottom: 12 })
        .onClick(() => this.openPolicy())

      // 两个按钮都靠右,之间 12。Android 那边试过三档:紧贴(6)太挤、撑满整行(131)太散,
      // 12 落在中间。
      Row({ space: 12 }) {
        Button(L.s('privacy_decline'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .backgroundColor(Color.Transparent)
          .height(36)
          .padding({ left: 16, right: 16 })
          .onClick(() => this.onDecline())
        Button(L.s('privacy_accept'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onPrimary)
          .backgroundColor(this.scheme.primary)
          .borderRadius(18)
          .height(36)
          .padding({ left: 22, right: 22 })
          .onClick(() => this.onAccept())
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.scheme.background)
    .padding({
      left: 28,
      right: 28,
      top: this.topInset + 28,
      bottom: this.bottomInset + 28
    })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 正文下方还有没有内容(对应 Compose 的 `ScrollState.canScrollForward`)。
   *
   * 为什么不直接用 `Scroller.isAtEnd()`:首帧布局尚未完成时它的返回值不可信,而渐隐恰恰
   * 需要在**用户还没滚动过**的第一帧就正确显示。改为拿实测的内容高/可视高/已滚距离算,
   * 内容本就一屏放得下时结果为 false,不会多出一道灰边。留 2vp 容差避免浮点抖动。
   */
  private canScrollForward(): boolean {
    if (this.viewH <= 0 || this.contentH <= 0) return false;
    return this.contentH - this.viewH - this.scrolled > 2;
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
