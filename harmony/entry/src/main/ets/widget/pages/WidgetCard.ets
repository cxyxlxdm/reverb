/**
 * 「继续收听」服务卡片本体。
 *
 * 三档尺寸共用这一个文件,由提供方送的 `dim` 决定排法:
 *  - 2*2 / 2*4:左封面、右文字(窄卡与宽卡只差封面尺寸);
 *  - 4*4:封面当主视觉,文字压在下面(与 Android `widget_large.xml` 同构)。
 *
 * 两条卡片侧硬约束(踩过就知道):
 *  ① 卡片里**只有少数组件可用**,层级尽量只用 Column / Row / Stack / Text / Image;
 *    进度条因此是两条 Row 叠出来的,不用 Progress。
 *  ② 数据只认 `@LocalStorageProp`,字段名与 `WidgetFormData.ConfigKeys` 逐字一致;
 *    卡片进程拿不到 App 的沙箱文件,封面只能走 formImages(键名 `art`)。
 */
import { WidgetRoute } from '../WidgetRoute';

/// 卡片的数据靠 @LocalStorageProp 从 FormBindingData 注进来;@Entry 必须带上这一格
/// (官方卡片写法,漏了会被编译器告警,而且拿不到注入的数据)。
let storage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('label') label: string = '';
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('podcast') podcast: string = '';
  @LocalStorageProp('time') time: string = '';
  @LocalStorageProp('percent') percent: number = 0;
  @LocalStorageProp('hasProgress') hasProgress: boolean = false;
  @LocalStorageProp('empty') empty: boolean = true;
  @LocalStorageProp('dim') dim: string = '2*2';
  @LocalStorageProp('dark') dark: boolean = false;
  @LocalStorageProp('art') art: string = '';

  private bg(): string { return this.dark ? '#161D20' : '#FCFAF4'; }
  private textColor(): string { return this.dark ? '#F2F2ED' : '#1B2426'; }
  private subColor(): string { return this.dark ? '#9AA8A6' : '#66716F'; }
  private accent(): string { return this.dark ? '#7FD1C0' : '#3F8A7C'; }
  private track(): string { return this.dark ? '#1F2A2E' : '#E7E0D1'; }

  build() {
    Column() {
      if (this.dim === '4*4') {
        this.posterLayout()
      } else if (this.dim === '2*4') {
        this.sideLayout(84)
      } else {
        this.sideLayout(52)
      }
      if (this.hasProgress) {
        this.progressBar()
      }
      if (this.time.length > 0) {
        Text(this.time)
          .fontSize(10)
          .fontColor(this.subColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .borderRadius(16)
    .backgroundColor(this.bg())
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // 点了就进 App 的播放页;`router` 动作只带参数,不动 App 里的播放态(与 Android 侧同一口径:
      // 不自动播放,按下播放键才出声)。
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { reverbWidget: WidgetRoute.PLAYER }
      });
    })
  }

  /// 4×4:封面吃满顶部,文字压在下面。
  @Builder
  posterLayout() {
    Image(this.art.length > 0 ? this.art : $r('app.media.startIcon'))
      .width('100%')
      .layoutWeight(1)
      .objectFit(ImageFit.Cover)
      .borderRadius(10)
      .margin({ bottom: 10 })
    this.labelText(10)
    Text(this.title)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.textColor())
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .margin({ top: 3 })
    Text(this.podcast)
      .fontSize(12)
      .fontColor(this.subColor())
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .margin({ top: 3 })
  }

  /// 2×2 / 2×4:左封面、右文字,文字块在剩余高度里垂直居中。
  @Builder
  sideLayout(artSize: number) {
    Row() {
      Image(this.art.length > 0 ? this.art : $r('app.media.startIcon'))
        .width(artSize)
        .height(artSize)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
      Column() {
        this.labelText(9)
        Text(this.title)
          .fontSize(this.dim === '2*4' ? 14 : 12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
        Text(this.podcast)
          .fontSize(this.dim === '2*4' ? 11 : 9)
          .fontColor(this.subColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .margin({ left: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  labelText(size: number) {
    if (this.label.length > 0) {
      Text(this.label)
        .fontSize(size)
        .fontColor(this.accent())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
  }

  /// 进度条:卡片里没有可依赖的 Progress,用两条 Row 叠(底轨 + 按百分比宽的前景)。
  @Builder
  progressBar() {
    Stack({ alignContent: Alignment.Start }) {
      Row().width('100%').height(3).backgroundColor(this.track()).borderRadius(2)
      Row().width(`${this.percent}%`).height(3).backgroundColor(this.accent()).borderRadius(2)
    }
    .width('100%')
    .height(3)
    .margin({ top: 8 })
  }
}
