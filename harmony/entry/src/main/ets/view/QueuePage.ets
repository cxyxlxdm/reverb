import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Episode } from '../model/Models';
import { PlayerController } from '../playback/PlayerController';
import { TopBar, EmptyHint, Artwork, Glyph, Sym } from './Widgets';
import { formatDurationSec } from './Components';

/// 播放队列(up next):上移 / 下移 / 移除 / 清空。
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
          }, (e: Episode) => e.id)
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

      // 上移 / 下移 / 移除。图标与 Android QueueScreen 对齐:
      // KeyboardArrowUp / KeyboardArrowDown(折角,非实心箭头)/ Close。
      // 原先借「上一集/下一集」图标旋转 90° 充当上下移,形状是横向三角+竖线,语义不对。
      this.iconBtn(Sym.up, idx > 0, () => {
        this.player.moveInQueue(idx, idx - 1);
      })
      this.iconBtn(Sym.down, idx < this.player.userQueue.length - 1, () => {
        this.player.moveInQueue(idx, idx + 1);
      })
      Glyph({ symbol: Sym.close, dim: 18, color: this.scheme.onSurfaceVariant })
        .onClick(() => this.player.removeFromQueue(e.id))
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  iconBtn(icon: Resource, enabled: boolean, action: () => void) {
    Glyph({
      symbol: icon, dim: 20,
      color: enabled ? this.scheme.onBackground : withAlpha(this.scheme.onSurfaceVariant, 0.3)
    })
      .onClick(() => { if (enabled) action(); })
  }
}
