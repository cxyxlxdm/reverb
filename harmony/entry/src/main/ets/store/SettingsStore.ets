import i18n from '@ohos.i18n';
import { Prefs } from './Prefs';
import { Log } from '../util/Logger';

/// 应用设置。与 Android SettingsStore / macOS SettingsStore 的键位对齐。
/// 用 @Observed 让界面直接观察;每个 setter 立即落盘。
@Observed
export class SettingsStore {
  /**
   * 隐私政策版本。**政策有实质性变更时把这个数 +1**,所有用户会再看一次同意页。
   * 与 Android 的 SettingsStore.PRIVACY_VERSION **保持同步**。
   *
   * 什么算"实质性变更":新增/变更网络访问地址、新增权限、改变数据的收集或用途、
   * 新增会外发数据的功能。纯措辞润色不必 +1。
   *
   * 变更历史:
   *   1 = 首个版本(2026-08)。
   *
   * 改这个数之后**必须重新打包两端**,并同步更新 docs/PRIVACY.md 与 reverb/privacy.html。
   */
  static readonly PRIVACY_VERSION: number = 1;

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
  /**
   * 列表播放模式,存的是 `PlayMode` 的 **ordinal**(与 Android `play_mode` 同口径)。
   *
   * ⚠️ 因为是 ordinal,**新增模式只能加在枚举末尾** —— 往中间插一个位置,
   * 老用户存的数就会指向另一个模式。读侧另有越界回落(降级安装时存的可能是未来值)。
   */
  playMode: number = 0;
  /// 订阅段是否宫格排布
  subsGrid: boolean = false;
  /// 电台模式:false 随机 / true 情境(按时段选分类)
  contextualRadio: boolean = false;
  /// 订阅更新提醒(周期检查 + 本地通知)
  updatesEnabled: boolean = false;
  /// 是否允许蜂窝网络下载(false = 仅 Wi-Fi)。与 Android allowCellular 同名同义。
  allowCellular: boolean = true;
  /**
   * 逐字稿总开关(播放页第三页)。与 Android `transcriptionEnabled` 同名同义、同默认值。
   *
   * **本端目前不显示这一行**:它只在有本机识别时才有意义(那时它决定"任何一集都能转"),
   * 而 `Features.LOCAL_ASR = false`,第三页仅在该集有官方稿时出现。字段留着是为了
   * 将来接上真正可用的引擎时一行都不用改(见 Features.LOCAL_ASR 的注释)。
   */
  transcriptionEnabled: boolean = true;
  /**
   * 逐字高亮:跟读时**逐字点亮**,而不是整句一起亮。与 Android `wordHighlight` 对齐。
   *
   * 本端的词级时间只有一个来源:**发布方的逐字稿本身带不带**(JSON 格式的稿一词一条,
   * 通常带;SRT/VTT 只有句级时间)。稿里没有词级时间时自动退化成整句高亮。
   */
  wordHighlight: boolean = true;
  /**
   * 是否已同意**当前版本**的隐私政策。
   *
   * **同意之前不得装配任何会联网或读系统网络信息的东西** —— 平台合规指引要求首次启动即
   * 显著提示阅读隐私政策,且同意前不申请个人信息/权限。Android 端已因此被判不通过一次
   * (见 MainActivity.startGatedComponents)。鸿蒙这边的门控点:整棵界面树(发现页一进来
   * 就会拉榜单)、订阅更新的 workScheduler 周期任务、系统媒体会话。
   * 详见 AppContainer.startGated 与 Index.build。
   *
   * 落盘的是**已同意的政策版本号**而不是布尔:政策有实质性变更时(新增网络访问点、
   * 新增权限、改变数据用途…),按合规惯例应重新征求同意。把 PRIVACY_VERSION +1
   * 即可让所有用户再看一次同意页。
   */
  privacyAccepted: boolean = false;

  load(): void {
    this.themeMode = Prefs.getNumber('theme_mode', 0);
    this.accentIndex = Prefs.getNumber('accent_index', 0);
    this.fontIndex = Prefs.getNumber('font_index', 1);
    this.language = Prefs.getString('app_language', '');
    this.regionOverride = Prefs.getString('region_override', '');
    this.defaultSpeed = Prefs.getNumber('default_speed', 1.0);
    this.skipBackSec = Prefs.getNumber('skip_back', 10);
    this.skipForwardSec = Prefs.getNumber('skip_fwd', 30);
    this.playMode = Prefs.getNumber('play_mode', 0);
    this.subsGrid = Prefs.getBool('subs_grid', false);
    this.contextualRadio = Prefs.getBool('contextual_radio', false);
    this.updatesEnabled = Prefs.getBool('updates_enabled', false);
    this.allowCellular = Prefs.getBool('allow_cellular', true);
    this.transcriptionEnabled = Prefs.getBool('transcription_enabled', true);
    this.wordHighlight = Prefs.getBool('word_highlight', true);
    this.privacyAccepted = this.loadPrivacyAccepted();
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
  setPlayMode(v: number): void {
    this.playMode = v;
    Prefs.put('play_mode', v);
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
  setTranscriptionEnabled(v: boolean): void {
    this.transcriptionEnabled = v;
    Prefs.put('transcription_enabled', v);
  }
  setWordHighlight(v: boolean): void {
    this.wordHighlight = v;
    Prefs.put('word_highlight', v);
  }
  /// 同意当前版本的隐私政策。紧接着就要装配此前被门控的组件,故先落盘再置内存态。
  acceptPrivacy(): void {
    Prefs.put('privacy_version', SettingsStore.PRIVACY_VERSION);
    this.privacyAccepted = true;
  }

  private loadPrivacyAccepted(): boolean {
    const v = Prefs.getNumber('privacy_version', 0);
    if (v > 0) return v >= SettingsStore.PRIVACY_VERSION;
    // 兼容早期版本:那时只存了布尔 privacy_accepted。视为已同意版本 1。
    if (Prefs.getBool('privacy_accepted', false)) {
      Prefs.put('privacy_version', 1);
      return 1 >= SettingsStore.PRIVACY_VERSION;
    }
    return false;
  }
  setSubsGrid(v: boolean): void {
    this.subsGrid = v;
    Prefs.put('subs_grid', v);
  }
}
