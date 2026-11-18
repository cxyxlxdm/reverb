import type common from '@ohos.app.ability.common';
import { LineHeight, Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { AppContainer } from '../AppContainer';
import { LanSyncController, LanSyncPhase, LanSyncViewState, LanSyncPeer, LanHandoffState } from '../sync/LanSyncController';
import { LanSyncFail } from '../sync/LanSyncWire';
import { LanSyncResult, LanSyncStage } from '../sync/LanSyncSession';
import { LanPeerHint } from '../sync/LanSyncLive';

/**
 * 「局域网同步」面板(Android `LanSyncDialog.kt` 的同构体)。
 *
 * 三层界面叠在同一个框里:
 * 1. **发现** —— 自动列出同一 Wi-Fi 下的设备,**同时**永远给出手动地址输入:
 *    AP 隔离 / 访客网络 / 企业 Wi-Fi 会让组播根本到不了对端,发现失败不是功能坏了。
 * 2. **配对** —— 六位数字要人眼比对。这套加密没有证书体系,配对码就是唯一的中间人判据。
 * 3. **结果** —— 只报**新增条数**(合并前后之差),不把远端条数当新增混报。
 *
 * **为什么是独立子组件,不是页面里的 @Builder**:框打开期间状态会连续变十几次
 * (发现 → 连接 → 配对 → 传输 → 完成)。若把 `LanSyncViewState` 挂在页面的 @State 上,
 * 外层 `if (showLanSync)` 的分支从头到尾不变 ⇒ 子树不重建 ⇒ @Builder 拿着旧值不刷新
 * (H6/H19/H27/H139 同一族)。状态收进子组件自己的 @State 才是能刷新的形状,
 * 顺带满足硬规矩 7(只重建这一个框)。
 *
 * 对话框打开即开始监听、关闭即停止 —— P0 不在后台常驻。
 */
@Component
export struct LanSyncDialog {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onDismiss: () => void = () => {};

  @State private view: LanSyncViewState = new LanSyncViewState();
  @State private manual: string = '';
  /**
   * 交接状态:与 `view` 分开,因为它每秒都在动(心跳 + 位置外推)。
   * 本组件只把它**传给子组件**;字段级刷新由 `HandoffSection` 的 `@ObjectLink` 承担 ——
   * 挂在 `view` 上就是每次心跳重建整个面板(硬规矩 7)。
   */
  @State private handoff: LanHandoffState = new LanHandoffState();

  private app: AppContainer = AppContainer.get();
  private controller: LanSyncController | null = null;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const c = new LanSyncController(ctx, this.app, (s: LanSyncViewState): void => {
      // 整值替换:V1 的观察粒度是对象,换一个对象才保证重渲(硬规矩 7)
      this.view = s;
    });
    this.controller = c;
    this.handoff = c.handoff;
    c.start();
  }

  aboutToDisappear(): void {
    const c = this.controller;
    this.controller = null;
    if (c !== null) c.stop();
  }

  /// 配对与传输中不允许点外面关掉:那会把 socket 抽走,另一端看到的是"网络中断"。
  private locked(): boolean {
    return this.view.phase === LanSyncPhase.CONFIRM || this.view.phase === LanSyncPhase.SYNCING;
  }

  private confirm(accept: boolean): void {
    const c = this.controller;
    if (c !== null) c.confirm(accept);
  }

  private retry(): void {
    const c = this.controller;
    if (c === null) return;
    c.stop();
    c.start();
  }

  private connect(): void {
    const c = this.controller;
    if (c === null) return;
    const text = this.manual.trim();
    // 空串时按钮本身是置灰的(见 listeningBody),这里只是兜底。
    if (text.length === 0) return;
    c.connectTo(text);
  }

  private failText(fail: LanSyncFail | null): string {
    if (fail === null) return L.s('lan_fail_io');
    switch (fail) {
      case LanSyncFail.CONNECT: return L.s('lan_fail_connect');
      case LanSyncFail.VERSION: return L.s('lan_fail_version');
      case LanSyncFail.PROTOCOL: return L.s('lan_fail_protocol');
      case LanSyncFail.DECRYPT: return L.s('lan_fail_decrypt');
      case LanSyncFail.CANCELLED: return L.s('lan_fail_cancelled');
      case LanSyncFail.PEER_CANCELLED: return L.s('lan_fail_peer_cancelled');
      default: return L.s('lan_fail_io');
    }
  }

  private stageText(stage: LanSyncStage): string {
    if (stage === LanSyncStage.SENDING) return L.s('lan_stage_sending');
    if (stage === LanSyncStage.RECEIVING) return L.s('lan_stage_receiving');
    return L.s('lan_stage_merging');
  }

  /// 配对码按三位一组显示。`String.chunked` 在 ArkTS 里没有,手写一份。
  private codeText(code: string): string {
    if (code.length <= 3) return code;
    return `${code.substring(0, 3)} ${code.substring(3)}`;
  }

  /**
   * 正文/说明行。**`lineHeight` 不能省**:ArkUI 的 `Text` 默认行距紧贴字身,而 Android 侧
   * Material 3 的 bodyMedium 自带 20/14 ≈ 1.43 的行高 —— 只搬字号不搬行高,面板里的几行字
   * 就会挤成一团(用户 2026-11-13 装机反馈「行间距太小」)。倍率表见 `theme/Theme.ets` 的 `LineHeight`。
   */
  @Builder
  labelLine(text: string, color: string) {
    Text(text)
      .fontSize(TypeScale.caption * this.fontScale)
      .lineHeight(TypeScale.caption * this.fontScale * LineHeight.label)
      .fontColor(color)
      .width('100%')
      .margin({ top: 6 })
  }

  @Builder
  bodyLine(text: string) {
    Text(text)
      .fontSize(TypeScale.body * this.fontScale)
      .lineHeight(TypeScale.body * this.fontScale * LineHeight.body)
      .fontColor(this.scheme.onBackground)
      .width('100%')
      .margin({ top: 6 })
  }

  /**
   * 可点的文字按钮。**点击区必须自己撑起来,不能只靠文字本身。**
   *
   * 1.0.8 用户反馈「取消 / 一致,开始同步 点不动」,原因就在这里:原先 `onClick` 直接挂在
   * `Text` 上,实测那两颗按钮的 bounds 高度只有 46 px(≈18vp),手指落在字的上下几像素就
   * 落到遮罩上 —— 而配对态遮罩是锁住的,表现就是"点了没反应"。
   * `Row` 给它 14vp 上下内边距,行高 ≈46vp,与系统建议的 48vp 最小点击区基本齐平(Android 侧用的是
   * Material TextButton,自带 48dp)。`enabled` 为 false 时置灰且吞掉点击(手动地址为空时的「连接」)。
   * 真机验收与 `dumpLayout` 读数陷阱见 docs/TROUBLESHOOTING.md H275。
   */
  @Builder
  actionButton(label: string, color: string, enabled: boolean, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(enabled ? color : withAlpha(color, 0.38))
    }
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .onClick(() => {
      if (enabled) onTap();
    })
  }

  /// 发现态:本机名字 / 地址 / 附近设备 / 手动输入。
  @Builder
  listeningBody() {
    Column() {
      this.bodyLine(L.f('lan_own_name', this.view.ownName))
      if (this.view.addresses.length === 0) {
        this.labelLine(L.s('lan_no_wifi'), this.scheme.error)
      } else {
        this.labelLine(L.s('lan_own_address'), this.scheme.onSurfaceVariant)
        ForEach(this.view.addresses, (addr: string) => {
          Text(addr)
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.onBackground)
            .fontWeight(FontWeight.Medium)
            .width('100%')
        }, (addr: string) => addr)
      }

      Text(L.s('lan_peers'))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.primary)
        .width('100%')
        .margin({ top: 14 })
      if (this.view.peers.length === 0) {
        this.labelLine(L.s('lan_no_peers'), this.scheme.onSurfaceVariant)
      } else {
        // 光列名字没人知道可以点 —— 用户反馈"附近的设备"下面缺一句提示。
        this.labelLine(L.s('lan_peers_hint'), this.scheme.onSurfaceVariant)
        ForEach(this.view.peers, (p: LanSyncPeer) => {
          Column() {
            Text(p.name)
              .fontSize(TypeScale.body * this.fontScale)
              .fontColor(this.scheme.onBackground)
              .width('100%')
            Text(p.address())
              .fontSize(TypeScale.caption * this.fontScale)
              .fontColor(this.scheme.onSurfaceVariant)
              .width('100%')
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .onClick(() => {
            const c = this.controller;
            if (c !== null) c.connectTo(p.address());
          })
        }, (p: LanSyncPeer) => p.serviceName)
      }

      TextInput({ text: this.manual, placeholder: L.s('lan_manual_hint') })
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .placeholderColor(this.scheme.onSurfaceVariant)
        .backgroundColor(withAlpha(this.scheme.onBackground, 0.06))
        .borderRadius(10)
        .width('100%')
        .margin({ top: 14 })
        .onChange((v: string) => { this.manual = v; })

      Row() {
        // 空串时置灰:Android 那边 TextButton 一直是可点的(点下去报「地址格式不对:」),
        // 而鸿蒙先前是静默 return,看起来像按钮坏了。统一成"没地址就不可点",两端都读得懂。
        //
        // ⚠️ **这颗按钮不能走 `actionButton`**:`enabled` 是 @Builder 的按值参数,只求值一次(H6/H19/H29),
        // 首次渲染时 `manual` 还是空串,于是按钮永远灰 —— 2026-11-13 真机验收手动地址兜底时踩到。
        // 判断必须在这层直接读 `this.manual`(listeningBody 随 @State 重跑,读到的是最新值)。
        Text(L.s('lan_connect'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.manual.trim().length > 0
            ? this.scheme.primary
            : withAlpha(this.scheme.primary, 0.38))
          .padding({ left: 14, right: 14, top: 14, bottom: 14 })
          .onClick(() => {
            if (this.manual.trim().length > 0) this.connect();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      this.labelLine(L.s('lan_tip'), this.scheme.onSurfaceVariant)
    }
    .width('100%')
  }

  /// 配对态:六位数字要两端一致。
  ///
  /// 标题与配对码都显式给 `width('100%')`:**`Column` 默认水平居中**,而正文行都是 100% 宽
  /// (内容左对齐),于是不给宽的标题会独自居中 —— 用户 2026-11-13 反馈「同步完成居中,
  /// 其他都居左不协调」。三端一律左对齐(Android/macOS 本来就是)。
  @Builder
  confirmBody() {
    Column() {
      Text(L.s('lan_confirm_title'))
        .fontSize(TypeScale.titleMedium * this.fontScale)
        .lineHeight(TypeScale.titleMedium * this.fontScale * 1.5)
        .fontColor(this.scheme.onBackground)
        .width('100%')
      this.bodyLine(L.f('lan_confirm_peer', this.view.peerName))
      Text(this.codeText(this.view.code))
        .fontSize(TypeScale.displaySmall * this.fontScale)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(6)
        .fontColor(this.scheme.primary)
        .width('100%')
        .margin({ top: 12 })
      this.labelLine(L.s('lan_confirm_body'), this.scheme.onSurfaceVariant)
    }
    .width('100%')
  }

  /// 结果:只报增量。`total` 为 0 时不摆一行全 0。
  ///
  /// 参数收 `LanSyncResult | null`(而不是在外层判空后直接传):build() 里不能声明局部变量,
  /// 而 ArkTS 对 `this.view.result !== null` 的收窄不会跨越表达式传给 @Builder —— 判空放在
  /// 这里是最不容易被编译器拒掉的形状。
  @Builder
  doneBody(result: LanSyncResult | null) {
    Column() {
      Text(L.s('lan_done_title'))
        .fontSize(TypeScale.titleMedium * this.fontScale)
        .lineHeight(TypeScale.titleMedium * this.fontScale * 1.5)
        .fontColor(this.scheme.onBackground)
        .width('100%')
      if (result !== null) {
        this.bodyLine(L.f('lan_done_with', result.peerName))
        if (result.total() > 0) {
          this.bodyLine(L.f('lan_done_added', result.subscriptions, result.favorites, result.stamps,
            result.notes, result.history, result.stats))
        } else {
          this.labelLine(L.s('lan_done_nothing'), this.scheme.onSurfaceVariant)
        }
      }
      // 交接是同步之后的「加时赛」:对端支持时才出现。老版本对端没有这一段,
      // 结果页与以前完全一样。
      if (this.handoff.available || this.handoff.note.length > 0) {
        HandoffSection({
          handoff: this.handoff,
          scheme: this.scheme,
          fontScale: this.fontScale,
          onTake: (): void => {
            const c = this.controller;
            if (c !== null) c.takePlayback();
          }
        })
      }
    }
    .width('100%')
  }

  @Builder
  failedBody() {
    Column() {
      Text(L.s('lan_failed_title'))
        .fontSize(TypeScale.titleMedium * this.fontScale)
        .lineHeight(TypeScale.titleMedium * this.fontScale * 1.5)
        .fontColor(this.scheme.onBackground)
        .width('100%')
      this.bodyLine(this.failText(this.view.fail))
      if (this.view.detail.length > 0) {
        this.labelLine(this.view.detail, this.scheme.onSurfaceVariant)
      }
    }
    .width('100%')
  }

  @Builder
  footerButtons() {
    Row({ space: 4 }) {
      if (this.view.phase === LanSyncPhase.CONFIRM) {
        this.actionButton(L.s('lan_cancel'), this.scheme.onSurfaceVariant, true, () => this.confirm(false))
        this.actionButton(L.s('lan_confirm_accept'), this.scheme.primary, true, () => this.confirm(true))
      } else if (this.view.phase === LanSyncPhase.DONE || this.view.phase === LanSyncPhase.FAILED) {
        this.actionButton(L.s('lan_close'), this.scheme.onSurfaceVariant, true, () => this.onDismiss())
        this.actionButton(this.view.phase === LanSyncPhase.DONE ? L.s('lan_again') : L.s('lan_retry'),
          this.scheme.primary, true, () => this.retry())
      } else {
        this.actionButton(L.s('lan_close'), this.scheme.onSurfaceVariant, true, () => this.onDismiss())
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
    .margin({ top: 4 })
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(withAlpha('#000000', 0.45))
        .onClick(() => {
          // 配对/传输中锁住遮罩:lock 状态下点空白什么都不做
          if (!this.locked()) this.onDismiss();
        })

      Column() {
        Text(L.s('lan_title'))
          .fontSize(TypeScale.titleLarge * this.fontScale)
          .fontColor(this.scheme.onBackground)
          .margin({ bottom: 8 })
          .alignSelf(ItemAlign.Start)

        Scroll() {
          Column() {
            if (this.view.phase === LanSyncPhase.IDLE) {
              Row({ space: 10 }) {
                LoadingProgress().width(18).height(18).color(this.scheme.primary)
                Text(L.s('lan_waiting'))
                  .fontSize(TypeScale.body * this.fontScale)
                  .lineHeight(TypeScale.body * this.fontScale * LineHeight.body)
                  .fontColor(this.scheme.onBackground)
              }
              .width('100%')
            } else if (this.view.phase === LanSyncPhase.LISTENING) {
              this.listeningBody()
            } else if (this.view.phase === LanSyncPhase.CONNECTING) {
              Row({ space: 10 }) {
                LoadingProgress().width(18).height(18).color(this.scheme.primary)
                Text(L.f('lan_connecting', this.view.target))
                  .fontSize(TypeScale.body * this.fontScale)
                  .lineHeight(TypeScale.body * this.fontScale * LineHeight.body)
                  .fontColor(this.scheme.onBackground)
                  .layoutWeight(1)
              }
              .width('100%')
            } else if (this.view.phase === LanSyncPhase.CONFIRM) {
              this.confirmBody()
            } else if (this.view.phase === LanSyncPhase.SYNCING) {
              Column() {
                this.bodyLine(L.f('lan_syncing', this.view.peerName))
                this.labelLine(this.stageText(this.view.stage), this.scheme.onSurfaceVariant)
                // 细进度条:外层是槽,内层按百分比铺满(ArkUI 没有现成的 LinearProgressIndicator,
                // 也不值得为此引入组件;宽度百分比一层就够)
                Stack() {
                  Row()
                    .width('100%')
                    .height(4)
                    .backgroundColor(withAlpha(this.scheme.onBackground, 0.12))
                    .borderRadius(2)
                  Row()
                    .width(`${this.view.percent}%`)
                    .height(4)
                    .backgroundColor(this.scheme.primary)
                    .borderRadius(2)
                }
                .width('100%')
                .height(4)
                .alignContent(Alignment.Start)
                .margin({ top: 8 })
              }
              .width('100%')
            } else if (this.view.phase === LanSyncPhase.DONE) {
              this.doneBody(this.view.result)
            } else if (this.view.phase === LanSyncPhase.FAILED) {
              this.failedBody()
            }
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: 380 })

        this.labelLine(L.s('lan_scope'), this.scheme.onSurfaceVariant)
        this.footerButtons()
      }
      .width('86%')
      .padding({ left: 22, right: 22, top: 22, bottom: 16 })
      .backgroundColor(this.scheme.surface)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 同步完成之后的交接区:另一台在播什么、能不能接过来。
 *
 * **独立子组件而不是 @Builder**:这里的值每秒都在变(心跳 + 位置外推)。`@ObjectLink`
 * 让重渲只落在这一块,而不是整个面板(硬规矩 7;与播放页把进度条独立成 `SeekBar` 同一个做法)。
 */
@Component
struct HandoffSection {
  @ObjectLink handoff: LanHandoffState;
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onTake: () => void = () => {};

  private clockText(ms: number): string {
    const total = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(total / 3600);
    const m = Math.floor(total % 3600 / 60);
    const s = total % 60;
    const two = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
  }

  /// 本机已经在放这一集(刚接手成功)时不再摆按钮 —— 按下去只会从当前位置重开一遍。
  private alreadyHere(hint: LanPeerHint | null): boolean {
    if (hint === null) return false;
    return this.handoff.localPlayingNow && this.handoff.localEpisodeId === hint.episode.id;
  }

  build() {
    Column() {
      // ⚠️ 这段**必须内联在 build() 里**,不能包成 `@Builder hintLine(hint)`。
      // 2026-11-15 真机实测:传成员表达式(`this.handoff.peerHint`)给 @Builder 是**按值**传,
      // `@ObjectLink` 更新后 build() 会重跑、按钮会跟着出现/消失,但 @Builder 里那两行 Text
      // **停在首次渲染的形态** —— 屏幕上一直写「另一台设备还没有在播放任何内容。」,
      // 而它下面「在此设备继续」是可点的(点下去真的接过去了)。
      // 判据:对方开始播放后,这一行必须在 1~2 秒内变成「正在播放/暂停在这一集 + 集名 · 位置」。
      if (this.handoff.peerHint !== null) {
        Text(L.s(this.handoff.peerHint.playing ? 'lan_handoff_playing' : 'lan_handoff_paused'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.primary)
          .width('100%')
          .margin({ top: 10 })
        Text(`《${this.handoff.peerHint.episode.title}》 · ` +
          (this.handoff.peerHint.approximate
            ? L.f('lan_handoff_approx', this.clockText(this.handoff.peerHint.positionMs))
            : this.clockText(this.handoff.peerHint.positionMs)))
          .fontSize(TypeScale.body * this.fontScale)
          .lineHeight(TypeScale.body * this.fontScale * LineHeight.body)
          .fontColor(this.scheme.onBackground)
          .width('100%')
          .margin({ top: 2 })
      } else {
        Text(L.s('lan_handoff_none'))
          .fontSize(TypeScale.caption * this.fontScale)
          .lineHeight(TypeScale.caption * this.fontScale * LineHeight.label)
          .fontColor(this.scheme.onSurfaceVariant)
          .width('100%')
          .margin({ top: 10 })
      }
      if (this.handoff.note.length > 0) {
        Text(this.handoff.note)
          .fontSize(TypeScale.caption * this.fontScale)
          .lineHeight(TypeScale.caption * this.fontScale * LineHeight.label)
          .fontColor(this.scheme.onSurfaceVariant)
          .width('100%')
          .margin({ top: 4 })
      }
      if (this.handoff.peerHint !== null && !this.alreadyHere(this.handoff.peerHint)) {
        Row() {
          Text(this.handoff.takingOver ? L.s('lan_handoff_taking') : L.s('lan_handoff_take'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.handoff.takingOver
              ? withAlpha(this.scheme.primary, 0.38)
              : this.scheme.primary)
            .padding({ left: 14, right: 14, top: 14, bottom: 14 })
            .onClick(() => {
              if (!this.handoff.takingOver) this.onTake();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      Text(L.s('lan_handoff_boundary'))
        .fontSize(TypeScale.caption * this.fontScale)
        .lineHeight(TypeScale.caption * this.fontScale * LineHeight.label)
        .fontColor(this.scheme.onSurfaceVariant)
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
  }
}
