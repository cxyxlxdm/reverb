import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { PlayerController } from '../playback/PlayerController';
import { Artwork } from './Widgets';

/// 底部常驻迷你播放条:细进度线 + 封面 + 标题/频道 + 播放暂停 + 下一集。
/// 点信息区打开全屏播放页。对应 Android `Components.kt` 的 MiniPlayer。
@Component
export struct MiniPlayerBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink player: PlayerController;
  onExpand: () => void = () => {};

  private progress(): number {
    if (this.player.durationMs <= 0) return 0;
    return Math.min(1, Math.max(0, this.player.positionMs / this.player.durationMs));
  }

  build() {
    Column() {
      // 细进度线
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(2).backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.18))
        Row().width(`${this.progress() * 100}%`).height(2).backgroundColor(this.scheme.primary)
      }
      .width('100%').height(2)

      Row({ space: 10 }) {
        Artwork({
          scheme: this.scheme,
          url: this.player.current === null ? '' : this.player.current.artworkUrl,
          dim: 42, corner: 8
        })
        Column({ space: 2 }) {
          Text(this.player.current === null ? '' : this.player.current.title)
            .fontSize(TypeScale.label * this.fontScale)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.scheme.onBackground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.player.current === null ? '' : this.player.current.podcastTitle)
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => this.onExpand())

        if (this.player.buffering) {
          LoadingProgress().width(22).height(22).color(this.scheme.primary)
        } else {
          Image(this.player.isPlaying ? $r('sys.media.ohos_ic_public_pause') : $r('sys.media.ohos_ic_public_play'))
            .width(22).height(22)
            .fillColor(this.scheme.onBackground)
            .onClick(() => this.player.togglePlayPause())
        }
        Image($r('sys.media.ohos_ic_public_play_next'))
          .width(19).height(19)
          .fillColor(this.player.hasNext ? this.scheme.onBackground : withAlpha(this.scheme.onSurfaceVariant, 0.35))
          .onClick(() => { if (this.player.hasNext) this.player.next(); })
      }
      .width('100%')
      .padding({ left: 14, right: 16, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(this.scheme.surface)
  }
}
