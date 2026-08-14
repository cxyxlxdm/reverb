import { Scheme, TypeScale, Metrics, withAlpha, ACCENTS, AccentPalette, Theme } from '../theme/Theme';
import { L } from '../util/L';
import { REGIONS, RegionOption, regionLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { SettingsStore } from '../store/SettingsStore';
import { TopBar } from './Widgets';
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

  constructor(title: string, options: string[], selected: number, onPick: (i: number) => void) {
    this.title = title;
    this.options = options;
    this.selected = selected;
    this.onPick = onPick;
  }
}

/// 精简设置:外观(主题/配色/字号)、内容(地区)、播放(默认倍速/快退快进)。
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

  @State hint: string = '';
  /// 正在进行的「选一项」;null = 无。
  @State picker: PickerSpec | null = null;

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
        Column({ space: 4 }) {
          this.sectionLabel(L.s('sec_appearance'))
          this.choiceRow(L.s('set_theme'), this.themeLabels(), () => this.settings.themeMode,
            (i: number) => { this.settings.setThemeMode(i); this.onChanged(); })
          this.accentRow()
          this.choiceRow(L.s('set_font'), this.fontLabels(), () => this.settings.fontIndex,
            (i: number) => { this.settings.setFontIndex(i); this.onChanged(); })

          this.choiceRow(L.s('set_language'), this.langLabels(), () => this.langIndex(),
            (i: number) => { this.settings.setLanguage(this.langCodes[i]); this.onChanged(); })

          this.sectionLabel(L.s('sec_content'))
          this.choiceRow(L.s('set_region'), REGIONS.map((r: RegionOption) => regionLabel(r)),
            () => this.regionIndex(),
            (i: number) => { this.settings.setRegionOverride(REGIONS[i].code); this.onChanged(); })

          this.choiceRow(L.s('set_radio_mode'), [L.s('radio_random'), L.s('radio_contextual')],
            () => this.settings.contextualRadio ? 1 : 0,
            (i: number) => { this.settings.setContextualRadio(i === 1); this.onChanged(); })

          this.sectionLabel(L.s('sec_playback'))
          this.choiceRow(L.s('set_default_speed'), this.speeds.map((s: number) => `${s}×`),
            () => this.speedIndex(),
            (i: number) => { this.settings.setDefaultSpeed(this.speeds[i]); this.onChanged(); })
          this.choiceRow(L.s('set_skip_back'), this.skipBackOpts.map((s: number) => L.f('sec_n', s)),
            () => this.optIndex(this.skipBackOpts, this.settings.skipBackSec),
            (i: number) => { this.settings.setSkipBackSec(this.skipBackOpts[i]); this.onChanged(); })
          this.choiceRow(L.s('set_skip_forward'), this.skipFwdOpts.map((s: number) => L.f('sec_n', s)),
            () => this.optIndex(this.skipFwdOpts, this.settings.skipForwardSec),
            (i: number) => { this.settings.setSkipForwardSec(this.skipFwdOpts[i]); this.onChanged(); })

          this.sectionLabel(L.s('sec_backup'))
          this.actionRow(L.s('backup_export'), () => this.exportBackup())
          this.actionRow(L.s('backup_import'), () => this.importBackup())
          this.actionRow(L.s('opml_export'), () => this.exportOpml())
          this.actionRow(L.s('opml_import'), () => this.importOpml())

          this.sectionLabel(L.s('sec_other'))
          this.choiceRow(L.s('set_updates'), [L.s('off'), L.s('on')],
            () => this.settings.updatesEnabled ? 1 : 0,
            (i: number) => { this.toggleUpdates(i === 1); })
          this.actionRow(L.s('update_check_now'), () => this.checkUpdates())
          this.actionRow(L.s('log_export'), () => this.exportLog())
          this.actionRow(L.s('action_about'), () => this.onOpenAbout())

          if (this.hint.length > 0) {
            Text(this.hint)
              .fontSize(TypeScale.caption * this.fontScale)
              .fontColor(this.scheme.primary)
              .padding({ left: Metrics.pagePadding, top: 10 })
          }

          Text(L.f('about_line', '1.0.0'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .margin({ top: 24, bottom: 24 })
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

  @Builder
  sectionLabel(text: string) {
    Text(text)
      .fontSize(TypeScale.caption * this.fontScale)
      .fontColor(this.scheme.secondary)
      .padding({ left: Metrics.pagePadding, top: 18, bottom: 6 })
  }

  /// 一行设置:标题 + 当前值 + 下拉菜单选择。
  /// 注意:当前值用**闭包**取而不是值参数 —— ArkUI 的 @Builder 值参数是一次性的,
  /// 状态变化后不会重新求值,会导致改了设置但显示的值不变。
  @Builder
  choiceRow(title: string, options: string[], selectedOf: () => number, onPick: (i: number) => void) {
    Row() {
      Text(title)
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .layoutWeight(1)
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

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /// 一行「点了就干活」的操作(备份/日志/关于)。
  @Builder
  actionRow(title: string, action: () => void) {
    Row() {
      Text(title)
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .layoutWeight(1)
      Image($r('sys.media.ohos_ic_public_play_next'))
        .width(16).height(16)
        .fillColor(this.scheme.onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 14, bottom: 14 })
    .onClick(action)
  }

  private async exportBackup(): Promise<void> {
    const json = BackupManager.build(this.app, ALL_SECTIONS);
    const ok = await Files.saveText(this.ctx(), 'reverb-backup.json', json);
    this.hint = ok ? L.s('backup_done') : L.s('backup_failed');
  }

  private async importBackup(): Promise<void> {
    const text = await Files.pickText(this.ctx());
    if (text === null) {
      this.hint = L.s('backup_failed');
      return;
    }
    const found = BackupManager.sectionsIn(text);
    if (found.length === 0) {
      this.hint = L.s('backup_failed');
      return;
    }
    BackupManager.apply(this.app, text, found);
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
      const ok = await UpdateNotifier.requestAuth(this.ctx());
      if (!ok) {
        this.hint = L.s('backup_failed');
        return;
      }
      UpdateNotifier.schedule();
    } else {
      UpdateNotifier.cancel();
    }
    this.settings.setUpdatesEnabled(on);
    this.onChanged();
  }

  private async checkUpdates(): Promise<void> {
    const n = await UpdateNotifier.checkNow(this.app.subscriptions.subscriptions, this.app.repository);
    this.hint = n > 0 ? L.f('update_found', n) : L.s('update_none');
  }

  private async exportLog(): Promise<void> {
    const ok = await Files.saveText(this.ctx(), 'reverb-log.txt', Log.dump());
    this.hint = ok ? L.s('log_done') : L.s('backup_failed');
  }

  private valueLabel(options: string[], selected: number): string {
    return selected >= 0 && selected < options.length ? options[selected] : '';
  }

  /// 配色:四个圆形色块直选。
  @Builder
  accentRow() {
    Row() {
      Text(L.s('set_accent'))
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .layoutWeight(1)
      Row({ space: 10 }) {
        ForEach(ACCENTS, (a: AccentPalette, idx: number) => {
          Stack() {
            // 选中环同样用 border 画(理由见 radio():Circle().stroke() 会被裁掉外侧半宽)
            if (this.settings.accentIndex === idx) {
              Column()
                .width(34).height(34)
                .borderRadius(17)
                .borderWidth(1.5)
                .borderColor(this.scheme.onBackground)
            }
            Circle()
              .width(26).height(26)
              .fill(this.scheme.isDark ? a.primaryDark : a.primaryLight)
          }
          .width(34).height(34)
          .onClick(() => {
            this.settings.setAccentIndex(idx);
            this.onChanged();
          })
        }, (a: AccentPalette, idx: number) => `${idx}`)
      }
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}
