import { Scheme, TypeScale, withAlpha, Metrics } from '../theme/Theme';
import { L } from '../util/L';

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
  static readonly shuffle: Resource = $r('sys.symbol.shuffle');                 // Rounded.Shuffle
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
  static readonly playing: Resource = $r('sys.symbol.hi_waveform_2');           // Rounded.GraphicEq
  static readonly played: Resource = $r('sys.symbol.checkmark');                // Rounded.Check(裸对勾)
  // 注:Symbol 字体里 `more` 是「更多应用」的 2×2 方块,不是省略号;纯省略号只有
  // ellipsis_bubble / ellipsis_circle 这类带容器的变体。三点用系统 media 里的标准件
  // `ohos_ic_public_more`(见 Widgets.GlyphImage) —— Android 是竖排三点 MoreVert,
  // 鸿蒙的平台惯例是横排三点,按「缺资源按平台特性补齐」取鸿蒙形态。
  // 列表封面上叠的播放/暂停:**裸三角与双竖条**,对齐 Android 的 Rounded.PlayArrow / Pause。
  // 不用 `sys.media.ohos_ic_public_play` —— 那枚带白色圆底,叠在封面上显得笨重。
  static readonly playFill: Resource = $r('sys.symbol.play_fill');              // Rounded.PlayArrow
  static readonly pauseFill: Resource = $r('sys.symbol.pause_fill');            // Rounded.Pause
  static readonly close: Resource = $r('sys.symbol.xmark');                     // Rounded.Close
  static readonly up: Resource = $r('sys.symbol.chevron_up');                   // Rounded.KeyboardArrowUp
  static readonly down: Resource = $r('sys.symbol.chevron_down');               // Rounded.KeyboardArrowDown
  static readonly speed: Resource = $r('sys.symbol.slider_horizontal_2');       // Rounded.Tune(倍速)
  static readonly footprint: Resource = $r('sys.symbol.checkmark_square_fill'); // 听觉足迹(印记)
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
          .fontWeight(FontWeight.Bold)
          .fontColor(this.scheme.onBackground)
          .layoutWeight(1)

        this.action()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 40×3 圆角细线,用「梁金」次强调色。金线紧跟标题行、标语降为线下方
      // 说明文字(与 Android 同步换位):原来 标题→标语→金线 的顺序让有标语
      // 的页面金线位置与音阁页错开,两页不对齐。
      Row()
        .width(40)
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

/// 固定尺寸封面。空 url 用低饱和底 + 波形图标占位(对齐 Android Artwork)。
@Component
export struct Artwork {
  @Prop scheme: Scheme;
  @Prop url: string;
  @Prop dim: number = 56;
  @Prop corner: number = 12;

  build() {
    Stack() {
      // 占位色块垫底:加载中/失败都显示低饱和底,不露出应用图标
      Row()
        .width(this.dim).height(this.dim)
        .backgroundColor(withAlpha(this.scheme.primary, 0.18))
      // 无封面时叠一枚波形图标(对齐 Android Artwork 的 GraphicEq 占位)。
      // 注:此前注释写了"波形图标占位",但代码里只有色块、并没有画图标 —— sys.media.* 无此形状。
      if (this.url.length === 0) {
        Glyph({ symbol: Sym.playing, dim: Math.max(14, this.dim * 0.42), color: this.scheme.primary })
      }
      if (this.url.length > 0) {
        Image(this.url)
          .width(this.dim).height(this.dim)
          .objectFit(ImageFit.Cover)
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
  @Prop url: string;
  @Prop corner: number = Metrics.cardCorner;

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
        Image(this.url)
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
      }
    }
    .width('100%')
    .aspectRatio(1)
    .borderRadius(this.corner)
    .clip(true)
  }
}
