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
 * Coil / Coroutines / WorkManager;鸿蒙端**不引三方库**,用到的全是系统能力,
 * 所以列的是 HarmonyOS SDK 自身与所用的系统 Kit。取源清单两端一致。
 *
 * 唯一的三方**素材**是底部页签那两枚图标:为了与 Android 端形状一致(并排截图时最显眼),
 * 从 Material Design Icons 取了 Explore / LibraryMusic 两个矢量打进包里,故单列一条。
 * **以后再往包里放任何三方素材,这张表都要同步补** —— 这一页是对外的合规陈述,不是摆设。
 */
const LIBS: Lib[] = [
  new Lib('HarmonyOS SDK (ArkTS / ArkUI)', 'Apache License 2.0'),
  new Lib('AVPlayer / AVSession (Media Kit)', 'Apache License 2.0'),
  new Lib('@ohos.net.http (Network Kit)', 'Apache License 2.0'),
  new Lib('@ohos.xml (XmlPullParser)', 'Apache License 2.0'),
  new Lib('Share Kit / Core File Kit', 'Apache License 2.0'),
  new Lib('workScheduler / notificationManager', 'Apache License 2.0'),
  // 打进包里的三方素材:底部页签的两枚矢量(与 Android 端同一批图标)
  new Lib('Material Design Icons(底部页签矢量)', 'Apache License 2.0')
];

// 数据来源列**实际用到的那些**。本端压根不连目录接口(见 Features.CATALOG),
// 照抄一份就是不实陈述。
//
// **不要写成 `Features.CATALOG ? [目录接口名...] : [...]`**:三元的两支都会被编进
// modules.abc,于是"Apple iTunes / fyyd.de / gpodder.net"这三个名字仍然出现在产物里
// (ArkTS 没有 dead code elimination,见 harmony/shelved/README.md)。
// TODO(catalog): 放开内容目录时,这里加回
// 'Apple iTunes Search / Marketing RSS' / 'fyyd.de' / 'gpodder.net' 三条。
const SOURCES: string[] = ['播客发布方自己的 RSS 地址', '本应用官网的推荐订阅清单(OPML)'];

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
          // 这段引言写「以下为公开的播客目录/检索接口」就是文不对题:下面列的是 RSS 地址
          // 与官网 OPML,压根没有目录接口。发布截图里这一页是会被复核人员逐字看的。
          // TODO(catalog): 放开内容目录时改回 licenses_sources_note_catalog。
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
