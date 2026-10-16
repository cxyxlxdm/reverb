import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Episode } from '../model/Models';
import { PlayerController } from '../playback/PlayerController';
import { TopBar, EmptyHint, Artwork, Glyph, Sym } from './Widgets';
import { formatDurationSec, CHIPS_RESERVE_H, ConfirmDialog, ConfirmSpec } from './Components';

/// 待播(up next):点击单集直接跳播(摘出立即播),上移 / 下移 / 移除 / 清空。
/// 对应 Android `QueueScreen.kt`。队列语义由 PlayerController 持有(优先于上下文队列)。
///
/// 标题栏里那颗「清空」**只在独立页出现**:音阁里它是内嵌的一个分段,那颗动作由
/// 分段条右端去摆(`LibraryPage.barActions()`),与「历史」段同一个走法。
@Component
export struct QueuePage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink player: PlayerController;
  onBack: () => void = () => {};
  /// 封面点进去的频道页(与 `FeedPage` / `LibraryPage` 同一颗动作,由外壳 `Index.ets` 注入)。
  /// 待播这一列**只有跳转、没有多选** —— 队列本身就是一个待播集合,长按菜单里没有可批量收进去的目标。
  onOpenChannel: (feedUrl: string) => void = () => {};
  /// 待确认的「清空队列」(null = 没在确认)。那颗按钮只写这个数,动作在确认框里跑。
  @State pendingClear: ConfirmSpec | null = null;

  build() {
    // 确认框要连标题栏一起遮住,所以根是 Stack 而不是 Column(与 `LibraryPage` 同一形状)。
    Stack() {
      Column() {
        Row() {
          TopBar({
            scheme: this.scheme, fontScale: this.fontScale,
            title: L.s('queue_title'), onBack: () => this.onBack()
          })
            .layoutWeight(1)
          if (this.player.userQueue.length > 0) {
            Text(L.s('action_clear'))
              .fontSize(TypeScale.label * this.fontScale)
              .fontColor(this.scheme.primary)
              .padding({ right: Metrics.pagePadding })
              .onClick(() => {
                this.pendingClear = new ConfirmSpec(L.s('queue_title'), L.s('confirm_clear_queue'),
                  L.s('action_clear_confirm'), () => this.player.clearQueue());
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 列表本体与音阁那个分段**共用一个组件**(下面是空态,也是一个组件里的两分支),
        // 免得两处各写一遍行的操作与 key 规则 —— 那两条坑(H145 的 idx-in-key)会各修一半。
        QueueBody({
          scheme: this.scheme, fontScale: this.fontScale, player: this.player,
          bottomPad: 0, chipReserve: false,
          showChannelJump: true, onOpenChannel: this.onOpenChannel
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      if (this.pendingClear !== null) {
        ConfirmDialog({
          scheme: this.scheme,
          fontScale: this.fontScale,
          spec: this.pendingClear,
          onDismiss: () => { this.pendingClear = null; }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 待播列表主体(不含标题栏与那颗「清空」),供音阁「待播」段内嵌复用 ——
 * 与 Android 的 `QueueBody` 同一个形状。
 *
 * @param chipReserve 内嵌在玻璃分段条下面时要顶出一行占位(独立页不需要)。
 *   与音阁其余分段同一走法:那几段用 `List` 的首个占位 `ListItem`,因为分段条是悬浮的。
 */
@Component
export struct QueueBody {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop bottomPad: number = 0;
  @Prop chipReserve: boolean = false;
  /**
   * 封面是否单独可点进频道页。默认关,与 `EpisodeListItem.showChannelJump` 同一条口径
   * (漏传退回"整行只跳播",而不是画出一颗看着能点的假封面)。
   */
  @Prop showChannelJump: boolean = false;
  /// 动作走闭包、不走值:V1 里无装饰器的成员变量只在建组件时赋值一次(见 H29/H145)。
  onOpenChannel: (feedUrl: string) => void = () => {};
  @ObjectLink player: PlayerController;

  build() {
    Column() {
      if (this.player.userQueue.length === 0) {
        EmptyHint({
          scheme: this.scheme, fontScale: this.fontScale,
          text: L.s('queue_empty')
        })
          .layoutWeight(1)
      } else {
        List() {
          if (this.chipReserve) {
            ListItem() {
              Row().width('100%').height(CHIPS_RESERVE_H)
            }
          }
          ForEach(this.player.userQueue, (e: Episode, idx: number) => {
            ListItem() {
              this.row(e, idx)
            }
          }, (e: Episode, idx: number) => `${idx}-${e.id}`)
          // ↑ key **必须带上 idx**:只按 `e.id` 做 key 时,上移/下移之后那两条的 key 没变,
          //   ArkUI 认定「内容没变」而不重建行 —— 于是行里那个**值参数 `idx` 冻结在旧位置**,
          //   点一下「上移」发的还是 `moveInQueue(旧idx, 旧idx-1)`,动的是别人的条目。
          //   同一次冻结还让图标亮暗停在初始判定上(见 H145)。队列只有几十条,重建代价可忽略。
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  row(e: Episode, idx: number) {
    Row({ space: 10 }) {
      // 点击区 = 封面 + 文案;操作图标与它平级而非嵌套,避免 ArkUI 嵌套 onClick 的手势歧义。
      Row({ space: 10 }) {
        // 封面上叠一层「只吃这一块」的透明盖(与播放条 `MiniPlayerBar`、列表行同一形状)。
        // ⚠️ `onTouch` 里那条 `stopPropagation` **不能省**:本端子组件 onClick 处理完照样
        // 冒泡给父 onClick(见 H185 同族实测),不拦的话点封面 = 进频道 + 立刻跳播这一集。
        Stack() {
          Artwork({ scheme: this.scheme, url: e.artworkUrl, dim: 46, corner: 8 })
          if (this.showChannelJump && e.feedUrl.length > 0) {
            Column().width(46).height(46).borderRadius(8)
              .backgroundColor(Color.Transparent)
              .onClick(() => this.onOpenChannel(e.feedUrl))
              .onTouch((event: TouchEvent) => event.stopPropagation())
              .accessibilityText(L.s('a11y_open_channel'))
          }
        }
        Column({ space: 3 }) {
          Text(e.title)
            .fontSize(TypeScale.titleSmall * this.fontScale)
            .fontColor(this.scheme.onBackground)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${e.podcastTitle}${formatDurationSec(e.durationSec).length > 0 ? '  ·  ' + formatDurationSec(e.durationSec) : ''}`)
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)
      .onClick(() => this.player.playFromQueue(e.id))

      // 上移 / 下移 / 移除。图标与 Android QueueScreen 对齐:
      // KeyboardArrowUp / KeyboardArrowDown(折角,非实心箭头)/ Close。
      // 原先借「上一集/下一集」图标旋转 90° 充当上下移,形状是横向三角+竖线,语义不对。
      this.iconBtn(Sym.up, () => idx > 0, L.s('a11y_queue_up'), () => {
        this.player.moveInQueue(idx, idx - 1);
      })
      this.iconBtn(Sym.down, () => idx < this.player.userQueue.length - 1, L.s('a11y_queue_down'), () => {
        this.player.moveInQueue(idx, idx + 1);
      })
      Glyph({ symbol: Sym.close, dim: 18, color: this.scheme.onSurfaceVariant })
        .accessibilityText(L.s('a11y_queue_remove'))
        .onClick(() => this.player.removeFromQueue(e.id))
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  /// 上移 / 下移的图标。**`enabledOf` 必须是闭包**:`@Builder` 的值参数只求值一次(见 H29/H145),
  /// 传布尔进来的结果是「首条的上移永远是亮的、末条的下移永远按不动」,而列表变化之后亮暗也不会跟着改。
  @Builder
  iconBtn(icon: Resource, enabledOf: () => boolean, label: string, action: () => void) {
    Glyph({
      symbol: icon, dim: 20,
      color: enabledOf() ? this.scheme.onBackground : withAlpha(this.scheme.onSurfaceVariant, 0.3)
    })
      .accessibilityText(label)
      .onClick(() => { if (enabledOf()) action(); })
  }
}
