import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { TopBar } from './Widgets';

/// 一项依赖及其许可。
class Lib {
  name: string = '';
  license: string = '';
  constructor(name: string, license: string) {
    this.name = name;
    this.license = license;
  }
}

/**
 * 开源许可页。对应 Android `LicensesScreen.kt`。
 *
 * 与 Android 的清单**内容不同、性质相同**:Android 列的是 Compose / Media3 / OkHttp /
 * Coil / Coroutines / WorkManager;鸿蒙端**零三方依赖**,用到的全是系统能力,
 * 所以列的是 HarmonyOS SDK 自身与所用的系统 Kit。取源清单两端一致。
 */
const LIBS: Lib[] = [
  new Lib('HarmonyOS SDK (ArkTS / ArkUI)', 'Apache License 2.0'),
  new Lib('AVPlayer / AVSession (Media Kit)', 'Apache License 2.0'),
  new Lib('@ohos.net.http (Network Kit)', 'Apache License 2.0'),
  new Lib('@ohos.xml (XmlPullParser)', 'Apache License 2.0'),
  new Lib('Share Kit / Core File Kit', 'Apache License 2.0'),
  new Lib('workScheduler / notificationManager', 'Apache License 2.0')
];

const SOURCES: string[] = [
  'Apple iTunes Search / Marketing RSS',
  'fyyd.de',
  'gpodder.net'
];

@Component
export struct LicensesPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};

  build() {
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: L.s('licenses_title'), onBack: () => this.onBack()
      })
      Scroll() {
        Column({ space: 6 }) {
          Text(L.s('licenses_intro'))
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)

          this.header(L.s('licenses_h_libs'))
          ForEach(LIBS, (lib: Lib) => {
            Row() {
              Text(lib.name)
                .fontSize(TypeScale.label * this.fontScale)
                .fontColor(this.scheme.onBackground)
                .layoutWeight(1)
              Text(lib.license)
                .fontSize(TypeScale.caption * this.fontScale)
                .fontColor(this.scheme.onSurfaceVariant)
            }
            .width('100%')
            .padding({ top: 7, bottom: 7 })
            .alignItems(VerticalAlign.Center)
          }, (lib: Lib) => lib.name)

          this.header(L.s('licenses_h_sources'))
          Text(L.s('licenses_sources_note'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
          ForEach(SOURCES, (s: string) => {
            Text(s)
              .fontSize(TypeScale.label * this.fontScale)
              .fontColor(this.scheme.onBackground)
              .padding({ top: 6, bottom: 6 })
          }, (s: string) => s)

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
  header(text: string) {
    Text(text)
      .fontSize(TypeScale.titleSmall * this.fontScale)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.scheme.primary)
      .margin({ top: 20, bottom: 4 })
  }
}
