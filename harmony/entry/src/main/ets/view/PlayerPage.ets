import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { PlayerController } from '../playback/PlayerController';
import { AppContainer } from '../AppContainer';
import { Artwork, Glyph, GlyphImage, Sym } from './Widgets';
import { InkWave } from './InkWave';
import { Files } from '../util/Files';
import { FavoriteStore } from '../store/Stores';
import { StampStore } from '../store/StampStore';
import { SettingsStore } from '../store/SettingsStore';
import { formatTime } from './Components';
import { htmlToText } from '../util/HtmlText';
import { sealOptions, SealOption } from '../store/StampStore';
import { MomentCard, snapshotToPng, saveToGallery } from './MomentCard';
import { Log } from '../util/Logger';
import type common from '@ohos.app.ability.common';

/// 全屏播放页:两页轮播(封面+水墨 / shownotes)+ 进度 + 主控制 + 倍速/睡眠/收藏。
/// 对应 Android `PlayerScreen.kt`(首版不含印记/剪藏/队列页)。
@Component
export struct PlayerPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink player: PlayerController;
  /// 收藏心形、印记选中态、快退快进秒数都依赖这些 store,必须被观察(同 H27)。
  /// 原先读 `this.app.favorites` 等裸对象 —— 点收藏心形不会变色。
  @ObjectLink favorites: FavoriteStore;
  @ObjectLink stamps: StampStore;
  @ObjectLink settings: SettingsStore;
  onBack: () => void = () => {};
  onOpenQueue: () => void = () => {};

  @State page: number = 0;
  @State dragging: boolean = false;
  @State dragValue: number = 0;
  @State showSpeed: boolean = false;
  @State showSleep: boolean = false;
  @State showSeals: boolean = false;
  @State momentHint: string = '';

  private app: AppContainer = AppContainer.get();
  private sleepMinutes: number[] = [15, 30, 45, 60];

  private sliderValue(): number {
    return this.dragging ? this.dragValue : this.player.positionMs;
  }

  build() {
    Column() {
      // 顶栏:收起 | 队列 · 倍速 · 睡眠 · 收藏 · 更多(三项在「更多」里,同 Android)
      Row() {
        // 收起播放页:与 Android 一致用「下折角」(KeyboardArrowDown),不是返回箭头 ——
        // 这是"把全屏播放页收下去"的语义,和二级页返回不同。
        this.iconAction(Sym.down, this.scheme.onBackground, 0, 0, () => this.onBack())
        Blank()
        // 间距统一由这里决定(各元素的视觉盒都贴紧内容,见 iconAction 注释)
        Row({ space: 14 }) {
          // 各图标带一点负边距,把「墨迹内缩」抵掉,可见间距才真正齐平。
          //
          // 为什么不是放大图标:图标是**等比缩放**的,放大时内部留白同比例变大 ——
          // 试过把「更多」从 21 调到 26,间距反而从 18.7vp 涨到 20.0vp。
          // 内缩量是字形自带的,只能用负边距抵消。数值来自真机像素实测
          // (队列墨宽 19.7 / 更多 16.0 / 收藏 22.7,字形盒均为 21)。
          this.iconAction(Sym.queue,
            this.player.userQueue.length > 0 ? this.scheme.primary : this.scheme.onSurfaceVariant,
            0, -2, () => this.onOpenQueue())
          this.speedChip()
          this.sleepChip()
          this.favoriteChip()
          this.moreMenuChip()
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 6 })
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
      if (this.momentHint.length > 0) {
        Text(this.momentHint)
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .margin({ top: 6 })
      }
      // 供 componentSnapshot 截图的剪藏卡:移到可视区外(不能用 visibility.None,那样截不到)
      if (this.player.current !== null) {
        MomentCard({
          scheme: this.scheme, fontScale: this.fontScale,
          episode: this.player.current, positionMs: this.player.positionMs,
          seal: this.currentSeal()
        })
          .id('reverb-moment-card')
          .position({ x: -2000, y: 0 })
      }
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
        Text(L.s('shownotes'))
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
    return t.length > 0 ? t : L.s('shownotes_empty');
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
          Button(L.s('action_retry'))
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
      Text(`${forward ? this.settings.skipForwardSec : this.settings.skipBackSec}`)
        .fontSize(9 * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .onClick(() => {
      if (forward) this.player.skipForward(); else this.player.skipBackward();
    })
  }

  @Builder
  speedChip() {
    // 与 Android SpeedChip 一致:倍速数字 + 下拉小三角,强调色
    Row({ space: 2 }) {
      Text(`${this.player.speed}×`)
        .fontSize(TypeScale.caption * this.fontScale)
        .fontColor(this.scheme.primary)
      Glyph({ symbol: Sym.down, dim: 14, color: this.scheme.primary })
    }
      .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.12))
      .padding({ left: 10, right: 8, top: 5, bottom: 5 })
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
  /// 睡眠定时。与 Android `SleepChip` 一致:**药丸形,图标 + 文字**
  /// (剩余时间 / 「本集」/ 「睡眠」),激活时整体转强调色。原先只有一枚裸月亮图标。
  sleepChip() {
    Row({ space: 4 }) {
      Glyph({ symbol: Sym.sleep, dim: 18, color: this.sleepTint() })
      Text(this.sleepLabel())
        .fontSize(TypeScale.caption * this.fontScale)
        .fontColor(this.sleepTint())
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.12))
    .borderRadius(20)
    .alignItems(VerticalAlign.Center)
    .bindMenu(this.sleepMenu())
  }

  private sleepActive(): boolean {
    return this.player.sleepRemainingMs > 0 || this.player.sleepEndOfEpisode;
  }

  private sleepTint(): string {
    return this.sleepActive() ? this.scheme.primary : this.scheme.onSurfaceVariant;
  }

  private sleepLabel(): string {
    if (this.player.sleepRemainingMs > 0) return formatTime(this.player.sleepRemainingMs);
    if (this.player.sleepEndOfEpisode) return L.s('sleep_current');
    return L.s('sleep');
  }

  @Builder
  sleepMenu() {
    Menu() {
      ForEach(this.sleepMinutes, (m: number) => {
        MenuItem({ content: L.f('dur_m', m) })
          .onClick(() => this.player.setSleepTimer(m))
      }, (m: number) => `${m}`)
      MenuItem({ content: L.s('sleep_end_of_episode') }).onClick(() => this.player.setSleepEndOfEpisode())
      MenuItem({ content: L.s('sleep_off') }).onClick(() => this.player.cancelSleep())
    }
  }

  /**
   * 一个图标动作。
   *
   * **视觉盒子必须贴紧图标本身,不能套透明的 40×40 盒**:顶栏里混了两种元素 ——
   * 纯图标(透明背景)和药丸(有背景色)。若给图标套 40 宽的透明盒,可见间距就变成三种:
   * 图标↔图标 = space + 两侧各约 9.5 的透明内缩、药丸↔药丸 = space、图标↔药丸 = 居中值,
   * 看起来就是"倍速和睡眠挨得近、别的散得开"。
   *
   * 所以布局尺寸就用图标尺寸,间距**统一交给 Row 的 space**;点击区域改用
   * `responseRegion` 单独外扩(它只影响命中测试、不参与布局),这样既整齐又好点。
   */
  /// nudge:抵掉该字形墨迹相对字形盒的内缩量(见上方注释)。只对需要的一侧生效。
  @Builder
  iconAction(symbol: Resource, color: ResourceColor, nudgeL: number, nudgeR: number,
             action: () => void) {
    Glyph({ symbol: symbol, dim: 21, color: color })
      .margin({ left: nudgeL, right: nudgeR })
      .responseRegion({ x: -11, y: -11, width: 43, height: 43 })
      .onClick(action)
  }

  /**
   * 「更多」溢出菜单:保存此刻 / 剪藏·分享此刻 / 盖章。
   *
   * 与 Android `MoreMenu` 一致 —— Android 的注释写明这三项**收进溢出菜单是为了避免顶栏按钮过多**。
   * 鸿蒙原先把「章」「藏」两个文字按钮直接摊在顶栏,连收起共 7 个,挤成一排。
   *
   * 盖章的半模态**绑在本节点上、由菜单项置位**。原先是把 `.onClick(showSeals = true)` 和
   * `.bindSheet($$this.showSeals, ...)` 挂在**同一个节点**上:`$$` 是双向绑定,点空白处关闭时
   * ArkUI 自己把状态置 false,而同节点的 onClick 又会把它置回 true —— 两者竞争,表现就是
   * 「收回去 → 又弹一次 → 才最终收起」的偶发抖动。菜单项与 sheet 不在同一节点,冲突消失。
   */
  @Builder
  moreMenuChip() {
    GlyphImage({ icon: $r('sys.media.ohos_ic_public_more'), dim: 21, color: this.scheme.onSurfaceVariant })
      .margin({ left: -2.5 })
      .responseRegion({ x: -11, y: -11, width: 43, height: 43 })
      .bindMenu(this.moreMenu())
      .bindSheet($$this.showSeals, this.sealSheet(), { height: 330 })
  }

  @Builder
  moreMenu() {
    Menu() {
      MenuItem({ content: L.s('clip_save') })
        .onClick(() => { this.saveMoment(); })
      MenuItem({ content: L.s('clip_moment') })
        .onClick(() => { this.shareMoment(); })
      MenuItem({ content: this.currentSeal().length > 0 ? L.s('stamp_edit') : L.s('stamp_add') })
        .onClick(() => { this.showSeals = true; })
    }
  }

  private currentSeal(): string {
    const e = this.player.current;
    return e === null ? '' : this.stamps.sealFor(e.id);
  }

  @Builder
  sealSheet() {
    Column({ space: 14 }) {
      Text(L.s('seal_prompt'))
        .fontSize(TypeScale.titleSmall * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .margin({ top: 16 })
      Grid() {
        ForEach(sealOptions(), (o: SealOption) => {
          GridItem() {
            Column({ space: 3 }) {
              Text(o.seal)
                .fontSize(24 * this.fontScale)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.currentSeal() === o.seal ? this.scheme.primary : this.scheme.onBackground)
              Text(o.label)
                .fontSize(TypeScale.caption * this.fontScale)
                .fontColor(this.scheme.onSurfaceVariant)
            }
            .width('100%').height(66)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.currentSeal() === o.seal
              ? withAlpha(this.scheme.primary, 0.18) : withAlpha(this.scheme.onSurfaceVariant, 0.10))
            .borderRadius(12)
            .onClick(() => {
              const e = this.player.current;
              if (e === null) return;
              if (this.currentSeal() === o.seal) this.stamps.remove(e.id);
              else this.stamps.set(e.id, o.seal, e.title, e.podcastTitle);
              this.showSeals = false;
            })
          }
        }, (o: SealOption) => o.seal)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .height(226)
      .padding({ left: 20, right: 20 })
    }
    .width('100%')
    .backgroundColor(this.scheme.surface)
  }

  /// 剪藏 · 分享此刻:同样截图成 PNG,但交给系统分享面板而不是存相册。
  /// 对应 Android MoreMenu 的 onClip(那边走 ShareCards.share)。
  private async shareMoment(): Promise<void> {
    const e = this.player.current;
    if (e === null) return;
    const ui = this.getUIContext();
    const ctx = ui.getHostContext() as common.UIAbilityContext;
    const png = await snapshotToPng(ui, ctx, 'reverb-moment-card', 'reverb-moment.png');
    if (png === null) {
      this.momentHint = L.s('moment_failed');
      return;
    }
    const ok = await Files.shareImage(ctx, L.s('clip_share'), png);
    if (!ok) this.momentHint = L.s('moment_failed');
  }

  private async saveMoment(): Promise<void> {
    const e = this.player.current;
    if (e === null) return;
    const ui = this.getUIContext();
    const ctx = ui.getHostContext() as common.UIAbilityContext;
    const png = await snapshotToPng(ui, ctx, 'reverb-moment-card', 'reverb-moment.png');
    if (png === null) {
      this.momentHint = L.s('moment_failed');
      return;
    }
    const ok = await saveToGallery(ctx, png);
    this.momentHint = ok ? L.s('moment_saved') : L.s('moment_saved_partial');
    Log.i('Moment', this.momentHint);
  }

  @Builder
  favoriteChip() {
    this.iconAction(this.isFav() ? Sym.favorite : Sym.favoriteOff,
      this.isFav() ? this.scheme.primary : this.scheme.onSurfaceVariant,
      -1, 0, () => {
        const e = this.player.current;
        if (e !== null) this.favorites.toggle(e);
      })
  }

  private isFav(): boolean {
    const e = this.player.current;
    return e === null ? false : this.favorites.isFavorite(e.id);
  }
}
