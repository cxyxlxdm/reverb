import { Scheme, TypeScale, withAlpha, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { ArtworkCache } from '../store/ArtworkCache';

/// 通用小部件:图标 / 页头 / 返回顶栏 / 空态 / 加载态 / 封面。
/// 对应 Android `ui/screens/Widgets.kt` + 部分 `ui/components/Components.kt`。

/**
 * 统一图标。**全项目的图标都走这里**,不要各处散写 `Image($r('sys.media...'))`。
 *
 * 为什么用 `SymbolGlyph` 而不是 `sys.media.*` 图片:`sys.media.ohos_ic_public_*` 只有 66 个,
 * 没有齿轮/柱状图/宫格/列表/罗盘/随机/心形/月亮/下载/队列 —— 当初只能拿文字("宫格""清空""下载")
 * 和近似图标(设置用 ⋯、收听时长用喇叭)凑,与 Android 的 Material Rounded 一套对不上。
 * 鸿蒙另有 Symbol 字体(4000+ 个,SF Symbols 风格命名),`SymbolGlyph` 自 API 11 起可用,
 * 这才是平台原生做法。名称见 `Sym`。
 *
 * 注意 `fontColor` 收的是**数组**(Symbol 支持分层多色),单色就传一个元素。
 */
@Component
export struct Glyph {
  /// `sys.symbol.*` 资源,用 `Sym` 里的常量
  @Prop symbol: Resource;
  /// 字号即图标视觉尺寸。**不能叫 `size`** —— 与 CustomComponent 自带的 `.size()` 属性冲突,
  /// 编译期报 "Property 'size' ... is not assignable to the same property in base type"。
  @Prop dim: number;
  @Prop color: ResourceColor;
  /**
   * 是否加粗描边。**默认不加粗** —— 保持 Symbol 字体原本的笔画。
   *
   * 试过默认给 Medium,想让鸿蒙图标"厚"一点去追 Android 的观感,结论是**方向错了**:
   * 两端图标的真正差别是 Material Rounded 为**实心**、Symbol 为**描边**,
   * 加粗描边并不会变成实心,只会让线条显得笨拙、整体"大一圈"。
   * 描边细是鸿蒙的图标语言,按平台特性保留(同 Sym 注释里三点图标那条取舍)。
   */
  @Prop bold: boolean = false;

  build() {
    SymbolGlyph(this.symbol)
      .fontSize(this.dim)
      .fontColor([this.color])
      .fontWeight(this.bold ? FontWeight.Medium : FontWeight.Normal)
  }
}

/// 系统 media 图标(少数 Symbol 字体里没有对等形状的场合用它)。
@Component
export struct GlyphImage {
  @Prop icon: Resource;
  @Prop dim: number;
  @Prop color: ResourceColor;

  build() {
    Image(this.icon)
      .width(this.dim).height(this.dim)
      .fillColor(this.color)
  }
}

/**
 * Symbol 名称表。与 Android 的 Material Rounded 图标一一对应,改哪端都要同步另一端。
 * 左侧注释即 Android 侧用的图标名,便于双端比对。
 */
export class Sym {
  static readonly settings: Resource = $r('sys.symbol.gearshape');              // Rounded.Settings
  static readonly listenStats: Resource = $r('sys.symbol.histogram');           // Rounded.BarChart
  static readonly grid: Resource = $r('sys.symbol.square_grid_2x2');            // Rounded.GridView
  static readonly list: Resource = $r('sys.symbol.list_bullet');                // AutoMirrored.ViewList
  static readonly discover: Resource = $r('sys.symbol.discover');               // Rounded.Explore
  // 底部 tab 的**选中态**用实心变体,未选中用描边 —— 这是 Material 的标准做法,
  // Android 侧就是这样(发现选中时是实心罗盘、音阁未选中是描边)。
  // 描边大圆环在视觉上会被读成"比实心的更大",选中态尤其显笨。
  static readonly discoverFill: Resource = $r('sys.symbol.discover_fill');
  static readonly libraryFill: Resource = $r('sys.symbol.music_note_list_fill');
  static readonly library: Resource = $r('sys.symbol.music_note_list');         // Rounded.LibraryMusic
  /**
   * 底部 tab「追更」。Android 侧是 `Icons.Rounded.RssFeed`(`ReverbRoot.kt:182`)。
   *
   * Symbol 字体里**没有 rss 那枚**,对等形状是「无线电波」`dot_radiowaves_left_and_right`
   * (名字取自 SDK 的 `sysResource.js` symbol 表,已核对存在 —— `sys.symbol.*` 写错不报错、
   * 直接空白,见下面 noteDelete 那段)。它**没有 `_fill` 变体**,所以这一项选中态只换色 + 加粗,
   * 判据写在 `BottomBar.SystemTabItem.hasFill`。
   */
  static readonly feed: Resource = $r('sys.symbol.dot_radiowaves_left_and_right');
  /**
   * 底部 tab「电台」。Android 侧是 `Icons.Rounded.Radio`;Symbol 表里正好有 `radio` 这个名字
   * (取自 SDK 的 `toolchains/id_defined.json`,type=symbol,已核对存在 —— `sys.symbol.*`
   * 写错**不报错、直接空白**)。
   * ⚠️ 它**没有 `_fill` 变体**(`radio_fill` 不在表里),所以这一格选中态只换色 + 加粗,
   * 判据与「追更」那条同形,见 `BottomBar.SystemTabItem.hasFill`。
   */
  static readonly radio: Resource = $r('sys.symbol.radio');
  static readonly plus: Resource = $r('sys.symbol.plus');
  static readonly shuffle: Resource = $r('sys.symbol.shuffle');                 // Rounded.Shuffle
  // 播放模式三态里的「单曲循环」。Material 侧是 Rounded.RepeatOne,Symbol 字体的对等件
  // 就是 repeat_1(循环箭头里带一个 1);**不要拿 `repeat` 冒充** —— 那枚是"列表循环",
  // 而列表循环这个模式在 2026-09-28 已经被单曲循环替掉了(见 PlayerController 枚举注释、H118)。
  static readonly repeatOne: Resource = $r('sys.symbol.repeat_1');              // Rounded.RepeatOne
  static readonly sun: Resource = $r('sys.symbol.sun_max');                     // Rounded.WbSunny
  static readonly twilight: Resource = $r('sys.symbol.cloud_and_sun_fill');     // Rounded.WbTwilight
  static readonly moon: Resource = $r('sys.symbol.moon');                       // 情境电台·夜间
  static readonly sleep: Resource = $r('sys.symbol.moon_fill');                 // Rounded.Bedtime
  static readonly favorite: Resource = $r('sys.symbol.heart_fill');             // Rounded.Favorite
  static readonly favoriteOff: Resource = $r('sys.symbol.heart');               // Rounded.FavoriteBorder
  static readonly download: Resource = $r('sys.symbol.download');               // Rounded.Download
  static readonly downloaded: Resource = $r('sys.symbol.square_and_arrow_down_badge_checkmark'); // Rounded.DownloadDone
  static readonly queue: Resource = $r('sys.symbol.music_note_list');           // AutoMirrored.QueueMusic
  // 「加入播放列表」用列表+加号(add_songlist),不用上面那枚 —— 详情页行内两个入口并存,
  // 同形不同义会让人以为点它也是「打开队列」(真机反馈)。
  static readonly queueAdd: Resource = $r('sys.symbol.add_songlist');           // AutoMirrored.PlaylistAdd
  static readonly share: Resource = $r('sys.symbol.share');                     // Rounded.Share
  // 播放页动作排:批注 / 盖章。名字取自 SDK 的 `toolchains/id_defined.json`
  // (type=symbol,已核对存在),不是凭形状猜的 —— `sys.symbol.*` 写错**不报错、直接空白**。
  // Android 侧分别是 `Icons.Rounded.EditNote` 与 `Icons.Rounded.Verified`;
  // 鸿蒙这枚 `seal` 是字面意义上的印章,比 Verified 的徽章更贴本端叫法(听觉印记 / 盖章)。
  static readonly note: Resource = $r('sys.symbol.square_and_pencil');          // Rounded.EditNote
  static readonly seal: Resource = $r('sys.symbol.seal');                       // Rounded.Verified
  static readonly playing: Resource = $r('sys.symbol.hi_waveform_2');           // Rounded.GraphicEq
  static readonly played: Resource = $r('sys.symbol.checkmark');                // Rounded.Check(裸对勾)
  // 注:Symbol 字体里 `more` 是「更多应用」的 2×2 方块,不是省略号;纯省略号只有
  // ellipsis_bubble / ellipsis_circle 这类带容器的变体。播放页的「更多」菜单已撤
  // (四项动作移到播放键下方),顶栏不再需要三点 —— 历史实现用的是系统 media 里的
  // `ohos_ic_public_more` / 自绘 `ic_more_vert`,留在这里只为记录形状取法的来历。
  // 列表封面上叠的播放/暂停:**裸三角与双竖条**,对齐 Android 的 Rounded.PlayArrow / Pause。
  // 不用 `sys.media.ohos_ic_public_play` —— 那枚带白色圆底,叠在封面上显得笨重。
  static readonly playFill: Resource = $r('sys.symbol.play_fill');              // Rounded.PlayArrow
  static readonly pauseFill: Resource = $r('sys.symbol.pause_fill');            // Rounded.Pause
  static readonly close: Resource = $r('sys.symbol.xmark');                     // Rounded.Close
  static readonly search: Resource = $r('sys.symbol.magnifyingglass');       // Rounded.Search
  static readonly up: Resource = $r('sys.symbol.chevron_up');                   // Rounded.KeyboardArrowUp
  static readonly down: Resource = $r('sys.symbol.chevron_down');               // Rounded.KeyboardArrowDown
  static readonly speed: Resource = $r('sys.symbol.slider_horizontal_2');       // Rounded.Tune(倍速)
  static readonly footprint: Resource = $r('sys.symbol.checkmark_square_fill'); // 听觉足迹(印记)
  /**
   * 批注行末的删除。Android 侧是 `Icons.Rounded.DeleteOutline`。
   *
   * 名字取自 SDK 的系统资源表(`toolchains/id_defined.json` 里 type=symbol 的 `trash`),
   * 不是猜的 —— Widgets 顶部写着:`sys.symbol.*` **写错不报错、直接空白**,
   * 所以此前每次换这类资源都得真机看一眼;这次装机前只做到"表里有这个名"。
   */
  static readonly noteDelete: Resource = $r('sys.symbol.trash');                // Rounded.DeleteOutline
  /**
   * 分类排序行末的拖拽把手。Android 侧是 `Icons.Rounded.DragHandle`(两条圆头横杠)。
   *
   * `sys.symbol.*` 写错不报错、直接空白(见上面 noteDelete 那段),所以这个名字取自
   * SDK 的 `toolchains/id_defined.json`(type=symbol,已核对存在),不是凭形状猜的。
   * 表里另有 `line_3_horizontal`(三条),Android 那枚是**两条**,故取 `_2`。
   */
  static readonly dragHandle: Resource = $r('sys.symbol.line_2_horizontal');    // Rounded.DragHandle
  /**
   * 批量条上的「全选」。Android 那侧是 `Icons.Rounded.SelectAll`,而且是**图标不是文字** ——
   * 理由直接照搬(见 `Components.kt SelectionBar`):es/fr 的「已选 N」+「全选」+「加入待播」
   * 三串文字挤在同一行会顶出屏外。这条在鸿蒙只会更严重(本机逻辑宽比 Android 那台窄 14%)。
   *
   * 名字取自 SDK 的 `toolchains/id_defined.json`(type=symbol,已核对存在),不是凭形状猜的 ——
   * `sys.symbol.*` 写错**不报错、直接空白**(见上面 noteDelete 那段)。表里另有
   * `checkmark_square_on_square_fill`(实心),Android 那枚是描边,故取不带 `_fill` 的那条。
   * ⚠️ **装机要扫一眼它画得出图形**:表里有名只等于"不会被静默丢弃",不等于真机渲染得出。
   */
  static readonly selectAll: Resource = $r('sys.symbol.checkmark_square_on_square'); // Rounded.SelectAll
}

/// 顶层页大标题头:标题 + 可选副标 + 右侧动作插槽 + 下方一道「梁金」细线。
@Component
export struct ScreenHeader {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop title: string;
  @Prop subtitle: string = '';
  @BuilderParam action: () => void = this.emptyAction;

  @Builder emptyAction(): void {}

  build() {
    Column() {
      // 动作键只与标题行对中:副标题若参与 Row 的垂直居中,有无副标题的两页
      // (发现/音阁)动作键会差出半个副标题的高度,随机电台与设置按钮就不在
      // 同一条水平线上了(与 Android ScreenHeader 同一修法)。
      Row() {
        Text(this.title)
          .fontSize(TypeScale.headlineMedium * this.fontScale)
          // **SemiBold,对齐 Android**:`ui/screens/Widgets.kt` 的 ScreenHeader
          // 显式写了 `fontWeight = FontWeight.SemiBold`。这里原先是 Bold(700),
          // 同一档字号下粗一档就读成"大一号"——用户反馈的"鸿蒙字体有些大",
          // 实测两端字号表同值,字重与行数才是来源(另一处见 Components.PodcastListItem)。
          // 写数值不写枚举:本 SDK 的 FontWeight 枚举里没有 SemiBold 这一档。
          .fontWeight(600)
          .fontColor(this.scheme.onBackground)
          .layoutWeight(1)

        this.action()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 35×3 圆角细线,用「梁金」次强调色。金线紧跟标题行、标语降为线下方
      // 说明文字(与 Android 同步换位):原来 标题→标语→金线 的顺序让有标语
      // 的页面金线位置与音阁页错开,两页不对齐。
      // 为什么宽从 40 收到 35:这是**装饰(外壳)**不是文字,按屏幕宽等比对齐 ——
      // Android 40/427.6 = 9.4%,鸿蒙同一屏幕逻辑宽只有 374.2vp,写 40 就是 10.7%
      // (整块外壳的换算与来由见 `shelved/GlassTabBar.ets` 的 `BAR_H`、`CHIPS_STRIP_H`)。
      // 高度**没有**跟着收:3×0.876 = 2.6,只差 0.4vp,这是描边级的量、读不出来;
      // 而"这根线占了多宽"是看得见的比例。标题字号留在 24 没动 —— 那是可读性常量,
      // 按绝对物理大小对齐(24fp × 1.18 ≈ Android 28sp),见 H51 的补充。
      Row()
        .width(35)
        .height(3)
        .backgroundColor(this.scheme.secondary)
        .borderRadius(2)
        .margin({ top: 4 })

      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .margin({ top: 10 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: Metrics.topPadding, bottom: 10 })
  }
}

/// 二级页返回顶栏:返回箭头 + 标题。
@Component
export struct TopBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop title: string;
  onBack: () => void = () => {};

  build() {
    Row({ space: 4 }) {
      Button() {
        Image($r('sys.media.ohos_ic_back'))
          .width(22).height(22)
          .fillColor(this.scheme.onBackground)
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(40).height(40)
      .accessibilityText(L.s('action_back'))
      .onClick(() => this.onBack())

      Text(this.title)
        .fontSize(TypeScale.titleLarge * this.fontScale)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 4, right: 12, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }
}

/// 居中空态提示。
@Component
export struct EmptyHint {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop text: string;

  build() {
    Column() {
      Text(this.text)
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(36)
  }
}

/// 居中加载态。
@Component
export struct LoadingBox {
  @Prop scheme: Scheme;
  @Prop fontScale: number;

  build() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(36).height(36)
        .color(this.scheme.primary)
      Text(L.s('loading'))
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}

/**
 * 封面取源的**唯一一条路**(`Artwork` 与 `SquareArtwork` 共用,别抄两遍)。
 *
 * 返回该 url 已有的本地副本 uri(没有则空串,由调用方直接用远程 url);
 * 同时把这张图挂进缓存队列,落盘成功后通过 [onHit] 回来换源。
 *
 * 这里只做一次 Map 查表和一次入队,**没有同步 IO** —— 这两个组件在列表里成几十份地构造,
 * 渲染路径上落一次磁盘读就是硬规矩 6 那条老账。
 */
function artworkSource(url: string, onHit: (uri: string) => void): string {
  if (url.length === 0) return '';
  const cache = ArtworkCache.get();
  const have = cache.uriFor(url);
  cache.ensure(url, have === null ? onHit : null);
  return have === null ? '' : have;
}

/// 固定尺寸封面。空 url 用低饱和底 + 波形图标占位(对齐 Android Artwork)。
@Component
export struct Artwork {
  @Prop scheme: Scheme;
  /** `@Watch`:列表复用 / 换台时 url 会变,本地副本必须跟着重解,否则显示的是上一张的本地图。 */
  @Prop @Watch('onUrlChange') url: string;
  @Prop dim: number = 56;
  @Prop corner: number = 12;
  /**
   * 这一张封面的**本地副本 uri**(空串表示还没有,直接用远程 URL)。
   * 断网时「已加载过的列表」还能看到图,靠的就是这一格 —— 见 `store/ArtworkCache`。
   */
  @State localUri: string = '';

  aboutToAppear(): void {
    this.resolveLocal();
  }

  onUrlChange(): void {
    this.resolveLocal();
  }

  private resolveLocal(): void {
    this.localUri = artworkSource(this.url, (uri: string) => { this.localUri = uri; });
  }

  /**
   * 本地副本读不出来就回落远程源。
   *
   * 会出现这一手的场合是「清除缓存」按下去时,别的页还在页面栈里、它 holding 的 uri 已经指向
   * 被删掉的文件 —— 不兜这一下,那些封面会**一直空白**,而不是退回联网重取。
   * 判据是"此刻用的是本地图":置空后这一张走远程,远程也失败时再进来是 no-op,不会来回切。
   */
  private dropLocalCopy(): void {
    if (this.localUri.length > 0) this.localUri = '';
  }

  build() {
    Stack() {
      // 占位色块垫底:加载中/失败都显示低饱和底,不露出应用图标
      Row()
        .width(this.dim).height(this.dim)
        .backgroundColor(withAlpha(this.scheme.primary, 0.18))
      // 无封面时叠一枚波形图标(对齐 Android Artwork 的 GraphicEq 占位)。
      // 图标**不按 url 是否为空来分支**:地址失效时 Image 是透明的,垫在底下的图标正好顶上来,
      // 不会留下一个空色块。图片加载成功后整张盖住它。
      Glyph({ symbol: Sym.playing, dim: Math.max(14, this.dim * 0.42), color: this.scheme.primary })
      if (this.url.length > 0) {
        Image(this.localUri.length > 0 ? this.localUri : this.url)
          .width(this.dim).height(this.dim)
          .objectFit(ImageFit.Cover)
          .onError(() => { this.dropLocalCopy(); })
      }
    }
    .width(this.dim).height(this.dim)
    .borderRadius(this.corner)
    .clip(true)
  }
}

/// 自适应方形封面(宫格用):铺满容器宽度,保持 1:1。
@Component
export struct SquareArtwork {
  @Prop scheme: Scheme;
  @Prop @Watch('onUrlChange') url: string;
  @Prop corner: number = Metrics.cardCorner;
  /// 同 `Artwork.localUri`:宫格是「已加载过的列表」断网后最主要的受害界面,必须走本地副本
  @State localUri: string = '';

  aboutToAppear(): void {
    this.resolveLocal();
  }

  onUrlChange(): void {
    this.resolveLocal();
  }

  private resolveLocal(): void {
    this.localUri = artworkSource(this.url, (uri: string) => { this.localUri = uri; });
  }

  /// 同 `Artwork.dropLocalCopy`
  private dropLocalCopy(): void {
    if (this.localUri.length > 0) this.localUri = '';
  }

  build() {
    Stack() {
      Row()
        .width('100%')
        .aspectRatio(1)
        .backgroundColor(withAlpha(this.scheme.primary, 0.18))
      if (this.url.length === 0) {
        Glyph({ symbol: Sym.playing, dim: 30, color: this.scheme.primary })
      }
      if (this.url.length > 0) {
        /**
         * `draggable(false)` 不是防"拖出去",是**把外层卡片的长按让回来**。
         * Image 自带一注册就是开着的长按-拖拽识别器(约 350ms 起缩略图),
         * 它在这条命中链上比外层卡片更深,于是长按封面的那一下被它吃掉,
         * 卡片上的 `bindContextMenu` 根本不弹 —— 而长按同一张卡的标题文字却正常。
         * 症状是"菜单在图的区域失灵",极易误判成菜单本身的问题(见 H100)。
         */
        Image(this.localUri.length > 0 ? this.localUri : this.url)
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => { this.dropLocalCopy(); })
      }
    }
    .width('100%')
    .aspectRatio(1)
    .borderRadius(this.corner)
    .clip(true)
  }
}
