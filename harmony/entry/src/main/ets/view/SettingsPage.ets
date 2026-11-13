import { Scheme, TypeScale, Metrics, withAlpha, ACCENTS, AccentPalette, Theme } from '../theme/Theme';
import { L } from '../util/L';
import { appVersionName } from '../util/AppInfo';
import { Features } from '../Features';
import { REGIONS, RegionOption, regionLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { SettingsStore } from '../store/SettingsStore';
import { TopBar } from './Widgets';
import { ConfirmDialog, ConfirmSpec } from './Components';
import { BackupManager, ALL_SECTIONS, BackupSection, sectionLabelKey } from '../store/BackupManager';
import { UpdateNotifier } from '../update/UpdateNotifier';
import { Files } from '../util/Files';
import { formatDecimal } from '../util/NumberFmt';
import { Log } from '../util/Logger';
import deviceInfo from '@ohos.deviceInfo';
import type common from '@ohos.app.ability.common';

/// 开发者邮箱。**与 Android 是同一个地址**(Android 那份写在 `SettingsScreen.kt` 的
/// `mailLog()` 里,`EXTRA_EMAIL`)。本端必须把它显示出来:ShareKit 的 `SharedRecord`
/// 没有收件人字段,面板也不接受"定向到邮件应用"的参数 ⇒ 预填这一步在本端不存在,
/// 地址只能写在行副标题上,由用户自己填进邮件应用。
const DEV_EMAIL = 'woooxooom@gmail.com';

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

/// 一次「勾选数据分区」的请求(导出与恢复共用一个框)。null = 没在勾。
///
/// 对应 Android 的 `BackupSectionDialog`:标题 + 每区一个复选框 + 取消 + 一个动作按钮
/// (导出那侧按钮写「备份」、恢复那侧写「恢复」),**一个都不勾时动作按钮不可点**。
///
/// 本对象只描述「要勾什么」,**不保存勾选状态** —— 勾选状态归对话框自己的 `@State`。
/// 理由见 `BackupSectionDialog` 的注释:@Builder 的值参数是一次性的,把可变状态放在
/// 页面 `@State` 的 spec 里会让勾打上而界面不动。
class BackupSpec {
  title: string = '';
  confirmText: string = '';
  sections: BackupSection[] = [];
  /// 与 sections 同长的显示名(在构造时算一次;`sectionLabelKey` 用的是专键 `backup_row_*`,
  /// 逐字对齐 Android,见 BackupManager 里那段注释)。
  labels: string[] = [];
  onConfirm: (picked: BackupSection[]) => void = () => {};

  constructor(title: string, confirmText: string, sections: BackupSection[],
              onConfirm: (picked: BackupSection[]) => void) {
    this.title = title;
    this.confirmText = confirmText;
    this.sections = sections;
    this.onConfirm = onConfirm;
    const out: string[] = [];
    for (let i = 0; i < sections.length; i++) {
      out.push(L.s(sectionLabelKey(sections[i])));
    }
    this.labels = out;
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
  /// 正在勾选分区的备份/恢复对话框;null = 无。
  @State backup: BackupSpec | null = null;
  /// 缓存/下载/日志占用。-1 表示还在算(与 Android 的 size_calculating 一致)。
  @State cacheBytes: number = -1;
  @State dlBytes: number = -1;
  @State logBytes: number = -1;

  private app: AppContainer = AppContainer.get();
  private themeLabels(): string[] { return [L.s('theme_system'), L.s('theme_light'), L.s('theme_dark'), L.s('theme_white')]; }
  private fontLabels(): string[] { return [L.s('font_small'), L.s('font_standard'), L.s('font_large'), L.s('font_xlarge')]; }
  /// 语言:值与 resources 下的 locale 目录对应("" = 跟随系统)
  // 与 Android `SettingsScreen.kt` 的 `LANG_TAGS` **逐项同序同值**("" = 跟随系统)。
  // 原先本端是 zh-Hans / zh-Hant,而备份里的 `language` 是跨端契约键 —— 见 SettingsStore.langTag。
  private langCodes: string[] = ['', 'zh-CN', 'zh-TW', 'en', 'fr', 'es'];
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
          this.choiceRow(L.s('set_default_speed'), () => '',
            this.speeds.map((s: number) => `${formatDecimal(s)}×`),
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
          // 1.0.8 起 `Features.LOCAL_ASR` 为 `true`(sherpa-onnx),所以这一行现在会显示;
          // 常量仍是门:降到 `false` 时隐藏,而不是摆一个开了也不变的开关(同 Android 的降级档)。
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
          this.actionRow(L.s('set_full_backup'), () => L.s('set_full_backup_sub'), () => this.openExportDialog())
          this.actionRow(L.s('set_restore'), () => L.s('set_restore_sub'), () => this.startRestore())

          this.sectionLabel(L.s('set_logs'))
          this.actionRow(L.s('set_share_log'), () => L.s('set_share_log_sub'), () => this.shareLog())
          this.actionRow(L.s('set_mail_log'), () => L.s('set_mail_log_sub'), () => this.mailLog())
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
      // 分区勾选框:同理只在 null → 非 null 时新建。框打开期间的勾选状态归它自己的 @State,
      // 所以这里**不需要**在勾选变化时重建(见 BackupSectionDialog 的注释)。
      if (this.backup !== null) {
        BackupSectionDialog({
          scheme: this.scheme,
          fontScale: this.fontScale,
          spec: this.backup,
          onDismiss: () => { this.backup = null; }
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
  ///
  /// **`onChange` 里那道「值没变就不做事」是必需的,不是防御性代码**:ArkUI 的 Toggle
  /// 在**程序化**改 `isOn` 时同样回调 onChange(用户手指与代码赋值分不出来),于是
  /// 「恢复一份备份」或「授权失败把值写回去」都会连带跑一遍这个开关的副作用 ——
  /// 实测的后果是恢复完成后 42ms 弹出系统通知授权框,答「不允许」又把刚恢复的值改回原样
  /// (见 H153)。判据用 `v === onOf()`:**手指按下时 store 还是旧值**,所以两者不等;
  /// **程序化赋值时 store 已经是新值**(就是它触发的这次重渲),所以两者相等。
  /// Android 侧的 Compose `Switch(checked=…)` 没有这个坑(赋值不回调),不需要对应改动。
  @Builder
  switchRow(title: string, subOf: () => string, onOf: () => boolean, onChange: (v: boolean) => void) {
    Row() {
      this.rowText(title, subOf)
      Toggle({ type: ToggleType.Switch, isOn: onOf() })
        .selectedColor(this.scheme.primary)
        .onChange((v: boolean) => {
          if (v === onOf()) return;
          onChange(v);
        })
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
    // 音频缓存与封面缓存各算各的目录,和"下载"那格**没有交集**(那边只数 downloads 目录)。
    // 这条分界是产品口径:缓存是可重生成的临时物,下载是用户显式要留的,清一个不能伤另一个。
    const audio = await this.app.audioCache.usageBytes();
    const artwork = this.app.artwork.usageBytes();
    this.cacheBytes = popular + feeds + transcripts + audio + artwork;
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
    // 音频缓存与封面缓存:两个目录都在 `clearAll()` 里自己作废内存表,
    // 所以清完之后界面不会还拿着一把指向已删文件的本地 uri(封面的那一层另有回落,见 Widgets)。
    // **不碰 downloadManager** —— 下载是用户显式要留的,和缓存不是一条口径(见 recomputeSizes)。
    // 这两个 clearAll 是异步删文件,**必须等它们回来再重算**:否则这一格显示的是"还没删完"的
    // 字节数,用户看到的就是"按了没归零",与没清一样。
    Promise.all([this.app.audioCache.clearAll(), this.app.artwork.clearAll()])
      .then((): void => { this.recomputeSizes(); });
    Log.i('Settings', '已清除热门榜、频道缓存、逐字稿、音频缓存与封面缓存');
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

  /**
   * 「分享日志」= 把日志落成 `reverb-log.txt` 交给系统分享面板。
   * 与 Android 的 `shareLog()` 同口径(那边是 `cacheDir/shares/reverb-log.txt` + `EXTRA_STREAM`),
   * 标题「Reverb log」也照搬。
   *
   * 失败提示用 `log_send_failed`(「日志发送失败」),不用 `backup_failed`(本端值是「操作未完成」,
   * 太泛;Android 侧那个键更不能复用,见那边注释)。H142 判据 ④:两端在这一格必须出声,
   * 而且文案口径一致 —— Android 原先失败是静默的,补的是**缺的那一侧**,不是把这边改成静默。
   */
  private async shareLog(): Promise<void> {
    const ok = await Files.shareText(this.ctx(), 'Reverb log', 'reverb-log.txt', Log.dump(), '');
    if (!ok) this.hint = L.s('log_send_failed');
  }

  /**
   * 「发送日志到开发者邮箱」= **同一个文件**,只是标题/正文换成邮件的形状
   * (对应 Android 的 `EXTRA_SUBJECT` + `EXTRA_TEXT`,那两个字符串在 Android 侧也没本地化)。
   *
   * 与本端「分享日志」的**真实差别**只有一层:Android 用 `type = "message/rfc822"` 把目标
   * 收敛到邮件应用,并预填收件人;本端做不到这两件(见 `DEV_EMAIL` 上方那段)。
   * 所以这一行的价值是**把主题、版本信息、收件人地址一起递到用户眼前**,
   * 而不是"点一下就发出去了" —— 副标题必须把这件事讲清楚,否则界面就在说谎(#89 同族)。
   * 失败提示与 `shareLog` 同一口径。
   */
  private async mailLog(): Promise<void> {
    const body = `请描述你遇到的问题:\n\n\n——\n余音 HarmonyOS v${appVersionName()} · ${deviceInfo.osFullName}`;
    const ok = await Files.shareText(this.ctx(), '余音 HarmonyOS 日志反馈', 'reverb-log.txt', Log.dump(), body);
    if (!ok) this.hint = L.s('log_send_failed');
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

  /**
   * 「完整备份」这一行的动作:**先弹框勾分区**,勾完确认才走保存。
   *
   * 与 Android 同序(`SettingsScreen.kt` 的「完整备份」行点下去只把 `backupExportOpen` 置 true,
   * 对话框的 onConfirm 里才 `backupExportLauncher.launch(...)`)。
   * 顺序是有意为之:选了保存位置再问要备份什么,等于让用户在文件管理器里走一趟回来还没写完。
   */
  private openExportDialog(): void {
    this.backup = new BackupSpec(L.s('backup_export_title'), L.s('backup_confirm'),
      ALL_SECTIONS.slice(), (picked: BackupSection[]) => { this.runExportBackup(picked); });
  }

  private async runExportBackup(include: BackupSection[]): Promise<void> {
    const json = await BackupManager.build(this.app, include);
    const r = await Files.saveText(this.ctx(), 'reverb-backup.json', json);
    // 取消 = 静默。原先 boolean 把取消折进「操作未完成」,用户只是按了取消却被告知失败。
    if (r.cancelled) return;
    this.hint = r.ok ? L.s('backup_done') : L.s('backup_failed');
  }

  /**
   * 「从备份恢复」:**先选文件 → 探测文件里有哪些分区 → 再弹框让用户勾**。
   *
   * 探测必须在勾选之前:可选集只有「文件里真的有的」那几项(Android 同做法 ——
   * `sectionsIn(text)` 出来空集就直接报 `backup_invalid`,非空才把对话框的 available
   * 限制成这个集合)。列一个文件里没有的分区,勾了等于勾一个空操作。
   */
  private async startRestore(): Promise<void> {
    const picked = await Files.pickText(this.ctx());
    // 用户取消 = 什么都不提示。原先这里落进 backup_failed,于是「按了取消」和「文件读不出来」
    // 是同一句话;Android 的 OpenDocument 回调里 uri == null 是静默的,现在两端一致。
    if (picked.cancelled) return;
    // 解析一次,探测与应用共用同一份 root(原先是把同一个大 JSON 解析两遍)
    const root = await BackupManager.parseRoot(picked.text);
    const found = BackupManager.sectionsInRoot(root);
    if (found.length === 0) {
      this.hint = L.s('backup_invalid');
      return;
    }
    this.backup = new BackupSpec(L.s('backup_restore_title'), L.s('restore_confirm'),
      found.slice(), (sel: BackupSection[]) => { this.runRestore(root, sel); });
  }

  private runRestore(root: Record<string, Object> | null, include: BackupSection[]): void {
    /**
     * 恢复 settings 分区之后必须**按新值重排订阅更新的周期任务**。
     *
     * 原先这里把返回值直接丢了(`applyRoot` 是同步返回 boolean 的,调用侧却不接),
     * 于是"备份里开着更新提醒、本机没开"这一种情况:设置页的 Toggle 会显示成开,
     * 而 workScheduler 里**压根没有那个任务** —— 界面承诺了一件不会发生的事。
     * 反向也一样(备份里关着、本机开着 → 恢复了还在偷偷检查并发通知)。
     *
     * 判据与 Android `SettingsScreen.kt` 恢复段(`if (importedSettings) { schedule / cancel }`)
     * 同构:仅在真恢复了 settings 分区时,按 `updatesEnabled` 的新值 schedule / cancel。
     * 加了勾选框之后这条更要紧 —— 用户完全可以只勾订阅不勾设置,那时就不该动任务。
     *
     * ⚠️ 与 Android 共有的一条窄窗口(不是本端独有,所以这里不单方面改):
     * 恢复路径**不重新索取通知授权**。若那份备份来自另一台机器,本机可能从未授予通知权限,
     * 于是任务排上了而通知发不出去。两端一致 ⇒ 不算漂移;要修得两端一起修。
     *
     * 2026-10-07 真机补记:上面这句**曾经是不成立的** —— 恢复把 `updatesEnabled` 从关改到开,
     * 会让设置页那颗 Toggle 以"程序化赋值"的形态回调 onChange,连带走一遍用户路径上的
     * `requestAuth`,于是「恢复完成」之后 42ms 弹出系统通知授权框(见 H153)。
     * 现在 `switchRow` 挡住了程序化回调,这句才真的成立。
     * 另外这里 schedule() 撞上"任务已在册"(用户本来就开着提醒)会打一行「已在册,无需重复注册」,
     * 不是失败 —— 见 UpdateNotifier.schedule 的注释。
     */
    if (BackupManager.applyRoot(this.app, root, include)) {
      if (this.settings.updatesEnabled) UpdateNotifier.schedule();
      else UpdateNotifier.cancel();
    }
    this.hint = L.s('backup_restored');
    this.onChanged();
  }

  private async exportOpml(): Promise<void> {
    const r = await Files.saveText(this.ctx(), 'reverb-subscriptions.opml', BackupManager.exportOpml(this.app));
    if (r.cancelled) return;
    this.hint = r.ok ? L.s('backup_done') : L.s('backup_failed');
  }

  private async importOpml(): Promise<void> {
    const picked = await Files.pickText(this.ctx());
    // 取消不提示(与恢复那条同口径;Android 的 OPML 导入回调里 uri == null 同样什么都不做)
    if (picked.cancelled) return;
    const n = await BackupManager.importOpml(this.app, picked.text);
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
    const r = await Files.saveText(this.ctx(), 'reverb-log.txt', Log.dump());
    if (r.cancelled) return;
    // 失败用 `saved_fail`(「保存失败」)而不是 `backup_failed`(本端值是「操作未完成」):
    // 这一行不在备份段里,与 Android 的 `logExportLauncher` 同一口径(见那边注释)。
    this.hint = r.ok ? L.s('log_done') : L.s('saved_fail');
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

/**
 * 分区勾选框(Android `BackupSectionDialog` 的同构体)。
 *
 * **为什么是独立子组件,不是又一个 @Builder**:
 * 页面里那两个框(`pickerDialog` / `ConfirmDialog`)都只在「null → 非 null」那一次被创建,
 * 之后立刻消失,所以值参数一次性没问题。这个框不同 —— 打开期间要连点 8 次复选框。
 * 如果把勾选状态挂在页面的 `@State backup: BackupSpec` 上(每次翻转换一份新 spec),
 * 外层 `if (this.backup !== null)` 的分支从头到尾没变 ⇒ 子树不重建 ⇒
 * `@Builder` 拿到的还是旧 spec,**勾打上而界面不动**(H6/H19/H27/H139 同一族)。
 * 状态收进子组件自己的 `@State` 才是那个能刷新的形状,顺带满足硬规矩 7
 * (只重建这一个框,不重建整页)。
 *
 * **勾选状态用位图而不用 `boolean[]`**:标量的整值赋值是 V1 观察里最没有争议的一档,
 * 数组元素赋值要另靠「整份替换」才稳(H77)。8 个分区正好一个字节,读起来也不绕。
 */
@Component
struct BackupSectionDialog {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 只在 null → 非 null 时随组件新建而来,所以是普通成员(与 ConfirmDialog 同口径)。
  spec: BackupSpec = new BackupSpec('', '', [], (p: BackupSection[]) => {});
  onDismiss: () => void = () => {};
  /// 第 i 位 = 第 i 个分区勾没勾。初值在 aboutToAppear 里给(默认**全选**,与 Android 同)。
  @State bits: number = 0;

  aboutToAppear(): void {
    // 全选:Android 侧导出是 `Section.entries.toSet()`、恢复是 `backupImportSel = avail`,
    // 两处都是「打开即全勾,勾掉是例外」。这样默认路径与没有对话框时完全等价 —— 老用户的
    // 肌肉记忆(点一下就直接备份全部)不会变味。
    this.bits = (1 << this.spec.sections.length) - 1;
  }

  private isOn(idx: number): boolean {
    return (this.bits & (1 << idx)) !== 0;
  }

  private toggleRow(idx: number): void {
    this.bits = this.bits ^ (1 << idx);
  }

  /// 勾中的分区,**按框里的显示顺序**。
  private pickedSections(): BackupSection[] {
    const src: BackupSection[] = this.spec.sections;
    const out: BackupSection[] = [];
    for (let i = 0; i < src.length; i++) {
      if (this.isOn(i)) out.push(src[i]);
    }
    return out;
  }

  private confirmBackup(): void {
    // 一个都没勾 = 确认没有意义(Android 那边直接 disable 按钮)。这里拦第二道:
    // 视觉上的半透明只表达「不可点」,真正的拦截必须在点击里做。
    if (this.bits === 0) return;
    const sel = this.pickedSections();
    const run = this.spec.onConfirm;
    this.onDismiss();   // 先收框再动手(同 ConfirmDialog:确认后可能有 IO,框挂着像没反应)
    run(sel);
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(withAlpha('#000000', 0.45))
        .onClick(() => { this.onDismiss(); })

      Column() {
        Text(this.spec.title)
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .fontColor(this.scheme.onBackground)
          .margin({ bottom: 16 })
          .alignSelf(ItemAlign.Start)

        Scroll() {
          Column() {
            ForEach(this.spec.labels, (label: string, idx: number) => {
              Row({ space: 14 }) {
                Toggle({ type: ToggleType.Checkbox, isOn: this.isOn(idx) })
                  .selectedColor(this.scheme.primary)
                  // 勾选只由**整行**的 onClick 改。不关掉 Toggle 自己的命中,点圈会被翻两次
                  // (它自己一次、行一次),表现是「点了没反应」—— 与 Components.ets:469 同一条。
                  .hitTestBehavior(HitTestMode.None)
                Text(label)
                  .fontSize(TypeScale.body * this.fontScale)
                  .fontColor(this.scheme.onBackground)
                  .layoutWeight(1)
              }
              .width('100%')
              // 上下各 14 ⇒ 行高约 48vp,与 pickerDialog 同(系统推荐的最小点击区)
              .padding({ top: 14, bottom: 14 })
              .onClick(() => { this.toggleRow(idx); })
            }, (label: string, idx: number) => `${idx}-${label}-${this.isOn(idx) ? 1 : 0}`)
            // key 里带上勾选位:整份状态刷新时这一项的 key 变了 ⇒ 该项必定重建。
            // Toggle 的 isOn 走的是状态依赖,理论上就会更新;加上 key 是第二道保险,
            // 因为「子组件参数不刷新」这一族在本仓库已经踩过三次(H77、H139、H27)。
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: 420 })

        Row({ space: 22 }) {
          Text(L.s('action_cancel'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .onClick(() => { this.onDismiss(); })
          Text(this.spec.confirmText)
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.primary)
            // 无勾选时降到 0.38 —— 用 opacity + confirmBackup 里的守卫,而不是 `.enabled(false)`:
            // 后者对 Text 的 onClick 到底拦不拦,SDK 文档没写死,而这里必须**确定**拦得住
            // (否则会导出一份空备份、或应用零个分区还提示「已恢复」)。
            .opacity(this.bits === 0 ? 0.38 : 1)
            .onClick(() => { this.confirmBackup(); })
        }
        .margin({ top: 8 })
        .alignSelf(ItemAlign.End)
      }
      .width('78%')
      .padding({ left: 22, right: 22, top: 22, bottom: 16 })
      .backgroundColor(this.scheme.surface)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
  }
}
