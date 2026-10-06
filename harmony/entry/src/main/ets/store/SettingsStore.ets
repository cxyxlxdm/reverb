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
  /// **默认 2(水墨)**,与 Android `theme_mode` 的默认值一致 —— 品牌主观感是水墨,
  /// 不是"跟随系统"。原先本端默认 0,两端首启是两套界面;而 0 这条路本身在 H126 之前是坏的。
  themeMode: number = 2;
  /// ACCENTS 索引:0 青瓷 / 1 黛蓝 / 2 绯红 / 3 竹青
  accentIndex: number = 0;
  /// FONT_SCALES 索引(4 档)
  fontIndex: number = 1;
  /// 界面语言:"" 跟随系统,否则 zh-CN / zh-TW / en / fr / es(与 Android 同一套标签,见 langTag)
  language: string = '';
  /// 目录检索地区:"" 自动
  regionOverride: string = '';
  defaultSpeed: number = 1.0;
  skipBackSec: number = 10;
  skipForwardSec: number = 30;
  /**
   * 列表播放模式的**回落值**,存的是 `PlayMode` 的 **ordinal**(与 Android `play_mode` 同键同口径)。
   *
   * 它服务两种情况:①老版本只有这一份全局设置,升级后它就是"没单独设过的列"的走法;
   * ②起播时**没有列身份**(发现页、历史行、迷你条、「下一个播放」)就按它走。
   *
   * ⚠️ 因为是 ordinal,**新增模式只能加在枚举末尾** —— 往中间插一个位置,
   * 老用户存的数就会指向另一个模式。读侧另有越界回落(降级安装时存的可能是未来值)。
   */
  playModeDefault: number = 0;
  /**
   * **每一列自己的**播放模式:key 是 `playQueue` 的 tag
   * ("inbox" / "fav" / "dl" / "podcast:<feedUrl>"),value 是 `PlayMode` 的 ordinal。
   * 见 H119(原先"全局一份",装机反馈「在收藏里切了单曲循环,下载也变了」)。
   *
   * 与 Android 的 `play_mode_map` **同名不同编码**:那边是一个字符串集合,元素写成
   * `tag=ordinal`,读的时候必须按**最后一个** `=` 切 —— 频道那一列的 tag 本身就是 feedUrl,
   * query 里带 `=` 就会把整条静默丢掉(H119 修法 1)。鸿蒙这边 preferences 没有集合的对等物,
   * 索性把整张表存成一段 JSON,**key 里出现 `=` 不需要任何转义,那个坑在结构上不存在**。
   * 两端的键名与语义一致,容器不同;这份数据不跨端搬运(备份分区里没有播放模式)。
   */
  playModeByTag: Record<string, number> = {};
  /// 订阅段是否宫格排布
  subsGrid: boolean = false;
  /// 电台模式:false 随机 / true 情境(按时段选分类)
  contextualRadio: boolean = false;
  /// 订阅更新提醒(周期检查 + 本地通知)
  updatesEnabled: boolean = false;
  /**
   * 是否**允许**在计费网络(蜂窝)下下载。**默认关**,与 Android `cellular_dl` 的默认值一致。
   *
   * ⚠️ 这里原先的注释写的是「与 Android allowCellular 同名同义」而本端默认 `true` ——
   * 那句是错的:Android 的字段叫 `allowCellularDownload`、键是 `cellular_dl`、**默认 false**,
   * 于是同一次改动里两端「什么都不设」的下载行为正好相反(鸿蒙走蜂窝、Android 拦)。
   * 界面那一行是反向的开关(`set_wifi_only`,显示的是"仅 Wi-Fi"),所以翻转默认值时
   * 界面文案不用动,只有首启的用户会看到开关处于"仅 Wi-Fi"这一侧。
   */
  allowCellular: boolean = false;
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
    this.themeMode = Prefs.getNumber('theme_mode', 2);
    this.accentIndex = Prefs.getNumber('accent_index', 0);
    this.fontIndex = Prefs.getNumber('font_index', 1);
    // 老版本(1.0.x)存的是 zh-Hans / zh-Hant,不归一的话升级后设置页会显示「跟随系统」。
    // 归一放在读盘这一侧(硬规矩 10:不变式在数据出口保证),下面 applyLanguage 拿到的就只能是新标签。
    this.language = SettingsStore.langTag(Prefs.getString('app_language', ''));
    this.regionOverride = Prefs.getString('region_override', '');
    this.defaultSpeed = Prefs.getNumber('default_speed', 1.0);
    this.skipBackSec = Prefs.getNumber('skip_back', 10);
    this.skipForwardSec = Prefs.getNumber('skip_fwd', 30);
    this.playModeDefault = Prefs.getNumber('play_mode', 0);
    this.playModeByTag = readPlayModeMap();
    this.subsGrid = Prefs.getBool('subs_grid', false);
    this.contextualRadio = Prefs.getBool('contextual_radio', false);
    this.updatesEnabled = Prefs.getBool('updates_enabled', false);
    this.allowCellular = Prefs.getBool('allow_cellular', false);
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
    // 归一在**进来这一步**做,所以下面的比较是"归一后 vs 当前(也已归一)",不会误判成变了。
    const next = SettingsStore.langTag(v);
    const changed = next !== this.language;
    this.language = next;
    Prefs.put('app_language', next);
    SettingsStore.applyLanguage(next);
    if (!changed) return;
    const reload = SettingsStore.onLanguageChanged;
    if (reload !== null) {
      // 延后一帧再重建:此刻还在下拉菜单的点击回调里,立即销毁整棵树会连带销毁
      // 正在收起的菜单。
      setTimeout(() => { reload(); }, 150);
    }
  }

  /**
   * 语言标签**归一到 Android 那一套**:"" / zh-CN / zh-TW / en / fr / es。
   *
   * 为什么是这一套而不是本端原先的 `zh-Hans` / `zh-Hant`:
   * ① **契约以已发布的那一端为准** —— Android 1.0.2 在外,它本地存的一直是 zh-CN/zh-TW,
   *    而它的备份**从这一版起**才第一次导出 `language`;本端的语言值从未离开过本端,
   *    换掉不破坏任何现存备份。
   * ② 本端资源目录本来就是按**地区**切的(`base` 放简体 + `zh_TW`/`en_US`/`fr_FR`/`es_ES`),
   *    `zh-TW` 与目录名同形,`zh-Hant` 反而要靠 i18n 的规范化才落得上去。
   *
   * ⚠️ 已发布的鸿蒙 1.0.x 里存的是 `zh-Hans` / `zh-Hant`,所以**读盘也要过这一道**
   * (见 `load()` 里那句),否则升级后老用户的语言会在界面上显示成「跟随系统」。
   */
  static langTag(v: string): string {
    if (v === 'zh-Hans' || v === 'zh_CN') return 'zh-CN';
    if (v === 'zh-Hant' || v === 'zh_TW') return 'zh-TW';
    return v;
  }

  /// 启动时把已存的语言偏好套用到系统(否则重启后回落系统语言)。
  static applyLanguage(v: string): void {
    try {
      // 「跟随系统」**不能直接传 'default'**:SDK 里这个值写明**只在冷启动时生效**
      // (`@ohos.i18n.d.ts` 对 `setAppPreferredLanguage` 的说明),而本端切语言是当场
      // `loadContent` 重画整棵树 —— 于是勾「跟随系统」之后界面仍是旧语言,要等下一次
      // 冷启动才回正,看起来就像这一项点了没反应(见 H146)。显式语言没有这个限制。
      // 改成**当场把系统语言解析成具体标签**再交给它,让它走与显式语言同一条当场生效的路。
      // 持久化的仍是空串,所以每次冷启动都按**当时的**系统语言重新解析,
      // 不会钉死在勾选那一刻。
      const tag = v.length > 0 ? v : i18n.System.getSystemLanguage();
      i18n.System.setAppPreferredLanguage(tag);
      Log.i('Settings', `应用语言 ${v.length === 0 ? `跟随系统(${tag})` : v}`);
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
  /**
   * 写**某一列**的播放模式并落盘。**空 tag 不进这张表** —— 它表示"没有列身份",
   * 走 `setPlayModeDefault`。这条分流与 Android 同口径,且不是防御性摆设:
   * 表里的 `""` 一旦有值就会和回落键打架,两处各存一份、读的时候不知听谁。
   *
   * 整个对象**换新引用**再写:ArkUI 的观察粒度是对象不是字段,原地改属性不会通知任何人,
   * 而这里的语义正是"表变了"。退订的频道不会从这张表里被清掉 —— 与 Android 一致,
   * 一条 URL 的整数不值得为它加回收逻辑(残留量以"用户订阅过的频道数"为上界)。
   * **这是决定,不是待办**(理由记在 H119):没有消费方会把"表里有这个键"当成"还在订阅",
   * 清它反而丢掉"重新订阅接上原模式"这份好处。别再当 bug 翻出来。
   */
  setPlayModeFor(tag: string, v: number): void {
    if (tag.length === 0) {
      this.setPlayModeDefault(v);
      return;
    }
    if (this.playModeByTag[tag] === v) return;
    const next: Record<string, number> = {};
    const keys = Object.keys(this.playModeByTag);
    for (let i = 0; i < keys.length; i++) next[keys[i]] = this.playModeByTag[keys[i]];
    next[tag] = v;
    this.playModeByTag = next;
    Prefs.put('play_mode_map', JSON.stringify(next));
  }

  /// 回落值:没有列身份的起播按它走(也是老版本那份全局设置的现名)。
  setPlayModeDefault(v: number): void {
    this.playModeDefault = v;
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

/**
 * 读「按列存的播放模式」表。整张表是一段 JSON 对象(`{"inbox":1,"podcast:https://…":2}`)。
 *
 * 三个回落都必须静默:空串(从没设过)、JSON 解析失败(手改过文件 / 未来版本换了格式)、
 * 值不是数字。这张表读不出来时用回落值(`play_mode`)播就行 —— 它在启动时同步读,
 * **绝不能因为一段坏 JSON 让整个应用起不来**。
 */
function readPlayModeMap(): Record<string, number> {
  const raw = Prefs.getString('play_mode_map', '');
  if (raw.length === 0) return {};
  let out: Record<string, number> = {};
  try {
    const root = JSON.parse(raw) as Record<string, Object>;
    const keys = Object.keys(root);
    for (let i = 0; i < keys.length; i++) {
      const v = root[keys[i]];
      if (typeof v === 'number' && v >= 0) out[keys[i]] = v;
    }
  } catch (e) {
    Log.w('Settings', `play_mode_map 解析失败,按空表处理:${(e as Error).message}`);
    out = {};
  }
  return out;
}
