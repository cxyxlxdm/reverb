import { Scheme, TypeScale, Metrics, withAlpha, ACCENTS, AccentPalette, Theme } from '../theme/Theme';
import { L } from '../util/L';
import { appVersionName } from '../util/AppInfo';
import { Features } from '../Features';
import { REGIONS, RegionOption, regionLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { SettingsStore } from '../store/SettingsStore';
import { TopBar } from './Widgets';
import { ConfirmDialog, ConfirmSpec } from './Components';
import { BackupManager, ALL_SECTIONS } from '../store/BackupManager';
import { UpdateNotifier } from '../update/UpdateNotifier';
import { Files } from '../util/Files';
import { Log } from '../util/Logger';
import type common from '@ohos.app.ability.common';

/// 一次「选一项」的请求。存进 @State 后弹出居中对话框;为 null 表示没在选。
class PickerSpec {
  title: string = '';
  options: string[] = [];
  selected: number = 0;
  onPick: (i: number) => void = () => {};
  /**
   * 每个选项左侧的色点(#RRGGBB),与 options 同长;空数组表示不画。
   * 目前只有「主题配色」用它 —— 光有「青瓷 / 黛蓝 / 绯红 / 竹青」四个名字,
   * 选之前看不出是什么颜色。Android 的 AccentDialog 一直是「单选圈 + 色点 + 名字」。
   */
  swatches: string[] = [];

  constructor(title: string, options: string[], selected: number, onPick: (i: number) => void,
              swatches: string[] = []) {
    this.title = title;
    this.options = options;
    this.selected = selected;
    this.onPick = onPick;
    this.swatches = swatches;
  }
}

/// 一次破坏性操作的二次确认请求(对应 Android ConfirmDialog)。
///
/// 类本体 `ConfirmSpec` 与框体 `ConfirmDialog` 已提到 `Components.ets` —— 用得上确认框的
/// 页面不止这一个(还有音阁 · 下载、频道主页各删一处单集),一份框才长一个样。
/// 这里只留「这一页要确认什么」的四份文案与动作。
function cacheConfirm(page: SettingsPage): ConfirmSpec {
  return new ConfirmSpec(L.s('set_clear_cache'), L.s('confirm_clear_cache'), L.s('action_clear'),
    () => page.doClearCache());
}
function downloadsConfirm(page: SettingsPage): ConfirmSpec {
  return new ConfirmSpec(L.s('set_clear_downloads'), L.s('confirm_clear_downloads'), L.s('action_delete'),
    () => page.doClearDownloads());
}
function historyConfirm(page: SettingsPage): ConfirmSpec {
  return new ConfirmSpec(L.s('set_clear_history'), L.s('confirm_clear_history'), L.s('action_clear_confirm'),
    () => page.doClearHistory());
}
function logConfirm(page: SettingsPage): ConfirmSpec {
  return new ConfirmSpec(L.s('set_clear_log'), L.s('log_clear_confirm'), L.s('action_clear_confirm'),
    () => page.doClearLog());
}

/// 字节数 → 人类可读。与 Android `human()` 同档位(B / KB / MB 一位小数 / GB 两位)。
function humanBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${Math.round(kb)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(1)} MB`;
  return `${(mb / 1024).toFixed(2)} GB`;
}

/// 设置页。分区与条目对齐 Android `SettingsScreen.kt`。
@Component
export struct SettingsPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /**
   * 设置对象本体,由外层以 @State 持有后传入。
   *
   * 必须是 `@ObjectLink`(SettingsStore 已 `@Observed`),不能图省事在页内写
   * `private app.settings` 直接读:那样读到的是**未被观察**的裸对象,改了字段本页不会重渲。
   * 曾经的表现是「配色点了没反应」——值其实已改并落盘,只是界面不动;而主题/字号看着正常,
   * 纯属**偶然**:它们走对话框,关闭时 `@State picker` 变化顺带触发了本页重渲。
   * 配色行没有任何本地状态变化,于是原地不动。详见 H26。
   */
  @ObjectLink settings: SettingsStore;
  onBack: () => void = () => {};
  /// 设置变更后通知外层重渲(主题/字号即时生效)
  onChanged: () => void = () => {};
  onOpenAbout: () => void = () => {};
  onOpenLicenses: () => void = () => {};
  onOpenFootprint: () => void = () => {};

  @State hint: string = '';
  /// 正在进行的「选一项」;null = 无。
  @State picker: PickerSpec | null = null;
  /// 正在确认的破坏性操作;null = 无。
  @State confirm: ConfirmSpec | null = null;
  /// 缓存/下载/日志占用。-1 表示还在算(与 Android 的 size_calculating 一致)。
  @State cacheBytes: number = -1;
  @State dlBytes: number = -1;
  @State logBytes: number = -1;

  private app: AppContainer = AppContainer.get();
  private themeLabels(): string[] { return [L.s('theme_system'), L.s('theme_light'), L.s('theme_dark'), L.s('theme_white')]; }
  private fontLabels(): string[] { return [L.s('font_small'), L.s('font_standard'), L.s('font_large'), L.s('font_xlarge')]; }
  /// 语言:值与 resources 下的 locale 目录对应("" = 跟随系统)
  private langCodes: string[] = ['', 'zh-Hans', 'zh-Hant', 'en', 'fr', 'es'];
  private langLabels(): string[] { return [L.s('theme_system'), '简体中文', '繁體中文', 'English', 'Français', 'Español']; }
  private speeds: number[] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0];
  private skipBackOpts: number[] = [5, 10, 15, 30];
  private skipFwdOpts: number[] = [15, 30, 45, 60];

  build() {
    Stack() {
      Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: L.s('settings_title'), onBack: () => this.onBack()
      })
      Scroll() {
        // 分区顺序与 Android `SettingsScreen.kt` 逐段一致:
        // 内容 → 外观 → 播放 → 提醒 → 存储 → 备份 → 日志 → 关于。
        // (原先是 外观 → 内容 → 播放 → 备份 → 其他,自成一套。)
        Column({ space: 0 }) {
          this.sectionLabel(L.s('sec_content'))
          // 「地区」只作用于分类榜单、关键词检索与电台的取材范围;
          // 与电台模式一起受 CATALOG 门控,合规要求降级时两项会同步隐藏。
          if (Features.CATALOG) {
            this.choiceRow(L.s('set_region'), () => '', REGIONS.map((r: RegionOption) => regionLabel(r)),
              () => this.regionIndex(),
              (i: number) => { this.settings.setRegionOverride(REGIONS[i].code); this.onChanged(); })
          }
          // 听觉足迹:Android 也是放在这一段的一条,不在音阁页头
          this.actionRow(L.s('set_footprint'), () => L.s('set_footprint_sub'), () => this.onOpenFootprint())
          if (Features.CATALOG) {
            this.choiceRow(L.s('set_radio_mode'), () => '', [L.s('radio_random'), L.s('radio_contextual')],
              () => this.settings.contextualRadio ? 1 : 0,
              (i: number) => { this.settings.setContextualRadio(i === 1); this.onChanged(); })
          }

          this.sectionLabel(L.s('sec_appearance'))
          this.choiceRow(L.s('set_theme'), () => '', this.themeLabels(), () => this.settings.themeMode,
            (i: number) => { this.settings.setThemeMode(i); this.onChanged(); })
          this.choiceRow(L.s('set_font'), () => '', this.fontLabels(), () => this.settings.fontIndex,
            (i: number) => { this.settings.setFontIndex(i); this.onChanged(); })
          this.accentRow()
          this.choiceRow(L.s('set_language'), () => '', this.langLabels(), () => this.langIndex(),
            (i: number) => { this.settings.setLanguage(this.langCodes[i]); this.onChanged(); })
          // 真实频谱:鸿蒙**没有**这一项。Android 靠 Visualizer(0) 抓系统输出混音,
          // 鸿蒙的 SOURCE_TYPE_PLAYBACK_CAPTURE 自 API 12 废弃、改用需录屏授权的
          // OH_AVScreenCapture,为一个封面动效索取录屏权限不成比例。详见 TROUBLESHOOTING。

          this.sectionLabel(L.s('sec_playback'))
          // 选定默认倍速**同时作用到当前这一集**:Android 在 Dlg.SPEED 的 onPick 里连着调
          // `PlayerController.setSpeed`,本端原先只写设置,于是"改了要等下一集才见效"。
          // 鸿蒙侧 `setSpeed` 只在 playing 时下发速率(AVPlayer 的限制,见 PlayerController
          // 的 applyRate 注释),暂停态改的是待用的 `speed` 字段,恢复播放时补上。
          this.choiceRow(L.s('set_default_speed'), () => '', this.speeds.map((s: number) => `${s}×`),
            () => this.speedIndex(),
            (i: number) => {
              this.settings.setDefaultSpeed(this.speeds[i]);
              this.app.player.setSpeed(this.speeds[i]);
              this.onChanged();
            })
          this.choiceRow(L.s('set_skip_back'), () => '', this.skipBackOpts.map((s: number) => L.f('unit_seconds', s)),
            () => this.optIndex(this.skipBackOpts, this.settings.skipBackSec),
            (i: number) => { this.settings.setSkipBackSec(this.skipBackOpts[i]); this.onChanged(); })
          this.choiceRow(L.s('set_skip_forward'), () => '', this.skipFwdOpts.map((s: number) => L.f('unit_seconds', s)),
            () => this.optIndex(this.skipFwdOpts, this.settings.skipForwardSec),
            (i: number) => { this.settings.setSkipForwardSec(this.skipFwdOpts[i]); this.onChanged(); })
          this.switchRow(L.s('set_wifi_only'), () => L.s('set_wifi_only_sub'),
            () => !this.settings.allowCellular,
            (on: boolean) => { this.settings.setAllowCellular(!on); })
          // 「逐字稿」总开关**只在有本机识别时才有意义**:那时它决定"任何一集都能转"。
          // 本端 LOCAL_ASR = false,第三页仅在该集有官方稿时出现 —— 没有可开关的东西,
          // 摆一个开了也不变的开关只会让人困惑(与 Android 大陆商店渠道同样不显示)。
          if (Features.LOCAL_ASR) {
            this.switchRow(L.s('set_transcription'), () => L.s('set_transcription_sub'),
              () => this.settings.transcriptionEnabled,
              (on: boolean) => { this.settings.setTranscriptionEnabled(on); })
          }
          // 逐字高亮**保留**:官方的 JSON 稿一词一条、自带词级时间,那个效果是真的
          this.switchRow(L.s('set_word_highlight'), () => L.s('set_word_highlight_sub'),
            () => this.settings.wordHighlight,
            (on: boolean) => { this.settings.setWordHighlight(on); })

          this.sectionLabel(L.s('sec_reminder'))
          this.switchRow(L.s('set_updates'), () => L.s('set_updates_sub'),
            () => this.settings.updatesEnabled,
            (on: boolean) => { this.toggleUpdates(on); })
          // 这里原先还有一行「立即检查更新」。删掉的理由:它做的事(遍历订阅拉 feed、
          // 有新集就发系统通知)在前台**完全被「音阁 · 最新」的下拉刷新覆盖** ——
          // 下拉刷新本来就会把所有订阅拉一遍并把新集直接列出来,比"弹个通知"直观;
          // 而后台那份检查由 workScheduler 的 FeedUpdateExtension 自己在跑(仍走
          // UpdateNotifier.checkNow,方法保留)。留着这行只是多一个没有进度指示、
          // 会在前台弹通知的慢操作,Android 侧也一直没有它。

          this.sectionLabel(L.s('sec_storage'))
          this.actionRow(L.s('set_clear_cache'), () => L.f('set_clear_cache_sub', this.cacheStr()),
            () => { this.confirm = cacheConfirm(this); })
          this.actionRow(L.s('set_clear_downloads'), () => L.f('set_clear_downloads_sub', this.dlStr()),
            () => { this.confirm = downloadsConfirm(this); })
          this.actionRow(L.s('set_clear_history'), () => '',
            () => { this.confirm = historyConfirm(this); })

          this.sectionLabel(L.s('sec_backup'))
          this.actionRow(L.s('set_export_opml'), () => L.s('set_export_opml_sub'), () => this.exportOpml())
          this.actionRow(L.s('set_import_opml'), () => L.s('set_import_opml_sub'), () => this.importOpml())
          this.actionRow(L.s('set_full_backup'), () => L.s('set_full_backup_sub'), () => this.exportBackup())
          this.actionRow(L.s('set_restore'), () => L.s('set_restore_sub'), () => this.importBackup())

          this.sectionLabel(L.s('set_logs'))
          this.actionRow(L.s('set_share_log'), () => L.s('set_share_log_sub'), () => this.shareLog())
          this.actionRow(L.s('log_export'), () => '', () => this.exportLog())
          this.actionRow(L.s('set_clear_log'), () => L.f('log_size', this.logStr()),
            () => { this.confirm = logConfirm(this); })

          this.sectionLabel(L.s('sec_about'))
          this.actionRow(L.s('set_about'), () => '', () => this.onOpenAbout())
          // 隐私政策必须**在应用内随时可查**,不能只在首启弹一次(平台合规指引)
          this.actionRow(L.s('set_privacy'), () => L.s('set_privacy_sub'), () => this.openPrivacy())
          this.actionRow(L.s('set_licenses'), () => '', () => this.onOpenLicenses())
          this.plainRow(L.s('set_version'), appVersionName())

          if (this.hint.length > 0) {
            Text(this.hint)
              .fontSize(TypeScale.caption * this.fontScale)
              .fontColor(this.scheme.primary)
              .padding({ left: Metrics.pagePadding, top: 10 })
          }
          Row().height(24)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      // 选项对话框:null → 非 null 时整段重建,故值参数拿到的是最新的 spec
      if (this.picker !== null) {
        this.pickerDialog(this.picker)
      }
      if (this.confirm !== null) {
        ConfirmDialog({
          scheme: this.scheme,
          fontScale: this.fontScale,
          spec: this.confirm,
          onDismiss: () => { this.confirm = null; }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /// 居中单选对话框:标题 + 单选列表。点选项即生效并关闭,点遮罩取消。
  ///
  /// 为什么不用挂在行上的下拉菜单:行是满宽的,菜单锚点取行的左边缘 ⇒ 贴着屏幕左侧弹;
  /// 给了 `Placement.BottomRight` 后短列表正常,但**选项一多(地区 12 项)菜单放不下**,
  /// ArkUI 会自动换到别的 placement,相对满宽锚点又被挤回屏幕中间 —— 位置不可控。
  /// 居中对话框没有锚点,长短列表都稳。
  ///
  /// 没有「取消」按钮:选项点了立即生效并关闭,取消的唯一含义就是「什么都不改地关掉」,
  /// 而点遮罩已经是这个语义。多一个只会关窗的按钮既占地方又让人以为要「确定」才生效。
  @Builder
  pickerDialog(spec: PickerSpec) {
    Stack() {
      // 遮罩:点击空白处关闭(即「取消」)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(withAlpha('#000000', 0.45))
        .onClick(() => { this.picker = null; })

      Column() {
        Text(spec.title)
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .fontColor(this.scheme.onBackground)
          .margin({ bottom: 16 })
          .alignSelf(ItemAlign.Start)

        Scroll() {
          Column() {
            ForEach(spec.options, (label: string, idx: number) => {
              Row({ space: 14 }) {
                this.radio(idx === spec.selected)
                // 色点(仅「主题配色」有;见 PickerSpec.swatches)。与 Android 同尺寸同位置:
                // 单选圈之后、名字之前,20 见方的实心圆。
                if (idx < spec.swatches.length) {
                  Circle().width(20).height(20).fill(spec.swatches[idx])
                }
                Text(label)
                  .fontSize(TypeScale.body * this.fontScale)
                  .fontColor(this.scheme.onBackground)
                  .layoutWeight(1)
              }
              .width('100%')
              // 上下各 14 ⇒ 行高约 48vp,正好是系统推荐的最小点击区,也让相邻选项不再挤成一坨
              .padding({ top: 14, bottom: 14 })
              .onClick(() => {
                this.picker = null;
                spec.onPick(idx);
              })
            }, (label: string, idx: number) => `${idx}-${label}`)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: 420 })
      }
      .width('78%')
      .padding({ left: 22, right: 22, top: 22, bottom: 14 })
      .backgroundColor(this.scheme.surface)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
  }

  /// 单选圈。**用 border 画圆环,不要用 `Circle().stroke()`**:
  /// ArkUI 的 shape 描边是「跨路径居中」的,strokeWidth 的外侧半宽会超出组件布局盒并被裁掉,
  /// 表现为圆环左侧(以及上下)被削掉一道直边 —— 正是 H25 的现象。
  /// border 按盒模型画在盒子**内部**,不存在越界,任何线宽都不会被裁。
  @Builder
  radio(on: boolean) {
    Stack() {
      Column()
        .width(20).height(20)
        .borderRadius(10)
        .borderWidth(1.5)
        .borderColor(on ? this.scheme.primary : this.scheme.onSurfaceVariant)
      if (on) {
        Circle().width(10).height(10).fill(this.scheme.primary)
      }
    }
    .width(20).height(20)
  }

  private langIndex(): number {
    const i = this.langCodes.indexOf(this.settings.language);
    return i < 0 ? 0 : i;
  }

  private regionIndex(): number {
    const code = this.settings.regionOverride;
    const i = REGIONS.findIndex((r: RegionOption) => r.code === code);
    return i < 0 ? 0 : i;
  }

  private speedIndex(): number {
    return this.optIndex(this.speeds, this.settings.defaultSpeed);
  }

  private optIndex(opts: number[], value: number): number {
    const i = opts.findIndex((v: number) => Math.abs(v - value) < 0.001);
    return i < 0 ? 0 : i;
  }

  /// 分区标签。颜色用 **primary**(与 Android SectionLabel 一致);原先用 secondary(梁金)。
  @Builder
  sectionLabel(text: string) {
    Text(text)
      .fontSize(TypeScale.caption * this.fontScale)
      .fontColor(this.scheme.primary)
      .padding({ left: Metrics.pagePadding, top: 18, bottom: 2 })
  }

  /**
   * 一行的标题 + 可选副标题(Android 的每个 SettingRow 都可带副标题;鸿蒙原先只有标题)。
   *
   * 副标题**必须一路以闭包传到这里**再求值,`subOf()` 空串即不显示。
   * 踩过两次:第一次把动态副标题当字符串传给 `actionRow`,第二次改成闭包但在 `actionRow` 里
   * 就 `subOf()` 求好值、再把字符串传给本 @Builder —— **等于把一次性值参数往下挪了一层**,
   * 清除缓存后文件都删了,副标题照旧显示旧的 KB 数。`@Builder` 的值参数是一次性的
   * (H6/H19/H27 同一族);闭包之所以有效,是因为它在 builder 体里被调用时才读状态。
   */
  @Builder
  rowText(title: string, subOf: () => string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onBackground)
      if (subOf().length > 0) {
        Text(subOf())
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    // **右边留出间距**:这一栏是 layoutWeight(1),会一路吃到右侧控件的左边缘,
    // 长副标题折行后第二行正好顶在开关/取值上(Android 侧同一处也补了 16)。
    .padding({ right: 16 })
  }

  /// 开关行(Android SettingSwitch)。原先把开关做成「关/开」两项的单选对话框 ——
  /// 两次点击才能切一个布尔值,且看不出这是开关。
  @Builder
  switchRow(title: string, subOf: () => string, onOf: () => boolean, onChange: (v: boolean) => void) {
    Row() {
      this.rowText(title, subOf)
      Toggle({ type: ToggleType.Switch, isOn: onOf() })
        .selectedColor(this.scheme.primary)
        .onChange((v: boolean) => { onChange(v); })
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /// 只展示不可点的一行(版本号)。
  @Builder
  plainRow(title: string, value: string) {
    Row() {
      this.rowText(title, () => '')
      Text(value)
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  /// 一行设置:标题 + 当前值 + 下拉菜单选择。
  /// 注意:当前值用**闭包**取而不是值参数 —— ArkUI 的 @Builder 值参数是一次性的,
  /// 状态变化后不会重新求值,会导致改了设置但显示的值不变。
  @Builder
  choiceRow(title: string, subOf: () => string, options: string[], selectedOf: () => number, onPick: (i: number) => void) {
    Row() {
      this.rowText(title, subOf)
      Text(this.valueLabel(options, selectedOf()))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 14, bottom: 14 })
    .onClick(() => {
      this.picker = new PickerSpec(title, options, selectedOf(), onPick);
    })
  }

  aboutToAppear(): void {
    this.recomputeSizes();
  }

  /**
   * 重算三处占用。进页面时算一次,清理后再算一次(与 Android 的 refreshTick 同思路)。
   *
   * **异步**:这些数字来自 `stat`,而下载与逐字稿都是"一集一个文件",条数一多就是
   * O(N) 次同步 IO 压在首帧上(见 H65)。界面在 `< 0` 时显示「计算中」,
   * 所以异步返回天然有落位。
   */
  private async recomputeSizes(): Promise<void> {
    // 逐字稿也算进"缓存":它可重生成、体积不小(一集几十 KB),而且用户需要一个
    // 能把它清掉的入口 —— 时间轴口径变了时,重转是唯一的自救办法
    this.logBytes = Log.sizeBytes();   // 只读内存环形缓冲,零 IO
    const popular = await this.app.popularCache.sizeBytes();
    const feeds = await this.app.feedCache.sizeBytes();
    const transcripts = await this.app.transcripts.usageBytes();
    this.cacheBytes = popular + feeds + transcripts;
    this.dlBytes = await this.app.downloadManager.usageBytes();
  }

  private cacheStr(): string {
    return this.cacheBytes < 0 ? L.s('size_calculating') : humanBytes(this.cacheBytes);
  }
  private dlStr(): string {
    return this.dlBytes < 0 ? L.s('size_calculating') : humanBytes(this.dlBytes);
  }
  private logStr(): string {
    return this.logBytes < 0 ? L.s('size_calculating') : humanBytes(this.logBytes);
  }

  /// 打开官网的完整隐私政策(隐式 Want 交给系统浏览器)。
  private openPrivacy(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === null || ctx === undefined) return;
      (ctx as ESObject).startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: L.s('privacy_url')
      });
    } catch (e) {
      Log.w('Settings', `打开隐私政策失败 ${(e as Error).message}`);
    }
  }

  /// 破坏性操作的实际执行体。由 ConfirmSpec 在用户确认后调用 —— 故必须是公开方法。
  /// 清理类操作**不再额外弹提示**:反馈就是本行副标题的占用变成 0 B、列表随即清空
  /// (与 Android 一致)。此前把行标题原样赋给 hint,底部就多出一行「清除缓存」,
  /// 除了占地方没有任何信息量。
  doClearCache(): void {
    this.app.popularCache.clear();
    this.app.feedCache.clear();
    this.app.transcripts.clearAll();
    this.recomputeSizes();
    Log.i('Settings', '已清除热门榜、频道缓存与逐字稿');
  }

  doClearDownloads(): void {
    this.app.downloadManager.deleteAll();
    this.recomputeSizes();
    Log.i('Settings', '已清除全部下载');
  }

  doClearHistory(): void {
    this.app.history.clear();
    Log.i('Settings', '已清空播放历史');
  }

  doClearLog(): void {
    Log.clear();
    this.recomputeSizes();
  }

  private async shareLog(): Promise<void> {
    const ok = await Files.shareText(this.ctx(), L.s('set_share_log'), Log.dump());
    if (!ok) this.hint = L.s('backup_failed');
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /**
   * 一行「点了就干活」的操作(备份/日志/关于)。
   *
   * 副标题必须用**闭包**取,不能传字符串:`@Builder` 的值参数是一次性的(H6/H19/H27 同一族),
   * 状态变了不会重算。踩过一次 —— 清除缓存后文件确实删了,可副标题仍显示旧的「257 KB」。
   * 本文件的 `choiceRow` 早就为此把当前值做成 `selectedOf()` 闭包,这里同理。
   *
   * Android 的 SettingRow 没有尾部箭头,这里也去掉 —— 原先用「下一集」图标当箭头,
   * 形状是三角+竖线,并不是右尖括号。
   */
  @Builder
  actionRow(title: string, subOf: () => string, action: () => void) {
    Row() {
      this.rowText(title, subOf)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 14, bottom: 14 })
    .onClick(action)
  }

  private async exportBackup(): Promise<void> {
    const json = await BackupManager.build(this.app, ALL_SECTIONS);
    const ok = await Files.saveText(this.ctx(), 'reverb-backup.json', json);
    this.hint = ok ? L.s('backup_done') : L.s('backup_failed');
  }

  private async importBackup(): Promise<void> {
    const text = await Files.pickText(this.ctx());
    if (text === null) {
      this.hint = L.s('backup_failed');
      return;
    }
    // 解析一次,探测与应用共用同一份 root(原先是把同一个大 JSON 解析两遍)
    const root = await BackupManager.parseRoot(text);
    const found = BackupManager.sectionsInRoot(root);
    if (found.length === 0) {
      this.hint = L.s('backup_failed');
      return;
    }
    BackupManager.applyRoot(this.app, root, found);
    this.hint = L.s('backup_restored');
    this.onChanged();
  }

  private async exportOpml(): Promise<void> {
    const ok = await Files.saveText(this.ctx(), 'reverb-subscriptions.opml', BackupManager.exportOpml(this.app));
    this.hint = ok ? L.s('backup_done') : L.s('backup_failed');
  }

  private async importOpml(): Promise<void> {
    const text = await Files.pickText(this.ctx());
    if (text === null) {
      this.hint = L.s('backup_failed');
      return;
    }
    const n = await BackupManager.importOpml(this.app, text);
    this.hint = L.f('opml_imported', n);
    this.onChanged();
  }

  private async toggleUpdates(on: boolean): Promise<void> {
    if (on) {
      // 先只改内存状态,让拒绝时发生 true → false 的可观察变化并把 Toggle 拉回关闭;
      // 若授权弹窗期间进程退出,持久化值仍保持 false。
      this.settings.updatesEnabled = true;
      const ok = await UpdateNotifier.requestAuth(this.ctx());
      if (!ok) {
        this.settings.setUpdatesEnabled(false);
        this.hint = L.s('notification_permission_denied');
        this.onChanged();
        return;
      }
      UpdateNotifier.schedule();
    } else {
      UpdateNotifier.cancel();
    }
    this.settings.setUpdatesEnabled(on);
    this.onChanged();
  }

  private async exportLog(): Promise<void> {
    const ok = await Files.saveText(this.ctx(), 'reverb-log.txt', Log.dump());
    this.hint = ok ? L.s('log_done') : L.s('backup_failed');
  }

  private valueLabel(options: string[], selected: number): string {
    return selected >= 0 && selected < options.length ? options[selected] : '';
  }

  /// 配色行。与 Android 一致:**标题 + 当前配色名 + 一个色点**,点开选择对话框;
  /// 原先是四个圆点直接排在行里(自成一套),与其它设置项的交互也不统一。
  @Builder
  accentRow() {
    Row({ space: 10 }) {
      this.rowText(L.s('set_accent'), () => '')
      Text(this.accentLabels()[this.accentIndex()])
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
      Circle()
        .width(20).height(20)
        .fill(this.accentColor(this.accentIndex()))
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.picker = new PickerSpec(L.s('dlg_accent_title'), this.accentLabels(), this.accentIndex(),
        (i: number) => { this.settings.setAccentIndex(i); this.onChanged(); },
        // 四个选项各自的色点,取当前明暗下真正会用到的那一支(深色用 primaryDark)
        ACCENTS.map((_a: AccentPalette, i: number) => this.accentColor(i)));
    })
  }

  private accentLabels(): string[] {
    return [L.s('accent_celadon'), L.s('accent_blue'), L.s('accent_red'), L.s('accent_green')];
  }

  private accentIndex(): number {
    const i = this.settings.accentIndex;
    return i >= 0 && i < ACCENTS.length ? i : 0;
  }

  private accentColor(idx: number): string {
    const a: AccentPalette = ACCENTS[idx];
    return this.scheme.isDark ? a.primaryDark : a.primaryLight;
  }
}
