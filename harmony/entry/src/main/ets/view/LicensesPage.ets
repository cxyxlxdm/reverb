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
 *
 * **哪些留字面量、哪些走资源**,判据与 Android 那侧同一条:「换语种要不要变」。
 * `HarmonyOS SDK` / `AVPlayer` / `@ohos.net.http` 是专有名词与模块名,五套界面同形;
 * 而 `Material Design Icons(底部页签矢量)` 括号里那句、以及数据来源最后两条是**说明句**,
 * 法/西/英用户看到的就该是当地语言(2026-10-08 真机 fr/es 通读实测:原来是中文,见 H160)。
 * `src_publisher_rss` / `src_site_opml` 的取值与 Android **逐字相同** —— 漂了就是两份对外陈述。
 */
function buildLibs(): Lib[] {
  return [
    new Lib('HarmonyOS SDK (ArkTS / ArkUI)', 'Apache License 2.0'),
    new Lib('AVPlayer / AVSession (Media Kit)', 'Apache License 2.0'),
    new Lib('@ohos.net.http (Network Kit)', 'Apache License 2.0'),
    new Lib('@ohos.xml (XmlPullParser)', 'Apache License 2.0'),
    new Lib('Share Kit / Core File Kit', 'Apache License 2.0'),
    new Lib('workScheduler / notificationManager', 'Apache License 2.0'),
    // 打进包里的三方素材:底部页签的两枚矢量(与 Android 端同一批图标)
    new Lib(L.s('lic_mdi_tabs'), 'Apache License 2.0')
  ];
}

// 数据来源列**实际用到的那些**。目录接口只负责发现节目,播放仍走发布方 RSS。
function buildSources(): string[] {
  return [
    'Apple iTunes Search / Marketing RSS',
    'fyyd.de',
    'gpodder.net',
    L.s('src_publisher_rss'),
    L.s('src_site_opml')
  ];
}

@Component
export struct LicensesPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};
  /**
   * 两份清单在 `aboutToAppear` 取一次存字段,不写成顶层 const、也不在 `build()` 里现调:
   * `L.s` 要过 resourceManager,而模块加载时 `L.init` 还没跑,顶层求值会把**键名**当文案显示
   * (同一个坑见 `util/L.ets` 里 `L.f` 那段注释);在 build 里调则每帧都过一遍取串。
   */
  private libs: Lib[] = [];
  private sources: string[] = [];

  aboutToAppear(): void {
    this.libs = buildLibs();
    this.sources = buildSources();
  }

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
          ForEach(this.libs, (lib: Lib) => {
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
          Text(L.s('licenses_sources_note_catalog'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
          ForEach(this.sources, (s: string) => {
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
