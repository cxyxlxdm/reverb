import { Episode, Podcast, HistoryEntry, ChannelListen, emptyPodcast } from '../model/Models';
import { Codec } from './Codec';
import { Stamp } from './StampStore';
import { AppContainer } from '../AppContainer';
import { J } from '../net/Http';
import { xmlUnescape } from '../util/HtmlText';
import taskpool from '@ohos.taskpool';
import { stringifyPrettyConcurrent, parseObjectConcurrent } from './JsonTask';
import { Log } from '../util/Logger';

/// 可备份的数据分区(与 Android / macOS 的 7 项一致)。
export enum BackupSection {
  SUBSCRIPTIONS = 0,
  FAVORITES = 1,
  STAMPS = 2,
  DOWNLOADS = 3,
  HISTORY = 4,
  LISTEN_STATS = 5,
  SETTINGS = 6
}

export const ALL_SECTIONS: BackupSection[] = [
  BackupSection.SUBSCRIPTIONS, BackupSection.FAVORITES, BackupSection.STAMPS,
  BackupSection.DOWNLOADS, BackupSection.HISTORY, BackupSection.LISTEN_STATS,
  BackupSection.SETTINGS
];

const KEY: Record<number, string> = {
  0: 'subscriptions', 1: 'favorites', 2: 'stamps',
  3: 'downloads', 4: 'history', 5: 'listenStats', 6: 'settings'
};

const LABEL_KEY: Record<number, string> = {
  0: 'lib_subscriptions', 1: 'lib_favorites', 2: 'footprint_title',
  3: 'lib_downloads', 4: 'lib_history', 5: 'listen_stats_title', 6: 'settings_title'
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
      root[KEY[BackupSection.SETTINGS]] = {
        'themeMode': st.themeMode, 'accentIndex': st.accentIndex, 'fontIndex': st.fontIndex,
        'language': st.language, 'regionOverride': st.regionOverride,
        'defaultSpeed': st.defaultSpeed, 'skipBackSec': st.skipBackSec,
        'skipForwardSec': st.skipForwardSec, 'subsGrid': st.subsGrid,
        'contextualRadio': st.contextualRadio
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
        if (o['fontIndex'] !== undefined) st.setFontIndex(J.num(o, 'fontIndex'));
        if (o['language'] !== undefined) st.setLanguage(J.str(o, 'language'));
        if (o['regionOverride'] !== undefined) st.setRegionOverride(J.str(o, 'regionOverride'));
        if (o['defaultSpeed'] !== undefined) st.setDefaultSpeed(J.num(o, 'defaultSpeed'));
        if (o['skipBackSec'] !== undefined) st.setSkipBackSec(J.num(o, 'skipBackSec'));
        if (o['skipForwardSec'] !== undefined) st.setSkipForwardSec(J.num(o, 'skipForwardSec'));
        const sg = o['subsGrid'];
        if (typeof sg === 'boolean') st.setSubsGrid(sg);
        const cr = o['contextualRadio'];
        if (typeof cr === 'boolean') st.setContextualRadio(cr);
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
