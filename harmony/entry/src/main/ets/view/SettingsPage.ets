import { Scheme, TypeScale, Metrics, withAlpha, ACCENTS, AccentPalette, Theme } from '../theme/Theme';
import { REGIONS, RegionOption } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { TopBar } from './Widgets';

/// 精简设置:外观(主题/配色/字号)、内容(地区)、播放(默认倍速/快退快进)。
/// 首版不含备份恢复/日志/关于(后续轮次)。
@Component
export struct SettingsPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};
  /// 设置变更后通知外层重渲(主题/字号即时生效)
  onChanged: () => void = () => {};

  private app: AppContainer = AppContainer.get();
  private themeLabels: string[] = ['跟随系统', '浅色 · 宣纸', '深色 · 水墨', '纯白'];
  private fontLabels: string[] = ['小', '标准', '大', '特大'];
  private speeds: number[] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0];
  private skipBackOpts: number[] = [5, 10, 15, 30];
  private skipFwdOpts: number[] = [15, 30, 45, 60];

  build() {
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: '设置', onBack: () => this.onBack()
      })
      Scroll() {
        Column({ space: 4 }) {
          this.sectionLabel('外观')
          this.choiceRow('主题', this.themeLabels, () => this.app.settings.themeMode,
            (i: number) => { this.app.settings.setThemeMode(i); this.onChanged(); })
          this.accentRow()
          this.choiceRow('字号', this.fontLabels, () => this.app.settings.fontIndex,
            (i: number) => { this.app.settings.setFontIndex(i); this.onChanged(); })

          this.sectionLabel('内容')
          this.choiceRow('地区', REGIONS.map((r: RegionOption) => r.label),
            () => this.regionIndex(),
            (i: number) => { this.app.settings.setRegionOverride(REGIONS[i].code); this.onChanged(); })

          this.choiceRow('电台模式', ['随机', '情境(按时段)'],
            () => this.app.settings.contextualRadio ? 1 : 0,
            (i: number) => { this.app.settings.setContextualRadio(i === 1); this.onChanged(); })

          this.sectionLabel('播放')
          this.choiceRow('默认倍速', this.speeds.map((s: number) => `${s}×`),
            () => this.speedIndex(),
            (i: number) => { this.app.settings.setDefaultSpeed(this.speeds[i]); this.onChanged(); })
          this.choiceRow('快退', this.skipBackOpts.map((s: number) => `${s} 秒`),
            () => this.optIndex(this.skipBackOpts, this.app.settings.skipBackSec),
            (i: number) => { this.app.settings.setSkipBackSec(this.skipBackOpts[i]); this.onChanged(); })
          this.choiceRow('快进', this.skipFwdOpts.map((s: number) => `${s} 秒`),
            () => this.optIndex(this.skipFwdOpts, this.app.settings.skipForwardSec),
            (i: number) => { this.app.settings.setSkipForwardSec(this.skipFwdOpts[i]); this.onChanged(); })

          Text('余音 Reverb · 鸿蒙端 1.0.0')
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
      Text('配色')
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
