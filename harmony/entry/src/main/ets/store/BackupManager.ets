import { Episode, Podcast, HistoryEntry, ChannelListen, emptyPodcast } from '../model/Models';
import { Codec } from './Codec';
import { Stamp } from './StampStore';
import { EpisodeNote } from './NoteStore';
import { AppContainer } from '../AppContainer';
import { J } from '../net/Http';
import { xmlUnescape } from '../util/HtmlText';
import { FONT_SCALES, fontIndexOf, fontIndexClamped } from '../theme/Theme';
import taskpool from '@ohos.taskpool';
import { stringifyPrettyConcurrent, parseObjectConcurrent } from './JsonTask';
import { Log } from '../util/Logger';

/**
 * 可备份的数据分区(与 Android / macOS 的 8 项一一对应)。
 *
 * ⚠️ **互通契约是键名,不是顺序** —— 三端都按键名读同一份 `reverb-backup.json`,
 * 而 Android 走 `org.json.JSONObject`(HashMap)本来就不保证写出顺序,所以"枚举值=文件里的
 * 出现次序"这种说法站不住(先前本注释就是这么写的,已按实测改掉,见 ROADMAP A2-4)。
 * 保持同序仍然有价值,但那是**界面价值**:勾选框按这个顺序列,三端看到的次序才一致。
 */
export enum BackupSection {
  SUBSCRIPTIONS = 0,
  FAVORITES = 1,
  STAMPS = 2,
  NOTES = 3,
  DOWNLOADS = 4,
  HISTORY = 5,
  LISTEN_STATS = 6,
  SETTINGS = 7
}

export const ALL_SECTIONS: BackupSection[] = [
  BackupSection.SUBSCRIPTIONS, BackupSection.FAVORITES, BackupSection.STAMPS,
  BackupSection.NOTES, BackupSection.DOWNLOADS, BackupSection.HISTORY,
  BackupSection.LISTEN_STATS, BackupSection.SETTINGS
];

const KEY: Record<number, string> = {
  0: 'subscriptions', 1: 'favorites', 2: 'stamps', 3: 'notes',
  4: 'downloads', 5: 'history', 6: 'listenStats', 7: 'settings'
};

const LABEL_KEY: Record<number, string> = {
  0: 'lib_subscriptions', 1: 'lib_favorites', 2: 'footprint_title', 3: 'lib_notes',
  4: 'lib_downloads', 5: 'lib_history', 6: 'listen_stats_title', 7: 'settings_title'
};

export function sectionLabelKey(s: BackupSection): string {
  return LABEL_KEY[s];
}

/**
 * 备份 / 恢复(**合并语义**,不覆盖清空)+ OPML 导入导出。
 *
 * 三类合并规则各不相同(这是 G3/G4 换来的认识):
 *  - 集合类(订阅/收藏/印记):按 id 并集,幂等;
 *  - 状态类(历史):按 updatedAt 取新者,幂等;
 *  - **计数类(收听时长):按设备分账逐格取 max**,绝不相加,否则重复恢复会翻倍;
 *  - 下载:只备份元信息与链接(不含音频),恢复时按链接重新下载。
 */
export class BackupManager {
  private static VERSION = 1;

  /// 导出为 JSON 字符串。
  /**
   * 组装备份内容并序列化。**序列化走子线程**(几百 KB 到几 MB 的 `stringify` 不该占 UI 线程,
   * 见 H65);组装本身必须留在 UI 线程 —— 它要读各个 store。
   */
  static async build(app: AppContainer, include: BackupSection[]): Promise<string> {
    const root = BackupManager.buildRoot(app, include);
    try {
      const out: Object = await taskpool.execute(stringifyPrettyConcurrent, root);
      return out as string;
    } catch (e) {
      Log.w('Backup', `子线程序列化失败,回落本线程:${(e as Error).message}`);
      return JSON.stringify(root, null, 2);
    }
  }

  private static buildRoot(app: AppContainer, include: BackupSection[]): Record<string, Object> {
    const root: Record<string, Object> = {};
    root['version'] = BackupManager.VERSION;
    const has = (s: BackupSection): boolean => include.indexOf(s) >= 0;

    if (has(BackupSection.SUBSCRIPTIONS)) {
      const arr: Object[] = [];
      const list = app.subscriptions.subscriptions;
      for (let i = 0; i < list.length; i++) arr.push(Codec.podcastToJson(list[i]));
      root[KEY[BackupSection.SUBSCRIPTIONS]] = arr;
    }
    if (has(BackupSection.FAVORITES)) {
      const arr: Object[] = [];
      const list = app.favorites.favorites;
      for (let i = 0; i < list.length; i++) arr.push(Codec.episodeToJson(list[i]));
      root[KEY[BackupSection.FAVORITES]] = arr;
    }
    if (has(BackupSection.STAMPS)) {
      const arr: Object[] = [];
      const list = app.stamps.stamps;
      for (let i = 0; i < list.length; i++) {
        const s = list[i];
        arr.push({
          'episodeId': s.episodeId, 'seal': s.seal, 'title': s.title,
          'podcastTitle': s.podcastTitle, 'createdAt': s.createdAt
        } as Record<string, Object>);
      }
      root[KEY[BackupSection.STAMPS]] = arr;
    }
    if (has(BackupSection.NOTES)) {
      // 批注是**用户写出来的字**,丢了没有任何东西能补回来,所以必须进默认导出。
      // episode 整条嵌进去(与 history 同构),否则换机后那些被发布方删掉的旧集无法定位。
      const arr: Object[] = [];
      const list = app.notes.notes;
      for (let i = 0; i < list.length; i++) {
        const n = list[i];
        arr.push({
          'noteId': n.noteId, 'positionMs': n.positionMs, 'text': n.text,
          'createdAt': n.createdAt, 'episode': Codec.episodeToJson(n.episode)
        } as Record<string, Object>);
      }
      root[KEY[BackupSection.NOTES]] = arr;
    }
    if (has(BackupSection.DOWNLOADS)) {
      // 只备份单集元信息/链接,不含音频文件
      const arr: Object[] = [];
      const list = app.downloads.downloads;
      for (let i = 0; i < list.length; i++) arr.push(Codec.episodeToJson(list[i].episode));
      root[KEY[BackupSection.DOWNLOADS]] = arr;
    }
    if (has(BackupSection.HISTORY)) {
      const arr: Object[] = [];
      const list = app.history.history;
      for (let i = 0; i < list.length; i++) arr.push(Codec.historyToJson(list[i]));
      root[KEY[BackupSection.HISTORY]] = arr;
    }
    if (has(BackupSection.LISTEN_STATS)) {
      const arr: Object[] = [];
      const list = app.listenStats.snapshot();
      for (let i = 0; i < list.length; i++) {
        let total = 0;
        const pd = list[i].perDevice;
        const ks = Object.keys(pd);
        for (let j = 0; j < ks.length; j++) total += pd[ks[j]];
        arr.push(Codec.channelListenToJson(list[i], total));
      }
      root[KEY[BackupSection.LISTEN_STATS]] = arr;
    }
    if (has(BackupSection.SETTINGS)) {
      const st = app.settings;
      /**
       * settings 分区的键集与 Android `BackupManager.kt` 的 SETTINGS 段**逐键对齐**。
       *
       * 为什么以 Android 的键名为准:Android 1.0.2 已发布,那份格式是**既成事实**;
       * 而鸿蒙 1.0.3 虽然在架,这一份文件此前只有本端自己读写过,改它不破坏任何现存备份。
       *
       * 两条不同源的东西要分清:
       * - **跨端键名是契约**(`fontScale` 是倍率、`allowCellularDownload`、`updatesEnabled`、
       *   `categoryOrder`…) —— 两端必须同名同义同类型;
       * - **本地编码不是契约**(Android 用 SharedPreferences 存 Float、本端用 `font_index`
       *   存档位下标) —— 所以这里同时写 `fontScale`(给对方读)和 `fontIndex`
       *   (给**已发布的旧鸿蒙**读,它只认下标)。
       */
      root[KEY[BackupSection.SETTINGS]] = {
        'themeMode': st.themeMode, 'accentIndex': st.accentIndex,
        // 倍率而非下标:与 Android 同一个数,不参与 0.876 那套外壳换算
        'fontScale': FONT_SCALES[st.fontIndex] === undefined ? 1.0 : FONT_SCALES[st.fontIndex],
        'fontIndex': st.fontIndex,
        'language': st.language,
        'regionOverride': st.regionOverride,
        'allowCellularDownload': st.allowCellular,
        'updatesEnabled': st.updatesEnabled,
        'defaultSpeed': st.defaultSpeed, 'skipBackSec': st.skipBackSec,
        'skipForwardSec': st.skipForwardSec, 'subsGrid': st.subsGrid,
        'contextualRadio': st.contextualRadio,
        'categoryOrder': app.categoryStore.keys()
      } as Record<string, Object>;
    }
    Log.i('Backup', `导出 分区=${include.length}`);
    return root;
  }

  /// 把备份文本解析成对象。**走子线程** —— 导入的文件可以很大,而这一步是纯数据运算。
  /// 解析失败(或不是对象)返回 null。
  static async parseRoot(json: string): Promise<Record<string, Object> | null> {
    try {
      const out: Object = await taskpool.execute(parseObjectConcurrent, json);
      return out === null || out === undefined ? null : out as Record<string, Object>;
    } catch (e) {
      Log.w('Backup', `子线程解析失败,回落本线程:${(e as Error).message}`);
      try {
        const o: Object = JSON.parse(json);
        return Array.isArray(o) ? null : o as Record<string, Object>;
      } catch (e2) {
        return null;
      }
    }
  }

  /// 探测备份里含哪些非空分区(文本版:自己解析一遍)。
  static async sectionsIn(json: string): Promise<BackupSection[]> {
    return BackupManager.sectionsInRoot(await BackupManager.parseRoot(json));
  }

  /// 探测备份里含哪些非空分区。**已解析版** —— 导入流程要先探测再应用,
  /// 两步共用同一份 root,避免把同一个大 JSON 解析两遍(原先就是解析两遍)。
  static sectionsInRoot(root: Record<string, Object> | null): BackupSection[] {
    const out: BackupSection[] = [];
    if (root === null) return out;
    for (let i = 0; i < ALL_SECTIONS.length; i++) {
      const s = ALL_SECTIONS[i];
      const v = root[KEY[s]];
      if (v === undefined || v === null) continue;
      if (Array.isArray(v)) {
        if ((v as Object[]).length > 0) out.push(s);
      } else {
        out.push(s);
      }
    }
    return out;
  }

  /// 应用备份(合并,不覆盖)。返回是否导入了设置(调用方据此刷新界面)。
  static async apply(app: AppContainer, json: string, include: BackupSection[]): Promise<boolean> {
    return BackupManager.applyRoot(app, await BackupManager.parseRoot(json), include);
  }

  /// 应用备份的**已解析版**。合并逻辑一字未动 —— 这是数据安全路径,
  /// 这轮只把"解析"挪出 UI 线程,不碰任何合并规则(G-Counter 取 max、历史按 updatedAt 取新)。
  static applyRoot(app: AppContainer, root: Record<string, Object> | null, include: BackupSection[]): boolean {
    if (root === null) {
      Log.e('Backup', '恢复解析失败');
      return false;
    }
    const has = (s: BackupSection): boolean => include.indexOf(s) >= 0;

    if (has(BackupSection.SUBSCRIPTIONS)) {
      const arr = J.arr(root, KEY[BackupSection.SUBSCRIPTIONS]);
      const list: Podcast[] = [];
      for (let i = 0; i < arr.length; i++) list.push(Codec.podcastFromJson(J.asObj(arr[i])));
      if (list.length > 0) app.subscriptions.addAll(list);
      Log.i('Backup', `恢复订阅 ${list.length} 条`);
    }
    if (has(BackupSection.FAVORITES)) {
      const arr = J.arr(root, KEY[BackupSection.FAVORITES]);
      const list: Episode[] = [];
      for (let i = 0; i < arr.length; i++) list.push(Codec.episodeFromJson(J.asObj(arr[i])));
      if (list.length > 0) app.favorites.addAll(list);
    }
    if (has(BackupSection.STAMPS)) {
      const arr = J.arr(root, KEY[BackupSection.STAMPS]);
      const list: Stamp[] = [];
      for (let i = 0; i < arr.length; i++) {
        const o = J.asObj(arr[i]);
        if (o === null) continue;
        const id = J.str(o, 'episodeId');
        if (id.length === 0) continue;
        list.push({
          episodeId: id, seal: J.str(o, 'seal'), title: J.str(o, 'title'),
          podcastTitle: J.str(o, 'podcastTitle'), createdAt: J.num(o, 'createdAt')
        });
      }
      if (list.length > 0) app.stamps.addAll(list);
    }
    if (has(BackupSection.NOTES)) {
      const arr = J.arr(root, KEY[BackupSection.NOTES]);
      const list: EpisodeNote[] = [];
      for (let i = 0; i < arr.length; i++) {
        const o = J.asObj(arr[i]);
        if (o === null) continue;
        const ep = Codec.episodeFromJson(J.obj(o, 'episode'));
        // 没有可播地址或没有正文的一律不收 —— 收进来就是列表里一条"点不动/看不出是什么"的记录
        if (ep.audioUrl.length === 0 || J.str(o, 'text').length === 0) continue;
        /**
         * **只有 `createdAt` 这个 epoch 字段**要做秒/毫秒归一(H86:macOS 侧写的是秒)。
         * `positionMs` 绝不能套同一条阈值 —— 那条阈值是给「Unix 时间戳」设计的,
         * 播放位置恒落在 1..1e11 之间,套上去会把 66 分钟(4.0e6 ms)误判成秒、乘一千变成
         * 40 亿毫秒,跳过去直接超出时长而落回开头,且列表显示的时间戳看着还是"合理"的。
         */
        const raw = J.num(o, 'createdAt');
        const createdAt = (raw > 0 && raw < 100000000000) ? raw * 1000 : raw;
        const pos = J.num(o, 'positionMs');
        list.push({
          noteId: J.str(o, 'noteId').length > 0 ? J.str(o, 'noteId') : `${createdAt}-${i}`,
          episode: ep,
          positionMs: pos > 0 ? pos : 0,
          text: J.str(o, 'text'),
          createdAt: createdAt
        });
      }
      if (list.length > 0) app.notes.addAll(list);
    }
    if (has(BackupSection.DOWNLOADS)) {
      // 按链接重新下载(备份不含音频文件)
      const arr = J.arr(root, KEY[BackupSection.DOWNLOADS]);
      let n = 0;
      for (let i = 0; i < arr.length; i++) {
        const e = Codec.episodeFromJson(J.asObj(arr[i]));
        if (e.audioUrl.length === 0 || app.downloadManager.isDownloaded(e.id)) continue;
        app.downloadManager.download(e);
        n += 1;
      }
      Log.i('Backup', `恢复下载 需重新下载 ${n} 集`);
    }
    if (has(BackupSection.HISTORY)) {
      const arr = J.arr(root, KEY[BackupSection.HISTORY]);
      const list: HistoryEntry[] = [];
      for (let i = 0; i < arr.length; i++) list.push(Codec.historyFromJson(J.asObj(arr[i])));
      if (list.length > 0) app.history.mergeAll(list);
    }
    if (has(BackupSection.LISTEN_STATS)) {
      const arr = J.arr(root, KEY[BackupSection.LISTEN_STATS]);
      const list: ChannelListen[] = [];
      const legacy = new Map<string, number>();
      for (let i = 0; i < arr.length; i++) {
        const pair = Codec.channelListenFromJson(J.asObj(arr[i]));
        if (pair[0].key.length === 0) continue;
        list.push(pair[0]);
        if (pair[1] > 0) legacy.set(pair[0].key, pair[1]);
      }
      if (list.length > 0) app.listenStats.merge(list, legacy);
    }
    let importedSettings = false;
    if (has(BackupSection.SETTINGS)) {
      const o = J.obj(root, KEY[BackupSection.SETTINGS]);
      if (o !== null) {
        const st = app.settings;
        if (o['themeMode'] !== undefined) st.setThemeMode(J.num(o, 'themeMode'));
        if (o['accentIndex'] !== undefined) st.setAccentIndex(J.num(o, 'accentIndex'));
        /**
         * 字号:**优先读 `fontScale`(倍率),读不到才退 `fontIndex`(本端下标)**。
         *
         * 这个先后不能反。Android 那份备份只有 `fontScale`,而它对"本端从未存过字号"
         * 是唯一可行的入口;反过来旧鸿蒙备份只有 `fontIndex`。两个键同时在场时
         * (新版本端导出就是同时写两个),必须让**跨端契约键**赢 ——
         * 否则一份手改过的 Android 备份在本端会按旧下标落,而对方端按新倍率落,
         * 同一份文件在两台机器上恢复出两档字号,且谁都不报错。
         */
        if (o['fontScale'] !== undefined) st.setFontIndex(fontIndexOf(J.num(o, 'fontScale')));
        else if (o['fontIndex'] !== undefined) st.setFontIndex(fontIndexClamped(J.num(o, 'fontIndex')));
        if (o['language'] !== undefined) st.setLanguage(J.str(o, 'language'));
        // Android 的"自动"是 JSON null,本端是 ""。J.str 对 null 返回 "",两边天然对上。
        if (o['regionOverride'] !== undefined) st.setRegionOverride(J.str(o, 'regionOverride'));
        const cd = o['allowCellularDownload'];
        if (typeof cd === 'boolean') st.setAllowCellular(cd);
        const ue = o['updatesEnabled'];
        if (typeof ue === 'boolean') st.setUpdatesEnabled(ue);
        if (o['defaultSpeed'] !== undefined) st.setDefaultSpeed(J.num(o, 'defaultSpeed'));
        if (o['skipBackSec'] !== undefined) st.setSkipBackSec(J.num(o, 'skipBackSec'));
        if (o['skipForwardSec'] !== undefined) st.setSkipForwardSec(J.num(o, 'skipForwardSec'));
        const sg = o['subsGrid'];
        if (typeof sg === 'boolean') st.setSubsGrid(sg);
        const cr = o['contextualRadio'];
        if (typeof cr === 'boolean') st.setContextualRadio(cr);
        /**
         * 分类顺序。这一行就是 FEATURES 里那句"`categoryOrder` 在本端无消费方"的收尾。
         *
         * `save()` 内部对空数组早退(同 Android `DiscoverViewModel.kt:104`),
         * 所以"备份里这个键是空的"= 不动本机已有顺序,而不是清空。
         * 恢复之后当前页可能正停在某个分类上,而发现页的 `cats` 是 aboutToAppear 时读的 ——
         * 由 #89 那一并处理的「恢复后整页刷新」负责把界面接上,这里只保证落盘正确。
         */
        const ca = J.arr(o, 'categoryOrder');
        if (ca.length > 0) {
          const keys: string[] = [];
          for (let i = 0; i < ca.length; i++) {
            const v = ca[i];
            if (typeof v === 'string' && v.length > 0) keys.push(v);
          }
          app.categoryStore.save(keys);
        }
        importedSettings = true;
      }
    }
    Log.i('Backup', `恢复完成 importedSettings=${importedSettings}`);
    return importedSettings;
  }

  // ── OPML ──

  static exportOpml(app: AppContainer): string {
    let body = '';
    const list = app.subscriptions.subscriptions;
    for (let i = 0; i < list.length; i++) {
      const t = BackupManager.xmlEscape(list[i].title);
      const f = BackupManager.xmlEscape(list[i].feedUrl);
      body += `    <outline type="rss" text="${t}" title="${t}" xmlUrl="${f}"/>\n`;
    }
    Log.i('Backup', `导出 OPML ${list.length} 个订阅`);
    return `<?xml version="1.0" encoding="UTF-8"?>\n<opml version="2.0">\n  <head><title>余音订阅</title></head>\n  <body>\n${body}  </body>\n</opml>\n`;
  }

  /**
   * 从 OPML 里抽出 feed 地址,去重。大小写不敏感(xmlUrl / xmlurl / XMLURL)。
   *
   * 两个坑,都是「自家导出的文件自家导不回来」:
   *  1) 属性值**单引号**也合法(`xmlUrl='...'`),部分导出器就这么写,只匹配双引号会整份漏掉;
   *  2) 导出时把 `&` 转义成了 `&amp;`,**必须反转义**回来 —— 否则带查询参数的地址
   *     (`?id=x&format=rss`,播客源里很常见)会变成 `?id=x&amp;format=rss`,订阅直接拉不动。
   * Android/macOS 用系统 XML 解析器,这两件事解析器替它们做了;鸿蒙抠字符串就得自己来。
   */
  static extractFeedUrls(opml: string): string[] {
    const out: string[] = [];
    const seen = new Set<string>();
    const re = /xmlurl\s*=\s*(?:"([^"]*)"|'([^']*)')/gi;
    while (true) {
      const m = re.exec(opml);
      if (m === null) break;
      const raw: string = m[1] !== undefined ? m[1] : m[2];
      const u = xmlUnescape(raw).trim();
      if (u.length === 0 || seen.has(u)) continue;
      seen.add(u);
      out.push(u);
    }
    return out;
  }

  /// 导入 OPML:逐个解析 feed 拿到频道信息后并入订阅(拿不到则用地址兜底)。
  static async importOpml(app: AppContainer, opml: string): Promise<number> {
    const urls = BackupManager.extractFeedUrls(opml);
    const list: Podcast[] = [];
    for (let i = 0; i < urls.length; i++) {
      const feed = await app.repository.feed(urls[i]);
      if (feed !== null) {
        list.push(feed.podcast);
      } else {
        const p = emptyPodcast();
        p.id = urls[i];
        p.feedUrl = urls[i];
        p.title = urls[i];
        list.push(p);
      }
    }
    if (list.length > 0) app.subscriptions.addAll(list);
    Log.i('Backup', `导入 OPML ${list.length} 个订阅`);
    return list.length;
  }

  private static xmlEscape(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
}
