import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Stamp } from '../store/StampStore';
import { AppContainer } from '../AppContainer';
import { TopBar, EmptyHint } from './Widgets';

/// 听觉足迹:把所有听觉印记以水墨印章网格呈现。
/// 对应 Android `StampsScreen.kt` / macOS `FootprintView.swift`。
@Component
export struct FootprintPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};

  private app: AppContainer = AppContainer.get();

  build() {
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: L.s('footprint_title'), onBack: () => this.onBack()
      })
      if (this.app.stamps.stamps.length === 0) {
        EmptyHint({
          scheme: this.scheme, fontScale: this.fontScale,
          text: L.s('footprint_empty')
        })
          .layoutWeight(1)
      } else {
        Scroll() {
          Grid() {
            ForEach(this.app.stamps.stamps, (s: Stamp) => {
              GridItem() {
                this.chip(s)
              }
            }, (s: Stamp) => s.episodeId)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(12)
          .rowsGap(12)
          .padding(Metrics.pagePadding)
          .height(Math.ceil(this.app.stamps.stamps.length / 3) * 180 + 20)
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  chip(s: Stamp) {
    Column({ space: 6 }) {
      // 水墨印章:圆角方块 + 大号印字
      Stack() {
        Row()
          .width('100%').aspectRatio(1)
          .backgroundColor(withAlpha(this.scheme.primary, 0.14))
          .borderRadius(14)
        Text(s.seal)
          .fontSize(TypeScale.displaySmall * this.fontScale)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.scheme.primary)
      }
      .width('100%').aspectRatio(1)

      Text(s.title)
        .fontSize(TypeScale.caption * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
  }
}
