/**
 * 「继续收听」服务卡片本体。
 *
 * 三档尺寸共用这一个文件,由提供方送的 `dim` 决定排法:
 *  - 2*2:左封面、右文字,播放/暂停压在封面上(这一档没有多余高度摆一行键);
 *  - 2*4:左封面、右文字,文字下面一行 上一集 / 播放暂停 / 下一集;
 *  - 4*4:封面当主视觉,文字与那行键压在下面(与 Android `widget_large.xml` 同构)。
 *
 * 三条卡片侧硬约束(踩过就知道):
 *  ① 卡片里**只有少数组件可用**,层级尽量只用 Column / Row / Stack / Text / Image;
 *    进度条因此是两条 Row 叠出来的,不用 Progress。图标用 `SymbolGlyph`(卡片自 API 12 起支持)。
 *  ② 数据只认 `@LocalStorageProp`,字段名与 `WidgetFormData.ConfigKeys` 逐字一致;
 *    卡片进程拿不到 App 的沙箱文件,封面只能走 formImages,值是 `memory://<键>`(见 H266)。
 *  ③ **点击会冒泡**:`.onClick` 挂在包住按钮的父节点上,点按钮会连父节点那一下一起触发
 *    (工程里多处踩过,见 MiniPlayerBar 封面覆盖层那段)。所以"进播放页"只挂在封面与
 *    文字块自己身上,播放键所在的那一层没有父级点击。
 *
 * 播放键走 `postCardAction` 的 `call` 动作(后台拉起 EntryAbility、不弹界面),只动播放态;
 * 点封面/文字走 `router` 进播放页 —— 与应用内迷你播放条的分工一致(点信息区展开,点键只动播放)。
 */
import { WidgetRoute } from '../WidgetRoute';

/// 卡片的数据靠 @LocalStorageProp 从 FormBindingData 注进来;@Entry 必须带上这一格
/// (官方卡片写法,漏了会被编译器告警,而且拿不到注入的数据)。
let storage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('podcast') podcast: string = '';
  @LocalStorageProp('time') time: string = '';
  @LocalStorageProp('percent') percent: number = 0;
  @LocalStorageProp('hasProgress') hasProgress: boolean = false;
  @LocalStorageProp('empty') empty: boolean = true;
  @LocalStorageProp('dim') dim: string = '2*2';
  @LocalStorageProp('dark') dark: boolean = false;
  @LocalStorageProp('art') art: string = '';
  /// 这一位由 App 侧 `WidgetRuntime` 落盘、`WidgetFormBuilder` 送过来;决定画播放还是暂停
  @LocalStorageProp('playing') playing: boolean = false;

  private bg(): string { return this.dark ? '#161D20' : '#FCFAF4'; }
  private textColor(): string { return this.dark ? '#F2F2ED' : '#1B2426'; }
  private subColor(): string { return this.dark ? '#9AA8A6' : '#66716F'; }
  private accent(): string { return this.dark ? '#7FD1C0' : '#3F8A7C'; }
  private track(): string { return this.dark ? '#1F2A2E' : '#E7E0D1'; }
  /// 压在 accent 底上的图标色。深色档的 accent 是浅青,白图标会糊在一起,所以用深底那一档墨色。
  private onAccent(): string { return this.dark ? '#10181A' : '#FFFFFF'; }

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
  }

  /// 4×4:封面吃满顶部,文字与那行键压在下面。
  @Builder
  posterLayout() {
    Image(this.art.length > 0 ? this.art : $r('app.media.startIcon'))
      .width('100%')
      .layoutWeight(1)
      .objectFit(ImageFit.Cover)
      .borderRadius(10)
      .margin({ bottom: 10 })
      .onClick(() => this.openPlayer())
    Column() {
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
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.openPlayer())
    if (!this.empty) {
      this.controlRow(28, FlexAlign.Center)
    }
  }

  /// 2×2 / 2×4:左封面、右文字;2×2 的播放键压在封面上,2×4 的在文字下面单独一行。
  @Builder
  sideLayout(artSize: number) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.art.length > 0 ? this.art : $r('app.media.startIcon'))
          .width(artSize)
          .height(artSize)
          .objectFit(ImageFit.Cover)
          .borderRadius(8)
          .onClick(() => this.openPlayer())
        if (!this.empty && this.dim !== '2*4') {
          this.filledButton(18, 30, WidgetRoute.ACTION_TOGGLE)
        }
      }
      Column() {
        // 文字块自己是一层点击区;**按键不能放进这一层**,否则点键会连"进播放页"一起冒上来
        Column() {
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
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .onClick(() => this.openPlayer())
        if (!this.empty && this.dim === '2*4') {
          this.controlRow(20, FlexAlign.Start)
        }
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

  /// 一行三颗键。2×4 那档左对齐(跟着文字走),4×4 居中(封面在主视觉上,键当一条 transport)。
  @Builder
  controlRow(size: number, align: FlexAlign) {
    Row({ space: 16 }) {
      this.symbolButton(size, WidgetRoute.ACTION_PREV)
      this.symbolButton(size, WidgetRoute.ACTION_TOGGLE)
      this.symbolButton(size, WidgetRoute.ACTION_NEXT)
    }
    .width('100%')
    .justifyContent(align)
    .margin({ top: 6 })
  }

  /**
   * ⚠️ 播放/暂停的图标**必须在 builder 内部读 `this.playing`**,不能当参数传进来:
   * `@Builder` 的参数是**按值**快照的,状态变了不会重算,时间文字翻了、图标还停在初始那一个
   * (2026-11-12 实测:时间行已显示播放中,封面上的键仍是 ▶)。见 H266。
   */
  private iconOf(method: string): Resource {
    if (method === WidgetRoute.ACTION_TOGGLE && this.playing) return $r('sys.symbol.pause_fill');
    if (method === WidgetRoute.ACTION_PREV) return $r('sys.symbol.backward_end_fill');
    if (method === WidgetRoute.ACTION_NEXT) return $r('sys.symbol.forward_end_fill');
    return $r('sys.symbol.play_fill');
  }

  @Builder
  symbolButton(size: number, method: string) {
    Row() {
      SymbolGlyph(this.iconOf(method))
        .fontSize(size)
        .fontColor([this.textColor()])
    }
    .width(size + 14)
    .height(size + 10)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.call(method))
  }

  /// 压在封面上的圆底键(2×2 那一档用;字号 18 / 圆底 30)。
  @Builder
  filledButton(size: number, dim: number, method: string) {
    Row() {
      SymbolGlyph(this.iconOf(method))
        .fontSize(size)
        .fontColor([this.onAccent()])
    }
    .width(dim)
    .height(dim)
    .borderRadius(dim / 2)
    .backgroundColor(this.accent())
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.call(method))
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

  /// 点封面 / 文字:**只进播放页,不动播放态**(与应用内"点信息区展开"同一口径)。
  private openPlayer(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { reverbWidget: WidgetRoute.PLAYER }
    });
  }

  /// 播放键:**后台拉起 App 只做这一件事**,不换界面。
  private call(method: string): void {
    postCardAction(this, {
      action: 'call',
      abilityName: 'EntryAbility',
      params: { method: method }
    });
  }
}
