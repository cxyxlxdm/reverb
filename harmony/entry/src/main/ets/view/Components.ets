import { Scheme, TypeScale, Tracking, LineHeight, withAlpha, Metrics } from '../theme/Theme';
import { curves } from '@kit.ArkUI';
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
  /// 行内「加入播放列表」。只在节目详情页开:浏览选集为主的页面,一步入队比长按菜单顺手
  /// —— 长按的触发时长是系统定值(约 500ms,`bindContextMenu` 不可配),改不了;
  /// 慢的**观感**靠下面的按压态底色缓解,而慢本身靠这个按钮绕开。
  @Prop showQueueAdd: boolean = false;
  /// 「标记已播完 / 未播完」这一项出现在**能承担撤销的地方**:发现页的搜索结果
  /// (与 Android 一致)和音阁 · 历史。后者是必须的 —— 发现页「继续收听」卡上那个
  /// 「标记已播完」改的就是这张列表的 `played`,不在历史页给回程,那一步就撤不回来。
  /// 长按菜单本身**所有单集列表都有**,故不设开关 —— 鸿蒙端此前压根没有长按手势,
  /// 外部反馈的「长按单集不能加入队列」即此。调用方必须接好 onPlayNext / onEnqueue。
  @Prop showPlayedToggle: boolean = false;
  onPlayNext: () => void = () => {};
  onEnqueue: () => void = () => {};
  onTogglePlayed: () => void = () => {};

  /**
   * 行按压态:onTouch 手动驱动,不用 stateStyles —— stateStyles 的 pressed 对
   * 子图标上的触摸同样会亮(真机反馈:点行内「入队」键,整行高亮,看着像点了播放)。
   * 行体亮/灭由这里的事件流控制,右侧各图标以 onTouch stopPropagation 截断冒泡;
   * 高亮只属于「按到行本身」:点行播放、长按菜单的等待期。
   */
  @State pressed: boolean = false;

  /// 长按弹出的菜单。项与 Android `EpisodeListItem` 的 DropdownMenu 一一对应。
  @Builder
  contextMenu() {
    Menu() {
      MenuItem({ content: L.s('queue_play_next') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.onPlayNext())
      MenuItem({ content: L.s('queue_add') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => {
          this.onEnqueue();
          this.showToast(L.s('queue_added'));
        })
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

  /// 入队确认的 toast。收在行组件而不是各页的 onEnqueue 回调:所有列表
  /// (行内键 + 长按菜单)统一有反馈,调用方不必各自补。写法同 PodcastDetailPage.showToast。
  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
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
          // 截断触摸冒泡:行的按压高亮只属于「按到行本身」,点图标不该点亮整行
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onClick(() => this.onToggleFavorite())
      }

      // 行内「加入播放列表」(showQueueAdd 打开时):与收藏心形同位置规则、同命中区外扩。
      // 图标用列表+加号(add_songlist)而不是队列符号 —— 它的动作是「入队」,
      // 与「打开队列页」的队列图标同形会误导(真机反馈)。
      if (this.showQueueAdd) {
        Glyph({ symbol: Sym.queueAdd, dim: 20, color: this.scheme.onSurfaceVariant })
          .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onClick(() => {
            this.onEnqueue();
            // 入队结果在别页,界面无任何变化,不提示等于没按上
            this.showToast(L.s('queue_added'));
          })
      }

      // 下载三态,与 Android `DownloadControl` 一一对应:
      // 已下载 = DownloadDone(强调色,点击删除)/ 进行中·排队 = 进度圈 / 未下载 = Download
      // 原先用「已存」「下载」文字代替 —— sys.media.* 没有这两个图标,换 Symbol 后有正主。
      if (this.downloadState === DownloadState.DOWNLOADING || this.downloadState === DownloadState.QUEUED) {
        LoadingProgress().width(20).height(20).color(this.scheme.primary)
      } else if (this.downloadState === DownloadState.COMPLETED) {
        Glyph({ symbol: Sym.downloaded, dim: 20, color: this.scheme.primary })
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onClick(() => this.onDeleteDownload())
      } else if (this.downloadState >= 0) {
        Glyph({ symbol: Sym.download, dim: 20, color: this.scheme.onSurfaceVariant })
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onClick(() => this.onDownload())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 12, bottom: 12 })
    .onClick(() => this.onPlay())
    /**
     * 按压态底色。长按菜单的触发时长是系统定值,等待期原本零反馈 —— 手指按住时
     * 「不知道按没按上」,观感就是「长按反馈慢」(Android 同样时长但有 ripple 垫着)。
     *
     * 不用 stateStyles:它的 pressed 对子图标上的触摸同样会亮(点「入队」键整行高亮,
     * 看着像点了播放)。改由 onTouch 驱动 @State,配合右侧图标的 stopPropagation,
     * 高亮只属于「按到行本身」。Move 也熄灭 —— 列表滚动都从 Down 开始,
     * 不灭会让被划过的行拖一条亮块;长按期间手指不动,不受影响。
     */
    .backgroundColor(this.pressed ? withAlpha(this.scheme.onSurfaceVariant, 0.10) : Color.Transparent)
    .onTouch((event: TouchEvent) => {
      this.pressed = event.type === TouchType.Down;
    })
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
      aboutToAppear: () => { TapGuard.raise(); this.pressed = false; },
      aboutToDisappear: () => { TapGuard.lowerSoon(); }
    })
  }
}

/// 玻璃分段条(ChipsRow)的高度。页面据此在滚动容器顶部留出同等余量
/// (List 用 contentStartOffset、宫格用占位 GridItem):首项静止时停在条下方,
/// 上滚时内容从条下经过 —— 悬浮玻璃后面得有东西经过,模糊才看得出来。
export const CHIPS_STRIP_H = 44;

/**
 * 页面在滚动容器顶部**该留的余量**。比条本身高 8vp —— 占位若只给 `CHIPS_STRIP_H`,
 * 静止时首项的顶边与条的下描边**重合**(真机实测两者都在 y=681),首项只剩自己的
 * 4vp 内边距撑着,读起来就是"标题贴着分类条"。
 *
 * `+ 8` 不是拍的:Android 侧同一个量写成 `GLASS_CHIPS_TOP_PAD = 52.dp`,注释是
 * 「条 44dp + 与内容的 8dp 间距」(见 `Components.kt`)。**两端同值同义**,
 * 小标题那 4vp 也各自留着(Android 在 `LibraryScreen` 里同样另加 4dp)。踩坑记录见 H102。
 */
export const CHIPS_RESERVE_H = CHIPS_STRIP_H + 8;

/**
 * 顶部分类条与 Swiper 的手势联动总线:页面在 onGestureSwipe 每帧灌入进度,
 * 胶囊按帧插值绘制(1:1 跟手,与底部栏同手感);松手时行/胶囊各自收尾。
 * 全程不走状态观察 —— 每帧只经回调重建胶囊这一个组件(H64 最小重建面)。
 */
export class ChipsSwipeSync {
  /** 插值两端与进度:胶囊位置 = lerp(chipX[from], chipX[to], progress) */
  from: number = 0;
  to: number = -1;
  progress: number = 0;
  /** 手势帧进行中;end() 先派发结束回调、后清位,收尾方还能读到最后一帧插值 */
  active: boolean = false;
  private frameSink: ((f: number, t: number, p: number) => void) | null = null;
  private endSinks: ((target: number) => void)[] = [];

  onFrame(sink: (f: number, t: number, p: number) => void): void {
    this.frameSink = sink;
  }

  /// 注册顺序即语义:行先注册(先弹簧,钉位依赖 active 仍为 true),胶囊后注册。
  addEndSink(sink: (target: number) => void): void {
    this.endSinks.push(sink);
  }

  report(from: number, to: number, p: number): void {
    this.from = from;
    this.to = to;
    this.progress = p;
    this.active = true;
    this.frameSink?.(from, to, p);
  }

  /// 手势收束(提交或回落)。target = 结束后胶囊应停的选中项。
  end(target: number): void {
    this.endSinks.forEach((fn: (target: number) => void) => fn(target));
    this.active = false;
    this.to = -1;
  }
}

/// 横向分类 chips(与内容分页双向联动)。本体是玻璃条:实时模糊 + 半透明染色,
/// 与底部 GlassTabBar 同一套参数;调用方负责把它悬浮在滚动内容上方。
@Component
export struct ChipsRow {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop labels: string[];
  /// @Watch 的回调参数是**属性名字符串**,不是新值 —— 直接把 springTo 挂上来会收到
  /// "selected",chipX["selected"] 取不到、提前 return,点击切页时胶囊就永远不动
  /// (踩过:拖动走 endSink、量测走 idx,传的都是真数字,唯独点击这条路径坏)。
  @Prop @Watch('onSelectedChange') selected: number;
  /// 与页面的 Swiper 手势联动总线(页面持有并灌帧);不传则无联动,纯弹簧
  sync: ChipsSwipeSync = new ChipsSwipeSync();
  onSelect: (i: number) => void = () => {};

  private scroller: Scroller = new Scroller();
  /// 上一次已滚动到的选中项,避免每次重渲都重复下发滚动指令
  private scrolledTo: number = -1;
  /// 各 chip 的实测位置/宽度(Scroll 内容坐标系,由各 chip 的 onAreaChange 回填),胶囊对位用
  private chipX: number[] = [];
  private chipW: number[] = [];
  /** 透明胶囊当前位置与宽度;首帧没量到选中 chip 之前先藏着 */
  @State capX: number = 0;
  @State capW: number = 0;

  aboutToAppear(): void {
    // 行先于胶囊(子组件)注册收尾回调:springTo 的钉位依赖 active 仍为 true
    this.sync.addEndSink((t: number) => { this.springTo(t); });
  }

  /**
   * 选中项变化时把它滚进可视区。
   * 发现页有 19 个分类,横滑几页之后选中的 chip 往往已经在屏幕外 ——
   * 高亮变了却看不见,观感上就是"分类没跟着动"。
   */
  private revealSelected(): void {
    if (this.selected === this.scrolledTo) return;
    this.scrolledTo = this.selected;
    // 优先用实测位置;首帧还没量到时退回估算(每 chip ≈ 字数×字号 + 左右 14 内边距 +
    // 8 间距) —— 目的只是把选中项带进视野,不追求精确居中。
    let x = this.chipX[this.selected] ?? -1;
    if (x < 0) {
      x = 0;
      for (let i = 0; i < this.selected && i < this.labels.length; i++) {
        x += this.labels[i].length * TypeScale.label * this.fontScale * 0.6 + 36;
      }
    }
    this.scroller.scrollTo({ xOffset: Math.max(0, x - 80), yOffset: 0, animation: { duration: 260, curve: Curve.EaseOut } });
  }

  /// @Watch 进来的桥:回调时机上 selected 已是新值,读它再进弹簧。
  /// reveal 也必须挂在这里 —— 内层 Row 的 onAreaChange 只在首次布局/面积变化
  /// 时触发,横滑换页只更新 selected、条身没有面积变化,onAreaChange 永远
  /// 不会再触发;只靠它兜底,选中 chip 滑到屏幕外后条身就不滚、高亮不可见
  /// (H93,与 Android 玻璃条换页不同步是同一症状)。reveal 自带 scrolledTo
  /// 幂等阀,重复触发无害。
  private onSelectedChange(): void {
    this.revealSelected();
    this.springTo(this.selected);
  }

  /// 弹簧滑到第 i 个 chip 下(弹簧参数与底部药丸不同,见 animateTo 处注释:
  /// 分类条chip 间距大、又有 Swiper 落位动画作参照,收尾要更从容)。
  /// chip 宽随字数可变,必须用实测值对位;首帧没量到就不动,量到后自然补上。
  ///
  /// 手势联动期间胶囊的绘制值是插值而不是 capX:先无动画把 capX 钉到实际绘制
  /// 位置再弹簧,否则弹簧从旧选中位起跳,视觉上先跳回再弹出去。
  private springTo(i: number): void {
    const tx = this.chipX[i] ?? -1;
    const tw = this.chipW[i] ?? -1;
    if (tx < 0 || tw <= 0) return;
    if (this.sync.active && this.sync.to >= 0) {
      const p = this.sync.progress;
      const fx = this.chipX[this.sync.from] ?? -1;
      const fw = this.chipW[this.sync.from] ?? -1;
      const gx = this.chipX[this.sync.to] ?? -1;
      const gw = this.chipW[this.sync.to] ?? -1;
      if (fx >= 0 && fw > 0 && gx >= 0 && gw > 0) {
        this.capX = fx + (gx - fx) * p;
        this.capW = fw + (gw - fw) * p;
      }
    }
    // 收尾弹簧必须比 Swiper 落位动画(~400ms)更从容:response 0.3 时胶囊
    // 150ms 左右就冲到终点,页面还在路上,观感是「瞬间切过去、很急迫」
    // (用户对照 Android 的 1:1 跟页平移给的反馈)。0.45/0.95 ≈ 450ms 滑行、
    // 几乎无回弹,与落位同时到位,读起来就是「跟着页面滑过去」。
    this.getUIContext().animateTo({ curve: curves.springMotion(0.45, 0.95) }, () => {
      this.capX = tx;
      this.capW = tw;
    });
  }

  build() {
    /**
     * 外层 Row 负责两侧各收进 12:玻璃胶囊必须「浮」起来(两侧有可见的缝 + 发丝描边)
     * 才有玻璃的形 —— 通栏贴边时条与页面背景融为一体,静止时玻璃等于隐形,
     * 看起来就是「没生效」;只有内容滚过条下时才糊得出来。
     * 不能直接给 width('100%') 的 Scroll 加横向 margin:百分比先按父内容宽算出 100%,
     * margin 再往外扩,右缘会溢出(与 searchBar 同款坑,见 DiscoverPage 注释)。
     */
    Row() {
      Scroll(this.scroller) {
        Stack({ alignContent: Alignment.Start }) {
          /**
           * 透明胶囊(与 GlassTabBar 同款语言):罩住选中 chip 的半透明衬底 + 发丝描边。
           * 独立成子组件:Swiper 手势期间每帧只重建这一颗胶囊,不牵动整条 ChipsRow。
           */
          ChipsCapsule({
            scheme: this.scheme,
            capX: this.capX,
            capW: this.capW,
            chipX: this.chipX,
            chipW: this.chipW,
            sync: this.sync
          })

          Row({ space: 8 }) {
            ForEach(this.labels, (label: string, idx: number) => {
              Text(label)
                // chip 文字取 labelLarge(14),与 Android 的 Material FilterChip 同档
                .fontSize(TypeScale.labelLarge * this.fontScale)
                // 选中态的底色交给胶囊,chip 自己只换文字色;未选中保持灰底
                .fontColor(this.selected === idx ? this.scheme.primary : this.scheme.onSurfaceVariant)
                .backgroundColor(this.selected === idx ? Color.Transparent : withAlpha(this.scheme.onSurfaceVariant, 0.10))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(16)
                // 高亮做淡入淡出,不要硬切。原先 backgroundColor/fontColor 是直接按三元赋值,
                // 状态一变颜色瞬间跳过去,配上页面的滑动动画就显得生硬。
                .animation({ duration: 200, curve: Curve.EaseOut })
                .onClick(() => this.onSelect(idx))
                .onAreaChange((_o: Area, n: Area) => {
                  // Area.position 是相对父组件的局部坐标(d.ts 标注 "local position"):
                  // 内层 Row 在 Stack 原点,胶囊与 chip 共用同一坐标系,x 直接当 translate 用
                  this.chipX[idx] = Number(n.position.x);
                  this.chipW[idx] = Number(n.width);
                  if (idx === this.selected) this.springTo(idx);
                })
            }, (label: string, idx: number) => `${idx}-${label}`)
          }
          .padding({ left: 8, right: 8 })
          .onAreaChange(() => { this.revealSelected(); })
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(CHIPS_STRIP_H)
      .borderRadius(21)
      // 玻璃本体:参数与 GlassTabBar 一致(见彼处注释),两端观感统一
      .backgroundEffect({
        radius: 40,
        saturation: 1.3,
        brightness: 1.0,
        color: withAlpha(this.scheme.surface, 0.6)
      })
      .border({ width: 0.8, color: withAlpha(this.scheme.outline, 0.45) })
      .align(Alignment.Start)
    }
    .width('100%')
    .height(CHIPS_STRIP_H)
    .padding({ left: 12, right: 12 })
  }
}

/**
 * 分类条的透明胶囊渲染器,独立成组件的目的是把 Swiper 手势期间的每帧重建
 * 压到最小面:帧数据经 ChipsSwipeSync 回调推进(@State 仅胶囊自身),
 * 整条 ChipsRow 与所有 chip 不参与。
 *
 * 两种绘制态:手势中(live)按 from→to 插值 1:1 跟手;否则画弹簧静止位
 * capX/capW(由 ChipsRow 的 springTo 驱动,收尾回调先把 live 摘掉再弹簧,
 * 因此弹簧中途切回静止位时画的是动画中的当前值,不跳变)。
 */
@Component
struct ChipsCapsule {
  @Prop scheme: Scheme;
  @Prop capX: number = 0;
  @Prop capW: number = 0;
  /** 手势插值绘制态:live=true 期间画 ix/iw */
  @State live: boolean = false;
  @State ix: number = 0;
  @State iw: number = 0;
  /** 各 chip 实测位置/宽度 —— 与 ChipsRow 共享同一数组引用,读时即最新值 */
  chipX: number[] = [];
  chipW: number[] = [];
  private sync: ChipsSwipeSync = new ChipsSwipeSync();

  private frameSink = (f: number, t: number, p: number): void => {
    const fx = this.chipX[f] ?? -1;
    const tx = this.chipX[t] ?? -1;
    const fw = this.chipW[f] ?? -1;
    const tw = this.chipW[t] ?? -1;
    if (fx < 0 || tx < 0 || fw <= 0 || tw <= 0) return;
    this.ix = fx + (tx - fx) * p;
    this.iw = fw + (tw - fw) * p;
    this.live = true;
  };

  aboutToAppear(): void {
    this.sync.onFrame(this.frameSink);
    // 后于行注册(行的 aboutToAppear 先跑):收尾时行先弹簧、这里再摘插值态
    this.sync.addEndSink((_t: number): void => { this.live = false; });
  }

  build() {
    Row()
      .width(this.live ? this.iw : this.capW)
      .height(34)
      .borderRadius(17)
      // 染色比底部药丸(0.15)深:胶囊滑到两颗 chip 之间的空档时,底下只有玻璃条 +
      // 米色页面,0.15 几乎隐形(实测拖到中途截图基本看不见),加深才能读出"在移动"
      .backgroundColor(withAlpha(this.scheme.primary, 0.26))
      .border({ width: 0.8, color: withAlpha(this.scheme.primary, 0.30) })
      .translate({ x: this.live ? this.ix : this.capX })
      .visibility((this.live || this.capW > 0) ? Visibility.Visible : Visibility.None)
  }
}
