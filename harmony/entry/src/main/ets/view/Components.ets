import { Scheme, TypeScale, Tracking, LineHeight, withAlpha, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { Podcast, Episode } from '../model/Models';
import { Artwork, SquareArtwork, Glyph, Sym } from './Widgets';
import { formatPubDate } from '../util/DateParse';
import { TapGuard } from '../util/TapGuard';
import { DownloadState } from '../playback/DownloadManager';

/// 列表/网格通用条目。对应 Android `ui/components/Components.kt`。

/// 时长文本:mm:ss / h:mm:ss。
export function formatTime(ms: number): string {
  if (ms <= 0) return '00:00';
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const p2 = (v: number): string => v < 10 ? `0${v}` : `${v}`;
  return h > 0 ? `${h}:${p2(m)}:${p2(s)}` : `${p2(m)}:${p2(s)}`;
}

/**
 * 单集时长的展示:**时间码**(`39:16` / `1:18:49`),0 返回空串。
 *
 * 原先返回的是「15 分钟」「1 小时 18 分」—— 与下面的 formatListenDuration 几乎同一份实现,
 * 是移植时的偷懒。两端就此分歧:Android 的 formatDurationSec 一直是 `formatTime(sec*1000)`。
 *
 * 按 Android 的分工来:**单集长度用时间码,累计收听用文字**(见 formatListenDuration)。
 * 这个区分是有道理的 —— 单集长度是"这条音频多长",时间码是媒体界的通用读法且更窄
 * (列表副信息那一行本来就挤);累计时长是"你听了多久",用文字更好读。
 */
export function formatDurationSec(sec: number): string {
  if (sec <= 0) return '';
  return formatTime(sec * 1000);
}

/// 人类可读的累计时长("X 小时 Y 分" / "Y 分钟" / "小于 1 分钟")。
export function formatListenDuration(sec: number): string {
  if (sec < 60) return L.s('dur_lt1m');
  const m = Math.floor(sec / 60);
  if (m >= 60) return L.f('dur_hm', Math.floor(m / 60), m % 60);
  return L.f('dur_m', m);
}

/// 频道列表行:封面 + 标题 + 作者 + 付费标记。
@Component
export struct PodcastListItem {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop podcast: Podcast;
  /// 搜索预检专用；默认空串,分类榜与订阅列表完全不受影响。
  @Prop status: string = '';
  @Prop statusError: boolean = false;
  @Prop tapEnabled: boolean = true;
  onTap: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      Artwork({ scheme: this.scheme, url: this.podcast.artworkUrl, dim: 60, corner: 10 })
      Column({ space: 4 }) {
        Text(this.podcast.title)
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .letterSpacing(Tracking.titleMedium)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.scheme.onBackground)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.podcast.author.length > 0) {
          Text(this.podcast.author)
            .fontSize(TypeScale.label * this.fontScale)
            .letterSpacing(Tracking.label)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.podcast.isPaid) {
          Text(L.s('paid'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.secondary)
        }
        if (this.status.length > 0) {
          Text(this.status)
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.statusError ? this.scheme.error : this.scheme.primary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .opacity(this.tapEnabled ? 1 : 0.58)
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
    .onClick(() => {
      if (this.tapEnabled) this.onTap();
    })
  }
}

/// 频道宫格卡:方封面 + 标题 + 作者(与 macOS PodcastCard 对齐)。
@Component
export struct PodcastGridItem {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop podcast: Podcast;
  onTap: () => void = () => {};

  build() {
    Column({ space: 8 }) {
      SquareArtwork({ scheme: this.scheme, url: this.podcast.artworkUrl, corner: Metrics.cardCorner })
      Text(this.podcast.title)
        .fontSize(TypeScale.titleSmall * this.fontScale)
        .letterSpacing(Tracking.titleSmall)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (this.podcast.author.length > 0) {
        Text(this.podcast.author)
          .fontSize(TypeScale.caption * this.fontScale)
          .letterSpacing(Tracking.caption)
          .fontColor(this.scheme.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .onClick(() => this.onTap())
  }
}

/// 单集行:封面 + 标题 + 元信息(频道名 · 日期 · 时长)+ 圆形播放键。
/// 当前播放态用强调色标注;已播完标题变暗。
@Component
export struct EpisodeListItem {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop episode: Episode;
  @Prop isCurrent: boolean = false;
  @Prop isPlaying: boolean = false;
  @Prop played: boolean = false;
  @Prop showPodcastTitle: boolean = false;
  /// 下载态:-1 不显示下载入口 / 0 排队 / 1 进行中 / 2 已完成 / 3 失败
  @Prop downloadState: number = -1;
  onPlay: () => void = () => {};
  onDownload: () => void = () => {};
  onDeleteDownload: () => void = () => {};
  /// 行内收藏心形。与 Android 一致:**只在「音阁 · 收藏」这类需要就地取消收藏的列表显示**
  /// (Android 是 onToggleFavorite != null 才画,ArkTS 没有可空回调的惯例,用显式开关)。
  @Prop showFavorite: boolean = false;
  @Prop isFavorite: boolean = false;
  onToggleFavorite: () => void = () => {};
  /// 「标记已播完」只在发现页的搜索结果里出现(与 Android 一致)。
  /// 长按菜单本身**所有单集列表都有**,故不设开关 —— 鸿蒙端此前压根没有长按手势,
  /// 外部反馈的「长按单集不能加入队列」即此。调用方必须接好 onPlayNext / onEnqueue。
  @Prop showPlayedToggle: boolean = false;
  onPlayNext: () => void = () => {};
  onEnqueue: () => void = () => {};
  onTogglePlayed: () => void = () => {};

  /// 长按弹出的菜单。项与 Android `EpisodeListItem` 的 DropdownMenu 一一对应。
  @Builder
  contextMenu() {
    Menu() {
      MenuItem({ content: L.s('queue_play_next') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.onPlayNext())
      MenuItem({ content: L.s('queue_add') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.onEnqueue())
      if (this.showPlayedToggle) {
        MenuItem({ content: this.played ? L.s('mark_unplayed') : L.s('mark_played') })
          .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
          .onClick(() => this.onTogglePlayed())
      }
    }
    // 面板底色与字号都显式给,理由同 PlayerPage.menuFont —— ArkUI 菜单默认浅色面板、
    // 字号偏大,不跟随 App 主题;全应用的菜单要长一个样。
    .backgroundColor(this.scheme.surface)
    .radius(12)
  }

  /// 菜单项字体:labelLarge(14) 常规体,对齐 Material 的 DropdownMenuItem。
  private menuFont(): Font {
    return { size: TypeScale.labelLarge * this.fontScale, weight: FontWeight.Normal };
  }

  /**
   * 日期 · 时长。**不含节目名** —— 节目名单独一栏靠左、用强调色(见 build)。
   *
   * 原先是「节目名 · 日期 · 时长」串成一条全灰文字,并排看 Android 与鸿蒙的截图时
   * 这条是观感差距最大的一处:三段同色同号挤在左边,读起来是一坨灰糊,还常被截断成
   * 「1 小时 …」。Android 是左右分栏(节目名强调色居左 / 日期时长灰色右对齐),
   * 右缘因时长宽度固定而天然整齐。
   */
  private meta(): string {
    const parts: string[] = [];
    const d = formatPubDate(this.episode.pubDate);
    if (d.length > 0) parts.push(d);
    const dur = formatDurationSec(this.episode.durationSec);
    if (dur.length > 0) parts.push(dur);
    return parts.join('  ·  ');
  }

  /// 靠左那栏的节目名。与 Android 同一口径:超过 10 字取前 9 字加省略号 ——
  /// 长度不设限会把右侧的日期时长挤出去。
  private shortPodcastTitle(): string {
    const name = this.episode.podcastTitle;
    return name.length > 10 ? `${name.substring(0, 9)}…` : name;
  }

  private showsPodcastTitle(): boolean {
    return this.showPodcastTitle && this.episode.podcastTitle.length > 0;
  }

  private titleColor(): string {
    if (this.isCurrent) return this.scheme.primary;
    return this.played ? this.scheme.onSurfaceVariant : this.scheme.onBackground;
  }

  build() {
    Row({ space: 12 }) {
      // 封面 + 半透明黑蒙层 + 白色播放/暂停图标。
      //
      // **播放入口就叠在封面上**,行右侧不再另放一个圆钮(与 Android 一致)。
      // 原先右侧那个 34 见方的灰圆圈让每行多一个抢眼的重元素,与封面争视线,
      // 而整行本来就可点播放 —— 它并不提供额外能力,只是把行撑宽、把标题挤成两行。
      Stack() {
        Artwork({ scheme: this.scheme, url: this.episode.artworkUrl, dim: 52, corner: 10 })
        Row()
          .width(52).height(52)
          .borderRadius(10)
          .backgroundColor(withAlpha('#000000', this.isCurrent ? 0.42 : 0.28))
        // 裸三角 / 双竖条,不是 `sys.media.ohos_ic_public_play` 那枚**带白色圆底**的:
        // 圆底那枚叠在封面上显得笨重,与 Android 的裸 PlayArrow 观感差一截。
        // 用 Symbol 字体的实心变体(名字已在真机上验过能渲染 —— Symbol 名写错不报错、
        // 直接空白,所以换这类资源必须真机看一眼,见 Widgets 注释)。
        Glyph({
          symbol: this.isCurrent && this.isPlaying ? Sym.pauseFill : Sym.playFill,
          dim: 24,
          color: Color.White
        })
      }
      .width(52).height(52)

      Column({ space: 3 }) {
        // 标题 + 已播对勾(与 Android 一致:对勾紧跟标题,16 号,onSurfaceVariant 色)
        Row({ space: 6 }) {
          Text(this.episode.title)
            // 常规字重、正文号(对齐 Android 的 bodyLarge 常规体)。原先是 Medium,
            // 与灰糊的副信息叠在一起显得又粗又胖,一屏比 Android 少放三四行。
            .fontSize(TypeScale.body * this.fontScale)
            // 字距与行高:ArkUI 默认字距 0、行距紧凑,而 Compose 用 Material 字号表时
            // 两者都自带 —— 不补就是"字挨着字、行贴着行",密排列表尤其显挤(见 Tracking 注释)
            .letterSpacing(Tracking.body)
            .lineHeight(TypeScale.body * this.fontScale * LineHeight.body)
            .fontColor(this.titleColor())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 不用 layoutWeight(1):那会让标题撑满、把对勾推到行最右。
            // Android 是 weight(1f, fill = false) —— 文字按内容宽、必要时收缩,对勾紧跟其后。
            .flexShrink(1)
          if (this.played) {
            Glyph({ symbol: Sym.played, dim: 16, color: this.scheme.onSurfaceVariant })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        // 副信息:节目名(强调色)靠左 + 日期·时长(灰)右对齐。
        // 不显示节目名的场景(频道详情页)退化成日期·时长单独居左,与 Android 同。
        if (this.showsPodcastTitle()) {
          Row() {
            Text(this.shortPodcastTitle())
              .fontSize(TypeScale.caption * this.fontScale)
              .letterSpacing(Tracking.caption)
              .fontColor(this.scheme.primary)
              .maxLines(1)
            Blank()
            if (this.meta().length > 0) {
              Text(this.meta())
                .fontSize(TypeScale.caption * this.fontScale)
                .letterSpacing(Tracking.caption)
                .fontColor(this.scheme.onSurfaceVariant)
                .maxLines(1)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else if (this.meta().length > 0) {
          Text(this.meta())
            .fontSize(TypeScale.caption * this.fontScale)
            .letterSpacing(Tracking.caption)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 行内收藏心形(与 Android 同位置:元信息之后、下载控件之前)
      if (this.showFavorite) {
        Glyph({
          symbol: this.isFavorite ? Sym.favorite : Sym.favoriteOff,
          dim: 20,
          color: this.isFavorite ? this.scheme.primary : this.scheme.onSurfaceVariant
        })
          // 图标只有 20,命中区外扩到 36 见方,免得点不中(行本身的 onClick 是播放,
          // 命中区重叠会被行吃掉,所以这里必须显式外扩)
          .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
          .onClick(() => this.onToggleFavorite())
      }

      // 下载三态,与 Android `DownloadControl` 一一对应:
      // 已下载 = DownloadDone(强调色,点击删除)/ 进行中·排队 = 进度圈 / 未下载 = Download
      // 原先用「已存」「下载」文字代替 —— sys.media.* 没有这两个图标,换 Symbol 后有正主。
      if (this.downloadState === DownloadState.DOWNLOADING || this.downloadState === DownloadState.QUEUED) {
        LoadingProgress().width(20).height(20).color(this.scheme.primary)
      } else if (this.downloadState === DownloadState.COMPLETED) {
        Glyph({ symbol: Sym.downloaded, dim: 20, color: this.scheme.primary })
          .onClick(() => this.onDeleteDownload())
      } else if (this.downloadState >= 0) {
        Glyph({ symbol: Sym.download, dim: 20, color: this.scheme.onSurfaceVariant })
          .onClick(() => this.onDownload())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 12, bottom: 12 })
    .onClick(() => this.onPlay())
    /**
     * 长按菜单。两个参数都是踩出来的:
     *
     * - `enableArrow` 必须是 **false**。带箭头时 ArkUI 会把菜单**锚到组件**上
     *   (placement 未指定就退化成组件正上方),而这一行是整屏宽的 —— 结果无论按在哪儿,
     *   菜单都从屏幕横向正中弹出,跟手指没关系。关掉箭头才走 `ResponseType.LongPress`
     *   的默认定位:**在按下点弹出**,贴边时自行翻转。Android 那边是同一套手感
     *   (零尺寸锚点放在按下点,见 `Components.kt` 的 pressPoint)。
     * - `aboutToAppear` / `aboutToDisappear` 升降「误触盾」,吃掉「点外部关菜单」
     *   那一下的穿透点击(ArkUI 会把它同时派发给下面的组件,见 TapGuard)。
     */
    .bindContextMenu(this.contextMenu(), ResponseType.LongPress, {
      enableArrow: false,
      aboutToAppear: () => { TapGuard.raise(); },
      aboutToDisappear: () => { TapGuard.lowerSoon(); }
    })
  }
}

/// 横向分类 chips(与内容分页双向联动)。
@Component
export struct ChipsRow {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop labels: string[];
  @Prop selected: number;
  onSelect: (i: number) => void = () => {};

  private scroller: Scroller = new Scroller();
  /// 上一次已滚动到的选中项,避免每次重渲都重复下发滚动指令
  private scrolledTo: number = -1;

  /**
   * 选中项变化时把它滚进可视区。
   * 发现页有 19 个分类,横滑几页之后选中的 chip 往往已经在屏幕外 ——
   * 高亮变了却看不见,观感上就是"分类没跟着动"。
   */
  private revealSelected(): void {
    if (this.selected === this.scrolledTo) return;
    this.scrolledTo = this.selected;
    // 估算:每个 chip 约 (字数×字号 + 左右各 14 内边距 + 8 间距),够用即可 ——
    // 目的只是把选中项带进视野,不追求精确居中。
    let x = 0;
    for (let i = 0; i < this.selected && i < this.labels.length; i++) {
      x += this.labels[i].length * TypeScale.label * this.fontScale * 0.6 + 36;
    }
    this.scroller.scrollTo({ xOffset: Math.max(0, x - 80), yOffset: 0, animation: { duration: 260, curve: Curve.EaseOut } });
  }

  build() {
    Scroll(this.scroller) {
      Row({ space: 8 }) {
        ForEach(this.labels, (label: string, idx: number) => {
          Text(label)
            // chip 文字取 labelLarge(14),与 Android 的 Material FilterChip 同档
            .fontSize(TypeScale.labelLarge * this.fontScale)
            .fontColor(this.selected === idx ? this.scheme.onPrimary : this.scheme.onSurfaceVariant)
            .backgroundColor(this.selected === idx ? this.scheme.primary : withAlpha(this.scheme.onSurfaceVariant, 0.10))
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(16)
            // 高亮做淡入淡出,不要硬切。原先 backgroundColor/fontColor 是直接按三元赋值,
            // 状态一变颜色瞬间跳过去,配上页面的滑动动画就显得生硬。
            .animation({ duration: 200, curve: Curve.EaseOut })
            .onClick(() => this.onSelect(idx))
        }, (label: string, idx: number) => `${idx}-${label}`)
      }
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
      .onAreaChange(() => { this.revealSelected(); })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(44)
    .align(Alignment.Start)
  }
}
