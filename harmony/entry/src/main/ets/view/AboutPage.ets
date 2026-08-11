import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { TopBar } from './Widgets';

/// 关于 + 开源许可(两端同款的静态页,合成一页两段)。
@Component
export struct AboutPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};

  private libs: string[] = [
    'HarmonyOS SDK (ArkTS / ArkUI) — Apache-2.0',
    'Apple iTunes Search / Charts — 公开接口,无需鉴权',
    'fyyd.de API — 公开接口',
    'gpodder.net API — 公开接口'
  ];

  build() {
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: L.s('about_title'), onBack: () => this.onBack()
      })
      Scroll() {
        Column({ space: 10 }) {
          Text(L.f('about_line', '1.0.0'))
            .fontSize(TypeScale.titleMedium * this.fontScale)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.scheme.onBackground)
          Text(L.s('about_body'))
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .lineHeight(22)

          Text(L.s('licenses_title'))
            .fontSize(TypeScale.titleSmall * this.fontScale)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.scheme.onBackground)
            .margin({ top: 16 })
          ForEach(this.libs, (s: string) => {
            Text(s)
              .fontSize(TypeScale.label * this.fontScale)
              .fontColor(this.scheme.onSurfaceVariant)
              .width('100%')
          }, (s: string) => s)

          Text(L.s('about_sources'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .lineHeight(20)
            .margin({ top: 16, bottom: 24 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
