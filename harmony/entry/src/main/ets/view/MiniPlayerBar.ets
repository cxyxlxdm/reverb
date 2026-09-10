import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { PlayerController } from '../playback/PlayerController';
import { Artwork, Glyph, Sym } from './Widgets';

/// 底部常驻迷你播放条:细进度线 + 封面 + 标题/频道 + 播放暂停 + 下一集 + 队列入口。
/// 点信息区打开全屏播放页,点队列符号进队列页(与 macOS 底部条的列表按钮同位次
/// —— 都在最右)。对应 Android `Components.kt` 的 MiniPlayer。
@Component
export struct MiniPlayerBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 播放状态变化(播放/暂停/换集…)要重渲;**进度不在其中**,见下面的 pct
  @ObjectLink @Watch('onPlayerChange') player: PlayerController;
  onExpand: () => void = () => {};
  onOpenQueue: () => void = () => {};

  /**
   * 进度线的百分比,**取整**。
   *
   * 进度不再由 `@Observed` 推过来(那会让整页每秒重建十次,见 `PlaybackClock`),
   * 改为这里自己 1 秒轮询一次 clock。取整到 1% 是为了「值没变就不赋值」——
   * 一集 30 分钟的话 1% ≈ 18 秒,也就是这条 2px 细线平均 18 秒才重渲一次,
   * 而它的宽度精度本来就只有屏幕宽 /100。
   */
  @State pct: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.sample();
    this.onPlayerChange();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  /// 只在播放中轮询;暂停/无内容时停表,并补采一次(seek 后松手也要更新)
  private onPlayerChange(): void {
    const want = this.player.isPlaying && this.player.current !== null;
    if (want && this.timer < 0) {
      this.timer = setInterval(() => this.sample(), 1000);
    } else if (!want && this.timer >= 0) {
      this.stopTimer();
      this.sample();
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private sample(): void {
    const dur = this.player.durationMs;
    const p = dur <= 0 ? 0 : Math.min(100, Math.max(0, Math.floor(this.player.positionMs / dur * 100)));
    if (p !== this.pct) this.pct = p;
  }

  build() {
    Column() {
      // 细进度线
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(2).backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.18))
        Row().width(`${this.pct}%`).height(2).backgroundColor(this.scheme.primary)
      }
      .width('100%').height(2)

      Row({ space: 10 }) {
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
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
        .onClick(() => this.onExpand())

        if (this.player.loading || this.player.buffering) {
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
        // 队列入口:命中区同样外扩,不外扩会被左右两个大命中目标夹得点不中
        Glyph({ symbol: Sym.queue, dim: 20, color: this.scheme.onBackground })
          .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
          .onClick(() => this.onOpenQueue())
      }
      .width('100%')
      .padding({ left: 14, right: 16, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(this.scheme.surface)
  }
}
