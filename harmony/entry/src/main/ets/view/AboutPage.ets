import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { TopBar } from './Widgets';

/**
 * 关于页。对应 Android `AboutScreen.kt`:应用名 + slogan + 版本,再三段正文
 * (这是什么 / 主要功能 / 设计理念)。
 *
 * 原先这一页把「开源库 + 取源顺序」也塞在里面(当时还没有独立的许可页),
 * 与 Android 的两页分工不符。取源与许可现已迁到 `LicensesPage`,本页只留 Android 的三段。
 */
@Component
export struct AboutPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};

  build() {
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: L.s('sec_about'), onBack: () => this.onBack()
      })
      Scroll() {
        Column({ space: 6 }) {
          Text(L.s('about_app'))
            .fontSize(TypeScale.headlineMedium * this.fontScale)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.scheme.onBackground)
          Text(L.s('app_slogan'))
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.secondary)
          Text(L.s('about_version'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)

          this.section(L.s('about_h_what'), L.s('about_p_what'))
          this.section(L.s('about_h_features'), L.s('about_p_features'))
          this.section(L.s('about_h_philosophy'), L.s('about_p_philosophy'))

          Row().height(24)
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

  @Builder
  section(title: string, body: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(TypeScale.titleMedium * this.fontScale)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
      Text(body)
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
        .lineHeight(23)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 18 })
  }
}
