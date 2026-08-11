import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { PlayerController } from '../playback/PlayerController';
import { AppContainer } from '../AppContainer';
import { Artwork } from './Widgets';
import { InkWave } from './InkWave';
import { formatTime } from './Components';
import { htmlToText } from '../util/HtmlText';

/// 全屏播放页:两页轮播(封面+水墨 / shownotes)+ 进度 + 主控制 + 倍速/睡眠/收藏。
/// 对应 Android `PlayerScreen.kt`(首版不含印记/剪藏/队列页)。
@Component
export struct PlayerPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink player: PlayerController;
  onBack: () => void = () => {};
  onOpenQueue: () => void = () => {};

  @State page: number = 0;
  @State dragging: boolean = false;
  @State dragValue: number = 0;
  @State showSpeed: boolean = false;
  @State showSleep: boolean = false;

  private app: AppContainer = AppContainer.get();
  private sleepMinutes: number[] = [15, 30, 45, 60];

  private sliderValue(): number {
    return this.dragging ? this.dragValue : this.player.positionMs;
  }

  build() {
    Column() {
      // 顶栏:收起 + 倍速 + 睡眠 + 收藏
      Row({ space: 6 }) {
        Button() {
          Image($r('sys.media.ohos_ic_back'))
            .width(20).height(20).fillColor(this.scheme.onBackground)
        }
        .type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .width(40).height(40)
        .onClick(() => this.onBack())
        Blank()
        Image($r('sys.media.ohos_ic_public_albums'))
          .width(20).height(20)
          .fillColor(this.player.userQueue.length > 0 ? this.scheme.primary : this.scheme.onSurfaceVariant)
          .onClick(() => this.onOpenQueue())
        this.speedChip()
        this.sleepChip()
        this.favoriteChip()
      }
      .width('100%')
      .padding({ left: 4, right: 12, top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      // 轮播:封面(带水墨)/ shownotes
      Swiper() {
        this.coverPage()
        this.shownotePage()
      }
      .index(this.page)
      .loop(false)
      .indicator(false)
      .onChange((i: number) => { this.page = i; })
      .layoutWeight(1)

      // 页码点
      Row({ space: 7 }) {
        ForEach([0, 1], (i: number) => {
          Circle()
            .width(this.page === i ? 8 : 6)
            .height(this.page === i ? 8 : 6)
            .fill(this.page === i ? this.scheme.primary : withAlpha(this.scheme.onSurfaceVariant, 0.45))
        }, (i: number) => `${i}`)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .margin({ bottom: 10 })

      this.titleBlock()
      this.seekBar()
      this.controls()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 16 })
  }

  @Builder
  coverPage() {
    Stack() {
      // 水墨仅在"当前页可见且播放中"才流动
      InkWave({
        color: this.scheme.primary,
        animating: this.player.isPlaying && this.page === 0
      })
        .width('100%').height(300)
      Artwork({
        scheme: this.scheme,
        url: this.player.current === null ? '' : this.player.current.artworkUrl,
        dim: 240, corner: 20
      })
    }
    .width('100%').height('100%')
  }

  @Builder
  shownotePage() {
    Scroll() {
      Column({ space: 10 }) {
        Text('简介')
          .fontSize(TypeScale.titleSmall * this.fontScale)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.scheme.onBackground)
        Text(this.noteText())
          .fontSize(TypeScale.body * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .lineHeight(22)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ top: 6, bottom: 12 })
    }
    .scrollBar(BarState.Off)
    .width('100%').height('100%')
    .align(Alignment.Top)
  }

  private noteText(): string {
    const e = this.player.current;
    if (e === null) return '';
    const t = htmlToText(e.description);
    return t.length > 0 ? t : '这一集没有提供简介';
  }

  @Builder
  titleBlock() {
    Column({ space: 5 }) {
      Text(this.player.current === null ? '' : this.player.current.title)
        .fontSize(TypeScale.titleLarge * this.fontScale)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
      Text(this.player.current === null ? '' : this.player.current.podcastTitle)
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  @Builder
  seekBar() {
    Column() {
      Slider({
        value: this.sliderValue(),
        min: 0,
        max: Math.max(1, this.player.durationMs),
        style: SliderStyle.OutSet
      })
        .selectedColor(this.scheme.primary)
        .trackColor(withAlpha(this.scheme.onSurfaceVariant, 0.25))
        .blockColor(this.scheme.primary)
        .width('100%')
        .onChange((v: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.dragging = true;
            this.dragValue = v;
          } else {
            // 松手才真正 seek(拖动期间不被播放位置回写)
            this.player.seekTo(Math.floor(v));
            this.dragging = false;
          }
        })
      Row() {
        Text(formatTime(this.sliderValue()))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
        Blank()
        Text(formatTime(this.player.durationMs))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  controls() {
    Column({ space: 10 }) {
      if (this.player.playbackError.length > 0) {
        Row({ space: 10 }) {
          Text(this.player.playbackError)
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
          Button('重试')
            .fontSize(TypeScale.caption * this.fontScale)
            .height(30)
            .backgroundColor(this.scheme.primary)
            .fontColor(this.scheme.onPrimary)
            .onClick(() => this.player.retry())
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
      Row({ space: 22 }) {
        this.iconBtn($r('sys.media.ohos_ic_public_play_last'), 22, this.player.hasPrev, () => this.player.previous())
        this.skipBtn(false)
        // 主播放键
        Stack() {
          Circle().width(72).height(72).fill(this.scheme.primary)
          if (this.player.buffering) {
            LoadingProgress().width(30).height(30).color(this.scheme.onPrimary)
          } else {
            Image(this.player.isPlaying ? $r('sys.media.ohos_ic_public_pause') : $r('sys.media.ohos_ic_public_play'))
              .width(32).height(32).fillColor(this.scheme.onPrimary)
          }
        }
        .width(72).height(72)
        .onClick(() => this.player.togglePlayPause())
        this.skipBtn(true)
        this.iconBtn($r('sys.media.ohos_ic_public_play_next'), 22, this.player.hasNext, () => this.player.next())
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .width('100%')
    .margin({ top: 10 })
  }

  @Builder
  iconBtn(icon: Resource, size: number, enabled: boolean, action: () => void) {
    Image(icon)
      .width(size).height(size)
      .fillColor(enabled ? this.scheme.onBackground : withAlpha(this.scheme.onSurfaceVariant, 0.35))
      .onClick(() => { if (enabled) action(); })
  }

  /// 快退/快进:秒数标在图标下方(与 Android 一致的信息密度)。
  @Builder
  skipBtn(forward: boolean) {
    Column({ space: 1 }) {
      Image(forward ? $r('sys.media.ohos_ic_public_play_next') : $r('sys.media.ohos_ic_public_play_last'))
        .width(19).height(19)
        .fillColor(this.scheme.onSurfaceVariant)
      Text(`${forward ? this.app.settings.skipForwardSec : this.app.settings.skipBackSec}`)
        .fontSize(9 * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .onClick(() => {
      if (forward) this.player.skipForward(); else this.player.skipBackward();
    })
  }

  @Builder
  speedChip() {
    Text(`${this.player.speed}×`)
      .fontSize(TypeScale.caption * this.fontScale)
      .fontColor(this.scheme.onBackground)
      .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.12))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(12)
      .bindMenu(this.speedMenu())
  }

  @Builder
  speedMenu() {
    Menu() {
      ForEach(this.player.speedSteps, (s: number) => {
        MenuItem({ content: `${s}×` })
          .onClick(() => this.player.setSpeed(s))
      }, (s: number) => `${s}`)
    }
  }

  @Builder
  sleepChip() {
    Image($r('sys.media.ohos_ic_public_device_sound_filled'))
      .width(20).height(20)
      .fillColor(this.player.sleepRemainingMs > 0 || this.player.sleepEndOfEpisode
        ? this.scheme.primary : this.scheme.onSurfaceVariant)
      .bindMenu(this.sleepMenu())
  }

  @Builder
  sleepMenu() {
    Menu() {
      ForEach(this.sleepMinutes, (m: number) => {
        MenuItem({ content: `${m} 分钟` })
          .onClick(() => this.player.setSleepTimer(m))
      }, (m: number) => `${m}`)
      MenuItem({ content: '本集结束' }).onClick(() => this.player.setSleepEndOfEpisode())
      MenuItem({ content: '关闭' }).onClick(() => this.player.cancelSleep())
    }
  }

  @Builder
  favoriteChip() {
    Image($r('sys.media.ohos_ic_public_albums'))
      .width(20).height(20)
      .fillColor(this.isFav() ? this.scheme.primary : this.scheme.onSurfaceVariant)
      .onClick(() => {
        const e = this.player.current;
        if (e !== null) this.app.favorites.toggle(e);
      })
  }

  private isFav(): boolean {
    const e = this.player.current;
    return e === null ? false : this.app.favorites.isFavorite(e.id);
  }
}
