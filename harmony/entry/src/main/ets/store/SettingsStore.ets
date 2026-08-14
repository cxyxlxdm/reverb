import i18n from '@ohos.i18n';
import { Prefs } from './Prefs';
import { Log } from '../util/Logger';

/// 应用设置。与 Android SettingsStore / macOS SettingsStore 的键位对齐。
/// 用 @Observed 让界面直接观察;每个 setter 立即落盘。
@Observed
export class SettingsStore {
  /// 0 跟随系统 / 1 浅色(宣纸) / 2 深色(水墨) / 3 纯白
  themeMode: number = 0;
  /// ACCENTS 索引:0 青瓷 / 1 黛蓝 / 2 绯红 / 3 竹青
  accentIndex: number = 0;
  /// FONT_SCALES 索引(4 档)
  fontIndex: number = 1;
  /// 界面语言:"" 跟随系统,否则 zh-Hans / zh-Hant / en / fr / es
  language: string = '';
  /// 目录检索地区:"" 自动
  regionOverride: string = '';
  defaultSpeed: number = 1.0;
  skipBackSec: number = 10;
  skipForwardSec: number = 30;
  /// 订阅段是否宫格排布
  subsGrid: boolean = false;
  /// 电台模式:false 随机 / true 情境(按时段选分类)
  contextualRadio: boolean = false;
  /// 订阅更新提醒(周期检查 + 本地通知)
  updatesEnabled: boolean = false;
  /// 是否允许蜂窝网络下载(false = 仅 Wi-Fi)。与 Android allowCellular 同名同义。
  allowCellular: boolean = true;

  load(): void {
    this.themeMode = Prefs.getNumber('theme_mode', 0);
    this.accentIndex = Prefs.getNumber('accent_index', 0);
    this.fontIndex = Prefs.getNumber('font_index', 1);
    this.language = Prefs.getString('app_language', '');
    this.regionOverride = Prefs.getString('region_override', '');
    this.defaultSpeed = Prefs.getNumber('default_speed', 1.0);
    this.skipBackSec = Prefs.getNumber('skip_back', 10);
    this.skipForwardSec = Prefs.getNumber('skip_fwd', 30);
    this.subsGrid = Prefs.getBool('subs_grid', false);
    this.contextualRadio = Prefs.getBool('contextual_radio', false);
    this.updatesEnabled = Prefs.getBool('updates_enabled', false);
    this.allowCellular = Prefs.getBool('allow_cellular', true);
    SettingsStore.applyLanguage(this.language);
    Log.i('Settings', `加载 theme=${this.themeMode} accent=${this.accentIndex} font=${this.fontIndex} region=${this.regionOverride === '' ? 'auto' : this.regionOverride}`);
  }

  setThemeMode(v: number): void {
    this.themeMode = v;
    Prefs.put('theme_mode', v);
  }
  setAccentIndex(v: number): void {
    this.accentIndex = v;
    Prefs.put('accent_index', v);
  }
  setFontIndex(v: number): void {
    this.fontIndex = v;
    Prefs.put('font_index', v);
  }
  /// 语言切换后由入口 Ability 注入:重新 loadContent 让整棵界面树重建。
  /// 为什么必须整树重建,而不是靠状态刷新:
  ///  1) `@Builder` 的**值参数是一次性**的(见 H6),设置页的行标题都是值参,状态变化不重算;
  ///  2) 其它已挂载页面(发现/音阁)把 `L.s()` 写在 build 里,但**并不观察语言**这个状态,
  ///     没有任何信号会触发它们重建。
  /// 与 Android「切换语言重建界面」同一策略。播放层是树外单例,重建不打断播放。
  static onLanguageChanged: (() => void) | null = null;

  /// 设置界面语言。"" = 跟随系统。写入应用级偏好语言,资源随即按新语言解析。
  setLanguage(v: string): void {
    // 同值必须短路掉重建。恢复备份时 `BackupManager.apply` 只要备份里有 language 键
    // 就会调进来,语言通常**根本没变**;若照旧重建整棵树,界面会被踢回发现页,
    // 连「已恢复」提示一起冲掉 —— 用户无从确认恢复是否成功。详见 H23。
    const changed = v !== this.language;
    this.language = v;
    Prefs.put('app_language', v);
    SettingsStore.applyLanguage(v);
    if (!changed) return;
    const reload = SettingsStore.onLanguageChanged;
    if (reload !== null) {
      // 延后一帧再重建:此刻还在下拉菜单的点击回调里,立即销毁整棵树会连带销毁
      // 正在收起的菜单。
      setTimeout(() => { reload(); }, 150);
    }
  }

  /// 启动时把已存的语言偏好套用到系统(否则重启后回落系统语言)。
  static applyLanguage(v: string): void {
    try {
      i18n.System.setAppPreferredLanguage(v.length === 0 ? 'default' : v);
      Log.i('Settings', `应用语言 ${v.length === 0 ? '跟随系统' : v}`);
    } catch (e) {
      Log.w('Settings', `设置语言失败 ${(e as Error).message}`);
    }
  }
  setRegionOverride(v: string): void {
    this.regionOverride = v;
    Prefs.put('region_override', v);
  }
  setDefaultSpeed(v: number): void {
    this.defaultSpeed = v;
    Prefs.put('default_speed', v);
  }
  setSkipBackSec(v: number): void {
    this.skipBackSec = v;
    Prefs.put('skip_back', v);
  }
  setSkipForwardSec(v: number): void {
    this.skipForwardSec = v;
    Prefs.put('skip_fwd', v);
  }
  setContextualRadio(v: boolean): void {
    this.contextualRadio = v;
    Prefs.put('contextual_radio', v);
  }
  setUpdatesEnabled(v: boolean): void {
    this.updatesEnabled = v;
    Prefs.put('updates_enabled', v);
  }
  setAllowCellular(v: boolean): void {
    this.allowCellular = v;
    Prefs.put('allow_cellular', v);
  }
  setSubsGrid(v: boolean): void {
    this.subsGrid = v;
    Prefs.put('subs_grid', v);
  }
}
