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
import { formatDecimal } from '../util/NumberFmt';
import { htmlToText } from '../util/HtmlText';
import { sealOptions, SealOption } from '../store/StampStore';
import { MomentCard, snapshotToPng, saveToGallery } from './MomentCard';
import { SeekBar } from './SeekBar';
import { SleepCountdownText } from './SleepCountdownText';
import { TranscriptPane } from './TranscriptPane';
import { Features } from '../Features';
import { Episode } from '../model/Models';
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
  /**
   * 频道名点击 → 跳该频道主页。
   *
   * **这个入口不是锦上添花:它是播放中单集能到达频道页的唯一路径。**
   * 从「最新」聚合或电台播出来的单集,那个频道很可能还没订阅,音阁的订阅列表里
   * 自然也找不到 —— 于是没有任何地方能订阅它。漏了这个回调,鸿蒙端就等于
   * 「听到喜欢的节目但订阅不了」(见 H69)。
   */
  onOpenPodcast: (feedUrl: string) => void = () => {};

  @State page: number = 0;
  /**
   * 离屏剪藏卡上要写的时间点。
   *
   * 为什么要单独存一个:进度已经不再驱动本页重渲(见 `SeekBar` / `PlaybackClock`),
   * 那张常驻离屏的卡片若还读实时进度,截出来的图会停在**它最后一次重渲时**的时刻。
   * 所以改成按「剪藏」的那一下取值 —— 这也更贴合「剪藏此刻」的语义:
   * 用户按下时听到的那一秒,而不是渲染发生的那一秒。
   */
  @State momentPosMs: number = 0;
  @State showSpeed: boolean = false;
  @State showSleep: boolean = false;
  @State showSeals: boolean = false;
  /**
   * 批注弹层的显位,与 `showSeals` 同一手法(半模态,见 moreMenuChip 的注释)。
   *
   * ⚠️ **`.bindSheet` 只能挂在另一个节点上,不能和盖章那个共用 `moreMenuChip`**:
   * 一个节点只有一个 bindSheet 属性,后写的会把先写的顶掉,表现是"点了写批注什么也没弹"。
   * 现在它挂在本页根 Column 上。
   */
  @State showNote: boolean = false;
  /**
   * 批注要记的那一秒 —— **按下「写批注」那一刻的快照,不是跟随播放器的实时值**。
   *
   * 与离屏剪藏卡的 `momentPosMs` 同因:进度已经不再驱动本页重渲(见 `SeekBar` / `PlaybackClock`),
   * 所以这里必须显式取一次;而就算能跟随,写一句话要十几秒,期间时间会一路往后走 ——
   * 保存下来的秒与看到的那一秒不是同一秒,而"记下这一秒"正是这个功能唯一的意义(硬规矩 6)。
   */
  @State notePosMs: number = 0;
  /// 批注弹层里的正文草稿。**不叫 `noteText`**:本页已有一个 `noteText()` 方法
  /// (节目笔记那一页的正文),同名会撞成一个标识符 —— 编译器报 duplicate identifier。
  @State noteDraft: string = '';
  /**
   * 按下那一刻的**集**,与 `notePosMs` 一起冻结。
   *
   * 普通成员而不是 `@State`:这个值不参与渲染(弹层只显示时间不显示标题),
   * 挂成 `@State` 等于白白让本页多一次重渲的触发源(硬规矩 7 那条观察粒度的账)。
   *
   * 只冻结时间不冻结集,会在"弹层开着的时候恰好播完接下一集"时把批注挂到**下一集**上 ——
   * 表现是"我明明写的是上一集那一句",而界面里显示的时间戳看着还是合理的(见 A2-3#11)。
   */
  private noteEpisode: Episode | null = null;
  @State momentHint: string = '';

  private app: AppContainer = AppContainer.get();
  private sleepMinutes: number[] = [15, 30, 45, 60];

  /**
   * 有没有第三页(逐字稿)。与 Android 用**同一个表达式**:
   * `(有本机识别 && 设置开着) || 这一集有官方稿`。
   *
   * 本端 `Features.LOCAL_ASR` 目前是 false(系统识别质量不够用,见那里的注释),
   * 于是这个式子退化成"**只有发布方给了逐字稿的那些集才有第三页**" ——
   * 与 Android 大陆商店渠道同一行为:没稿就别出一个空页。
   */
  private showTranscript(): boolean {
    const e = this.player.current;
    if (e === null) return false;
    // 直播流不给第三页:逐字稿要么下载整段、要么转写整段,而直播没有"整段"这个边界 ——
    // 挂上去就是一个永远转不完、也永远不落盘的任务(与 Android / macOS 同一条)。
    if (e.isLive === true) return false;
    return (Features.LOCAL_ASR && this.settings.transcriptionEnabled) || e.transcriptUrl.length > 0;
  }

  /**
   * 直播流没有时间轴:进度条与两端时间换成一句 LIVE。
   *
   * 判据是 `isLive && duration <= 0` 而不是只看 isLive —— 用户粘进来的也可能是一个**有限**的
   * 音频文件,播放器一旦报出时长,进度条与快进快退就重新有意义,那时不该再装作是直播。
   */
  private liveNoTimeline(): boolean {
    const e = this.player.current;
    return e !== null && e.isLive === true && this.player.durationMs <= 0;
  }

  private pageDots(): number[] {
    return this.showTranscript() ? [0, 1, 2] : [0, 1];
  }

  /// 点「生成逐字稿」:已下载的单集直接用本地文件(纯离线),否则让识别侧自己去下
  private startTranscript(): void {
    const e = this.player.current;
    if (e === null) return;
    const local = this.app.downloads.pathOf(e.id);
    this.app.transcripts.start(e, this.settings.language, local === null ? '' : local);
  }

  build() {
    Column() {
      // 顶栏:收起 | 队列 · 倍速 · 睡眠 · 收藏 · 更多(三项在「更多」里,同 Android)
      Row() {
        // 收起播放页:与 Android 一致用「下折角」(KeyboardArrowDown),不是返回箭头 ——
        // 这是"把全屏播放页收下去"的语义,和二级页返回不同。
        this.iconAction(() => Sym.down, () => this.scheme.onBackground,
          L.s('a11y_collapse_player'), 0, 0, () => this.onBack())
        Blank()
        // 间距统一由这里决定(各元素的视觉盒都贴紧内容,见 iconAction 注释)
        Row({ space: 14 }) {
          // 各图标带一点负边距,把「墨迹内缩」抵掉,可见间距才真正齐平。
          //
          // 为什么不是放大图标:图标是**等比缩放**的,放大时内部留白同比例变大 ——
          // 试过把「更多」从 21 调到 26,间距反而从 18.7vp 涨到 20.0vp。
          // 内缩量是字形自带的,只能用负边距抵消。数值来自真机像素实测
          // (队列墨宽 19.7 / 更多 16.0 / 收藏 22.7,字形盒均为 21)。
          this.iconAction(() => Sym.queue,
            () => this.player.userQueue.length > 0 ? this.scheme.primary : this.scheme.onSurfaceVariant,
            L.s('queue_title'), 0, -2, () => this.onOpenQueue())
          // 直播不给倍速:AVPlayer 对直播流回 `Operate Not Permit: The stream is live stream,
          // not support rate` —— 发出去只会让界面写着 1.5× 而声音不变(见 H239)。
          // 三端一起藏,L 形与 Android 同构。
          if (!this.liveNoTimeline()) this.speedChip()
          this.sleepChip()
          this.favoriteChip()
          this.moreMenuChip()
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      // 轮播:封面(带水墨)/ shownotes /(逐字稿)
      Swiper() {
        this.coverPage()
        this.shownotePage()
        if (this.showTranscript()) {
          TranscriptPane({
            scheme: this.scheme,
            fontScale: this.fontScale,
            store: this.app.transcripts,
            player: this.player,
            active: this.page === 2,
            playing: this.player.isPlaying,
            wordHighlight: this.settings.wordHighlight,
            episodeId: this.player.current === null ? '' : this.player.current.id,
            uiLanguage: this.settings.language,
            onStart: () => { this.startTranscript(); }
          })
        }
      }
      .index(this.page)
      .loop(false)
      .indicator(false)
      .onChange((i: number) => { this.page = i; })
      .layoutWeight(1)

      // 页码点
      Row({ space: 7 }) {
        ForEach(this.pageDots(), (i: number) => {
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
      if (this.liveNoTimeline()) {
        this.liveRow()
      } else {
        // 进度条是独立组件:它自己轮询播放位置,于是进度更新不再重渲整个播放页(H64)
        SeekBar({
          scheme: this.scheme,
          fontScale: this.fontScale,
          durationMs: this.player.durationMs,
          playing: this.player.isPlaying,
          clock: this.player.clock,
          onSeek: (ms: number) => { this.player.seekTo(ms); }
        })
      }
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
          episode: this.player.current, positionMs: this.momentPosMs,
          seal: this.currentSeal()
        })
          .id('reverb-moment-card')
          .position({ x: -2000, y: 0 })
      }
    }
    .width('100%')
    .height('100%')
    // 左右 24 与 Android 的 `padding(horizontal = 24.dp)` 对齐 —— 原先 20,标题看着贴边
    .padding({ left: 24, right: 24, bottom: 16 })
    // 批注弹层。挂在这里而不是 moreMenuChip 上:那个节点已经被盖章的 sheet 占了
    // (一个节点只有一个 bindSheet)。高度按「标题 + 时间 + 三行输入 + 按钮」给足,
    // 键盘弹起时由系统抬升 —— 这条**未真机验过**,装机判据是"输入框不被键盘盖住"。
    .bindSheet($$this.showNote, this.noteSheet(), { height: 320, backgroundColor: this.scheme.surface })
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

  /// 简介解析的记忆化缓存(**不能是 @State**:在 build 里赋值会触发再次重渲)。
  /// 只在换集时重解析。
  private noteId: string = '';
  private noteVal: string = '';

  /**
   * 节目简介纯文本。
   *
   * **必须缓存**:本页观察 player,而播放中 500ms 一次 tick 就会重渲一遍,
   * 原先每次重渲都把整段 HTML 重跑十道正则 —— 有些播客的 shownotes 有几十 KB,
   * 于是主线程每秒被占两次,轻则 CPU 长期高位(外部反馈的第 3 项),
   * 重则直接 THREAD_BLOCK_6S 卡死(第 1 项),连带点击与长按被丢弃(第 2 项)。
   * macOS 端早先已做过同样的「解析移出渲染路径」,鸿蒙这边漏了。
   */
  private noteText(): string {
    const e = this.player.current;
    if (e === null) return '';
    if (e.id !== this.noteId) {
      this.noteId = e.id;
      this.noteVal = htmlToText(e.description);
    }
    return this.noteVal.length > 0 ? this.noteVal : L.s('shownotes_empty');
  }

  /// 当前单集所属频道的 RSS 地址;没在播或该集没带 feedUrl 时是空串。
  /// 空串意味着到不了频道页(例如引导音频),此时频道名不可点。
  private currentFeedUrl(): string {
    return this.player.current === null ? '' : this.player.current.feedUrl;
  }

  @Builder
  /**
   * 单集标题 + 频道名。**字体与间距对齐 Android 播放页**(`PlayerScreen.kt` 的同一块)。
   *
   * 逐项对齐过的差异,以及为什么:
   * - **字重用 Normal,不是 Medium。** Android 那边写的是 SemiBold,但 Android 的中文字体
   *   (Noto Sans CJK)在 600 这一档往往没有真字面、要合成或回落,**实际观感偏轻**;
   *   而 HarmonyOS Sans 有真的 Medium 字面,同样写 Medium 就明显比 Android 粗。
   *   要"看起来一样",这里就得比规格书上低一档 —— 照抄 SemiBold 只会更粗。
   * - **行高 28**:Material 3 的 titleLarge 是 22/28,鸿蒙这边原先没设行高,
   *   两行标题挤在一起,这是"更丑"的另一半原因。
   * - **频道名 14 而不是 12**:Android 用的是 bodyMedium(14sp),原先这里用 label(12)偏小。
   * - 间距:标题→频道名 6、频道名→进度条 20,都取 Android 的值。
   *
   * 页面左右内边距在 build() 里从 20 改成了 **24**(Android 是 `padding(horizontal = 24.dp)`)
   * —— 那是"贴边"的直接原因。
   */
  titleBlock() {
    Column({ space: 6 }) {
      Text(this.player.current === null ? '' : this.player.current.title)
        .fontSize(TypeScale.titleLarge * this.fontScale)
        .fontWeight(FontWeight.Normal)
        .lineHeight(28 * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
      Text(this.player.current === null ? '' : this.player.current.podcastTitle)
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.currentFeedUrl().length > 0 ? this.scheme.primary : this.scheme.onSurfaceVariant)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .onClick(() => {
          const feed: string = this.currentFeedUrl();
          if (feed.length > 0) this.onOpenPodcast(feed);
        })
    }
    .width('100%')
    .margin({ bottom: 20 })
  }

  /**
   * 直播的「没有进度」一行:红点 + LIVE。高度与「进度条 + 两端时间」那一块相当,版面不跳
   * (与 Android `PlayerScreen.kt` 的 liveNoTimeline 分支同形)。
   */
  @Builder
  liveRow() {
    Row({ space: 8 }) {
      Circle().width(8).height(8).fill(this.scheme.error)
      Text(L.s('live_on_air'))
        .fontSize(TypeScale.labelLarge * this.fontScale)
        .fontColor(this.scheme.error)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(48)
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
        // 直播没有上一集/下一集,也没有可跳的时间轴:四颗键里只留主播放键
        this.iconBtn($r('sys.media.ohos_ic_public_play_last'), 22,
          () => !this.liveNoTimeline() && this.player.hasPrev,
          L.s('a11y_prev'), () => this.player.previous())
        if (!this.liveNoTimeline()) {
          this.skipBtn(false)
        }
        // 主播放键
        Stack() {
          Circle().width(72).height(72).fill(this.scheme.primary)
          if (this.player.loading || this.player.buffering) {
            LoadingProgress().width(30).height(30).color(this.scheme.onPrimary)
          } else {
            Image(this.player.isPlaying ? $r('sys.media.ohos_ic_public_pause') : $r('sys.media.ohos_ic_public_play'))
              .width(32).height(32).fillColor(this.scheme.onPrimary)
          }
        }
        .width(72).height(72)
        .accessibilityText(L.s(this.player.isPlaying ? 'a11y_pause' : 'a11y_play'))
        .onClick(() => this.player.togglePlayPause())
        if (!this.liveNoTimeline()) {
          this.skipBtn(true)
        }
        this.iconBtn($r('sys.media.ohos_ic_public_play_next'), 22,
          () => !this.liveNoTimeline() && this.player.hasNext,
          L.s('a11y_next'), () => this.player.next())
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .width('100%')
    .margin({ top: 10 })
  }

  /**
   * 上一集 / 下一集。**`enabledOf` 必须是闭包,不能是布尔值参数** —— 与 `iconAction`
   * 那处同一个坑(见 H29),但这里的症状更重,而且是真机量出来的(见 H145):
   * 值参数冻结在**首次渲染**那一刻,冷启动时队列里只有当前这一集、`hasPrev=false`,
   * 于是按了「下一集」换到第二集之后,「上一集」仍然是暗的、点下去 `if (enabled)` 直接吃掉,
   * 用户看到的就是「播到第二集了却按不动上一集」。
   * 闭包在 builder 体里被调用时才读 `this.player.hasPrev`,那次读会登记依赖,所以既亮得对、
   * 也按得动。标签 `label` 是静态的,继续按值传(动态标签要留在渲染处,见 `iconAction` 注释)。
   */
  @Builder
  iconBtn(icon: Resource, size: number, enabledOf: () => boolean, label: string, action: () => void) {
    Image(icon)
      .width(size).height(size)
      .fillColor(enabledOf() ? this.scheme.onBackground : withAlpha(this.scheme.onSurfaceVariant, 0.35))
      .accessibilityText(label)
      .onClick(() => { if (enabledOf()) action(); })
  }

  /// 快退/快进:秒数标在图标下方(与 Android 一致的信息密度)。
  @Builder
  skipBtn(forward: boolean) {
    Column({ space: 1 }) {
      Image(forward ? $r('sys.media.ohos_ic_public_play_next') : $r('sys.media.ohos_ic_public_play_last'))
        .width(19).height(19)
        .fillColor(this.scheme.onSurfaceVariant)
        // 标签带秒数,与 Android `SkipButton` 同一句文案;下方那枚秒数 Text 照旧由系统读。
        .accessibilityText(forward
          ? L.f('a11y_skip_fwd', this.settings.skipForwardSec)
          : L.f('a11y_skip_back', this.settings.skipBackSec))
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
    // 数字走 `formatDecimal` 而不是模板串 —— 法/西语区小数该用逗号,与 Android 同口径(见 H160)
    Row({ space: 2 }) {
      Text(`${formatDecimal(this.player.speed)}×`)
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
        MenuItem({ content: `${formatDecimal(s)}×` })
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
        .accessibilityText(L.s('sleep'))
      if (this.player.sleepTimed) {
        // 倒计时那一格是本页唯一每秒变的量,交给它自己按秒轮询 —— 
        // 数值在非观察的 clock 里,挂在本页会带着整棵播放页每秒重建(H64)
        SleepCountdownText({
          color: this.sleepTint(),
          fontSize: TypeScale.caption * this.fontScale,
          running: true,
          clock: this.player.clock,
        })
      } else {
        Text(this.player.sleepEndOfEpisode ? L.s('sleep_current') : L.s('sleep'))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.sleepTint())
      }
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.12))
    .borderRadius(20)
    .alignItems(VerticalAlign.Center)
    .bindMenu(this.sleepMenu())
  }

  private sleepActive(): boolean {
    return this.player.sleepTimed || this.player.sleepEndOfEpisode;
  }

  private sleepTint(): string {
    return this.sleepActive() ? this.scheme.primary : this.scheme.onSurfaceVariant;
  }

  @Builder
  sleepMenu() {
    Menu() {
      ForEach(this.sleepMinutes, (m: number) => {
        MenuItem({ content: L.f('dur_m', m) })
          .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
          .onClick(() => this.player.setSleepTimer(m))
      }, (m: number) => `${m}`)
      MenuItem({ content: L.s('sleep_end_of_episode') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.player.setSleepEndOfEpisode())
      MenuItem({ content: L.s('sleep_off') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.player.cancelSleep())
    }
    .backgroundColor(this.scheme.surface)
    .radius(12)
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
  /**
   * nudge:抵掉该字形墨迹相对字形盒的内缩量(见上方注释)。只对需要的一侧生效。
   *
   * **symbol / color 必须是闭包,不能是值参数**:`@Builder` 的值参数只求值一次,
   * 状态变化不会重新求值(踩过两次,见 H29)。此前收藏心形与队列图标就是把
   * `isFav() ? Sym.favorite : Sym.favoriteOff` 当值传进来 —— 点一下 store 确实变了、
   * 页面也重渲了,但图标被冻结在初始值,颜色永远不动,表现就是平台复核说的
   * 「收藏按钮点击无响应」。闭包必须一路传到渲染那一层才有效。
   *
   * 命中区宽度取 21 + 14 = 35(图标宽 + Row 的 space),即向两侧各外扩 7 —— **刚好填满
   * 半个间距、不与相邻图标重叠**。先前用 43 宽,相邻两个的命中区互相压 8vp,
   * 重叠处由后一个兄弟节点吃掉点击,小目标更难点中。
   *
   * `label` 是**值参数**(只求值一次,见上面 symbol/color 那条),所以只给**静态**标签用它 ——
   * 会随状态变的标签(收藏心、播放/暂停)一律留在各自的渲染处直接写,不进这个 builder。
   */
  @Builder
  iconAction(symbolOf: () => Resource, colorOf: () => ResourceColor, label: string,
             nudgeL: number, nudgeR: number, action: () => void) {
    Glyph({ symbol: symbolOf(), dim: 21, color: colorOf() })
      .margin({ left: nudgeL, right: nudgeR })
      .responseRegion({ x: -7, y: -11, width: 35, height: 43 })
      .accessibilityText(label)
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
    // 竖排三点,用与 Android 同一枚 Material 矢量(`Icons.Rounded.MoreVert`)。
    // 原先用 `sys.media.ohos_ic_public_more` —— 那是**横排**三点(鸿蒙平台惯例),
    // 两端摆在一起就是两种形状。同 tab 图标那次的判断:图标形状属于品牌一致性,取一致。
    GlyphImage({ icon: $r('app.media.ic_more_vert'), dim: 21, color: this.scheme.onSurfaceVariant })
      .margin({ left: -2.5 })
      .responseRegion({ x: -11, y: -11, width: 43, height: 43 })
      .accessibilityText(L.s('more'))
      .bindMenu(this.moreMenu())
      .bindSheet($$this.showSeals, this.sealSheet(), { height: 330 })
  }

  @Builder
  moreMenu() {
    Menu() {
      MenuItem({ content: L.s('clip_save') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => { this.saveMoment(); })
      MenuItem({ content: L.s('clip_moment') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => { this.shareMoment(); })
      // 批注排在盖章之前:与 Android `MoreMenu` 同序(保存此刻 / 分享此刻 / 写批注 / 盖章)。
      MenuItem({ content: L.s('note_add') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => {
          // 就在这一行取位置:下面两句都要跨一个异步渲染才落地,晚取就不是"这一秒"了
          const e = this.player.current;
          if (e === null) return;
          this.notePosMs = this.player.positionMs;
          this.noteEpisode = e;
          this.noteDraft = '';
          this.showNote = true;
        })
      MenuItem({ content: this.currentSeal().length > 0 ? L.s('stamp_edit') : L.s('stamp_add') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => { this.showSeals = true; })
    }
    // **面板底色必须显式给**:ArkUI 的菜单默认是浅色面板、不跟随 App 主题,
    // 而我们把文字设成了 onSurface(深色主题下近白)—— 白字压在白panel上直接看不见。
    // Android 的 DropdownMenu 是跟随主题的,所以这里也给成深色面板 + 亮字。
    .backgroundColor(this.scheme.surface)
    .radius(12)
  }

  /**
   * 溢出菜单项的字体。
   *
   * ArkUI 的 `MenuItem` 默认字号偏大、字重偏粗,三项摆在一起明显比 Android 那个菜单笨重。
   * Material 的 `DropdownMenuItem` 取 **labelLarge(14) 常规体**,这里对齐它。
   * (字体**家族**仍是各自系统字体 —— 不打包字体的话改不了,那是平台差异。)
   */
  private menuFont(): Font {
    return { size: TypeScale.labelLarge * this.fontScale, weight: FontWeight.Normal };
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

  /**
   * 写一条批注:标题带**按下的那一刻**的时间,正文一句话。与 Android `NoteDialog` 同内容,
   * 只是形态从居中对话框换成半模态(本端已有 `sealSheet` 同形,不必为它新造一个弹层组件)。
   *
   * 空文字**直接关掉、不落一条**(store 返回空串)而不是弹「请输入内容」——
   * 用户点了保存又什么也没写,最自然的意图是"这条不要";
   * 而列表里出现一条空白批注,以后无从分辨它是不是误触(且删除确认框会显示成空)。
   */
  @Builder
  noteSheet() {
    Column({ space: 12 }) {
      Text(L.s('note_title'))
        .fontSize(TypeScale.titleMedium * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .margin({ top: 16 })
      Text(formatTime(this.notePosMs))
        .fontSize(TypeScale.titleMedium * this.fontScale)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.primary)
      TextArea({ placeholder: L.s('note_hint'), text: this.noteDraft })
        .placeholderColor(this.scheme.onSurfaceVariant)
        .fontColor(this.scheme.onBackground)
        .fontSize(TypeScale.body * this.fontScale)
        .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.08))
        .borderRadius(10)
        .height(96)
        .onChange((v: string) => { this.noteDraft = v; })
      Row({ space: 12 }) {
        Text(L.s('action_cancel'))
          .fontSize(TypeScale.labelLarge * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .onClick(() => { this.showNote = false; })
        Blank()
        Text(L.s('action_save'))
          .fontSize(TypeScale.labelLarge * this.fontScale)
          .fontColor(this.scheme.primary)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .onClick(() => { this.saveNote(); })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(this.scheme.surface)
  }

  private saveNote(): void {
    // 用**按下那一刻**冻住的集,而不是这里重新取 `player.current` —— 后者在弹层开着的时候
    // 可能已经接下一集了,那时批注会挂错集(见 noteEpisode 的注释)。
    const e = this.noteEpisode;
    if (e === null) {
      this.showNote = false;
      return;
    }
    // 夹时长、去空白、生成 id 都在 store 里(硬规矩 10);这里只管收摊。
    // **不给成功提示**:与 Android 同一判断 —— 结果就摆在音阁第 6 段的第一行,
    // 而播放页上那条 hint 是给"看不见结果"的动作(存图 / 分享)用的。
    this.app.notes.add(e, this.notePosMs, this.noteDraft, Date.now());
    this.showNote = false;
  }

  /**
   * 把「此刻」的时刻写进离屏卡片,并等它真正重渲完再截图。
   *
   * 卡片是常驻离屏的(不能用 `visibility.None`,那样截不到),而进度已不再驱动本页重渲,
   * 所以必须显式赋值 + 让出一帧 —— 状态改完到渲染出来隔一个 vsync,
   * 立刻截图会拿到**改之前**的那一帧。48ms 给足两帧余量;这条路径本来就是异步的
   * (写文件 + 拉起分享面板),用户感知不到。
   */
  private async armMomentCard(): Promise<void> {
    this.momentPosMs = this.player.positionMs;
    await new Promise<void>((resolve: () => void) => setTimeout(resolve, 48));
  }

  /// 剪藏 · 分享此刻:同样截图成 PNG,但交给系统分享面板而不是存相册。
  /// 对应 Android MoreMenu 的 onClip(那边走 ShareCards.share)。
  private async shareMoment(): Promise<void> {
    const e = this.player.current;
    if (e === null) return;
    const ui = this.getUIContext();
    const ctx = ui.getHostContext() as common.UIAbilityContext;
    await this.armMomentCard();
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
    await this.armMomentCard();
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
    // 心形衬一枚 surfaceVariant 圆底(36 见方、心 20),与 Android `FavoriteButton` 同一形态。
    // 原先是**裸心**:顶栏里倍速与睡眠都是有底色的药丸,收藏却光秃秃一个图标,轻重不一。
    Stack() {
      Circle()
        .width(36).height(36)
        .fill(this.scheme.surfaceVariant)
      Glyph({
        symbol: this.isFav() ? Sym.favorite : Sym.favoriteOff, dim: 20,
        color: this.isFav() ? this.scheme.primary : this.scheme.onSurfaceVariant
      })
    }
    .width(36).height(36)
    .accessibilityText(L.s(this.isFav() ? 'a11y_unfavorite' : 'a11y_favorite'))
    .onClick(() => {
      const e = this.player.current;
      if (e !== null) this.favorites.toggle(e);
    })
  }

  private isFav(): boolean {
    const e = this.player.current;
    return e === null ? false : this.favorites.isFavorite(e.id);
  }
}
