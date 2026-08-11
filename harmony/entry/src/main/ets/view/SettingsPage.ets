import { Scheme, TypeScale, Metrics, withAlpha, ACCENTS, AccentPalette, Theme } from '../theme/Theme';
import { L } from '../util/L';
import { REGIONS, RegionOption, regionLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { TopBar } from './Widgets';
import { BackupManager, ALL_SECTIONS } from '../store/BackupManager';
import { UpdateNotifier } from '../update/UpdateNotifier';
import { Files } from '../util/Files';
import { Log } from '../util/Logger';
import type common from '@ohos.app.ability.common';

/// 精简设置:外观(主题/配色/字号)、内容(地区)、播放(默认倍速/快退快进)。
/// 首版不含备份恢复/日志/关于(后续轮次)。
@Component
export struct SettingsPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};
  /// 设置变更后通知外层重渲(主题/字号即时生效)
  onChanged: () => void = () => {};
  onOpenAbout: () => void = () => {};

  @State hint: string = '';

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
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: L.s('settings_title'), onBack: () => this.onBack()
      })
      Scroll() {
        Column({ space: 4 }) {
          this.sectionLabel(L.s('sec_appearance'))
          this.choiceRow(L.s('set_theme'), this.themeLabels(), () => this.app.settings.themeMode,
            (i: number) => { this.app.settings.setThemeMode(i); this.onChanged(); })
          this.accentRow()
          this.choiceRow(L.s('set_font'), this.fontLabels(), () => this.app.settings.fontIndex,
            (i: number) => { this.app.settings.setFontIndex(i); this.onChanged(); })

          this.choiceRow(L.s('set_language'), this.langLabels(), () => this.langIndex(),
            (i: number) => { this.app.settings.setLanguage(this.langCodes[i]); this.onChanged(); })

          this.sectionLabel(L.s('sec_content'))
          this.choiceRow(L.s('set_region'), REGIONS.map((r: RegionOption) => regionLabel(r)),
            () => this.regionIndex(),
            (i: number) => { this.app.settings.setRegionOverride(REGIONS[i].code); this.onChanged(); })

          this.choiceRow(L.s('set_radio_mode'), [L.s('radio_random'), L.s('radio_contextual')],
            () => this.app.settings.contextualRadio ? 1 : 0,
            (i: number) => { this.app.settings.setContextualRadio(i === 1); this.onChanged(); })

          this.sectionLabel(L.s('sec_playback'))
          this.choiceRow(L.s('set_default_speed'), this.speeds.map((s: number) => `${s}×`),
            () => this.speedIndex(),
            (i: number) => { this.app.settings.setDefaultSpeed(this.speeds[i]); this.onChanged(); })
          this.choiceRow(L.s('set_skip_back'), this.skipBackOpts.map((s: number) => L.f('sec_n', s)),
            () => this.optIndex(this.skipBackOpts, this.app.settings.skipBackSec),
            (i: number) => { this.app.settings.setSkipBackSec(this.skipBackOpts[i]); this.onChanged(); })
          this.choiceRow(L.s('set_skip_forward'), this.skipFwdOpts.map((s: number) => L.f('sec_n', s)),
            () => this.optIndex(this.skipFwdOpts, this.app.settings.skipForwardSec),
            (i: number) => { this.app.settings.setSkipForwardSec(this.skipFwdOpts[i]); this.onChanged(); })

          this.sectionLabel(L.s('sec_backup'))
          this.actionRow(L.s('backup_export'), () => this.exportBackup())
          this.actionRow(L.s('backup_import'), () => this.importBackup())
          this.actionRow(L.s('opml_export'), () => this.exportOpml())
          this.actionRow(L.s('opml_import'), () => this.importOpml())

          this.sectionLabel(L.s('sec_other'))
          this.choiceRow(L.s('set_updates'), [L.s('off'), L.s('on')],
            () => this.app.settings.updatesEnabled ? 1 : 0,
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
  }

  private langIndex(): number {
    const i = this.langCodes.indexOf(this.app.settings.language);
    return i < 0 ? 0 : i;
  }

  private regionIndex(): number {
    const code = this.app.settings.regionOverride;
    const i = REGIONS.findIndex((r: RegionOption) => r.code === code);
    return i < 0 ? 0 : i;
  }

  private speedIndex(): number {
    return this.optIndex(this.speeds, this.app.settings.defaultSpeed);
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
    .bindMenu(this.pickMenu(options, onPick))
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
    this.app.settings.setUpdatesEnabled(on);
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

  @Builder
  pickMenu(options: string[], onPick: (i: number) => void) {
    Menu() {
      ForEach(options, (label: string, idx: number) => {
        MenuItem({ content: label }).onClick(() => onPick(idx))
      }, (label: string, idx: number) => `${idx}-${label}`)
    }
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
            Circle()
              .width(26).height(26)
              .fill(this.scheme.isDark ? a.primaryDark : a.primaryLight)
            if (this.app.settings.accentIndex === idx) {
              Circle()
                .width(34).height(34)
                .fillOpacity(0)
                .stroke(this.scheme.onBackground)
                .strokeWidth(1.5)
            }
          }
          .width(34).height(34)
          .onClick(() => {
            this.app.settings.setAccentIndex(idx);
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
