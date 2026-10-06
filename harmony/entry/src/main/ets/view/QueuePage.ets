import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Episode } from '../model/Models';
import { PlayerController } from '../playback/PlayerController';
import { TopBar, EmptyHint, Artwork, Glyph, Sym } from './Widgets';
import { formatDurationSec } from './Components';

/// 播放队列(up next):点击单集直接跳播(摘出立即播),上移 / 下移 / 移除 / 清空。
/// 对应 Android `QueueScreen.kt`。队列语义由 PlayerController 持有(优先于上下文队列)。
@Component
export struct QueuePage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink player: PlayerController;
  onBack: () => void = () => {};

  build() {
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
            .onClick(() => this.player.clearQueue())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.player.userQueue.length === 0) {
        EmptyHint({
          scheme: this.scheme, fontScale: this.fontScale,
          text: L.s('queue_empty')
        })
          .layoutWeight(1)
      } else {
        List() {
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
        Artwork({ scheme: this.scheme, url: e.artworkUrl, dim: 46, corner: 8 })
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
