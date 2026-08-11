import { Scheme, TypeScale, withAlpha, Metrics } from '../theme/Theme';
import { L } from '../util/L';

/// 通用小部件:页头 / 返回顶栏 / 空态 / 加载态 / 封面。
/// 对应 Android `ui/screens/Widgets.kt` + 部分 `ui/components/Components.kt`。

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
      Row() {
        Column() {
          Text(this.title)
            .fontSize(TypeScale.headlineMedium * this.fontScale)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.scheme.onBackground)
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(TypeScale.label * this.fontScale)
              .fontColor(this.scheme.onSurfaceVariant)
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        this.action()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 40×3 圆角细线,用「梁金」次强调色
      Row()
        .width(40)
        .height(3)
        .backgroundColor(this.scheme.secondary)
        .borderRadius(2)
        .margin({ top: 10 })
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
