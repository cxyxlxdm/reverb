import { Scheme, TypeScale, withAlpha, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { Podcast, Episode } from '../model/Models';
import { Artwork, SquareArtwork, Glyph, Sym } from './Widgets';
import { formatPubDate } from '../util/DateParse';
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

/// 单集时长的安静展示("42 分钟" / "1 小时 5 分");0 返回空串。
export function formatDurationSec(sec: number): string {
  if (sec <= 0) return '';
  const m = Math.floor(sec / 60);
  if (m >= 60) return L.f('dur_hm', Math.floor(m / 60), m % 60);
  return L.f('dur_m', m);
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
  onTap: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      Artwork({ scheme: this.scheme, url: this.podcast.artworkUrl, dim: 60, corner: 10 })
      Column({ space: 4 }) {
        Text(this.podcast.title)
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.scheme.onBackground)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.podcast.author.length > 0) {
          Text(this.podcast.author)
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.podcast.isPaid) {
          Text(L.s('paid'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.secondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
    .onClick(() => this.onTap())
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
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (this.podcast.author.length > 0) {
        Text(this.podcast.author)
          .fontSize(TypeScale.caption * this.fontScale)
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

  private meta(): string {
    const parts: string[] = [];
    if (this.showPodcastTitle && this.episode.podcastTitle.length > 0) parts.push(this.episode.podcastTitle);
    const d = formatPubDate(this.episode.pubDate);
    if (d.length > 0) parts.push(d);
    const dur = formatDurationSec(this.episode.durationSec);
    if (dur.length > 0) parts.push(dur);
    return parts.join('  ·  ');
  }

  private titleColor(): string {
    if (this.isCurrent) return this.scheme.primary;
    return this.played ? this.scheme.onSurfaceVariant : this.scheme.onBackground;
  }

  build() {
    Row({ space: 12 }) {
      Artwork({ scheme: this.scheme, url: this.episode.artworkUrl, dim: 52, corner: 10 })
      Column({ space: 5 }) {
        // 标题 + 已播对勾(与 Android 一致:对勾紧跟标题,16 号,onSurfaceVariant 色)
        Row({ space: 6 }) {
          Text(this.episode.title)
            .fontSize(TypeScale.titleSmall * this.fontScale)
            .fontWeight(FontWeight.Medium)
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
        if (this.meta().length > 0) {
          Text(this.meta())
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

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

      // 圆形播放/暂停键
      Stack() {
        Circle()
          .width(34).height(34)
          .fill(this.isCurrent ? withAlpha(this.scheme.primary, 0.18) : withAlpha(this.scheme.onSurfaceVariant, 0.12))
        Image(this.isCurrent && this.isPlaying
          ? $r('sys.media.ohos_ic_public_pause')
          : $r('sys.media.ohos_ic_public_play'))
          .width(18).height(18)
          .fillColor(this.isCurrent ? this.scheme.primary : this.scheme.onSurfaceVariant)
      }
      .width(34).height(34)
      .onClick(() => this.onPlay())
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
    .onClick(() => this.onPlay())
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
            .fontSize(TypeScale.label * this.fontScale)
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
