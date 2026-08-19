import { Episode, ChannelListen, HistoryEntry, channelKeyOf, listenedMsOf } from '../model/Models';
import { JsonFile } from './JsonFile';
import { Codec } from './Codec';
import { Prefs } from './Prefs';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/**
 * 按频道累计「实际播放过的内容时长」。三端同一口径:
 * 播放中的正向增量(1..3000ms)累加,快进/暂停不计;倍速按内容时长计。
 *
 * 时长**按设备分账**(perDevice:设备ID → 毫秒),展示值为各设备之和。
 * 备份合并按设备取 max(G-Counter CRDT 语义)⇒ 重复恢复不会重复统计。
 * 首启种子记在**共用的 seed 格**(不是本机格)——历史本身也会被备份合并,
 * 两台设备从同一份历史各自种子若记在各自名下就会翻倍。
 */
@Observed
export class ListenStatsStore {
  /// 已按累计时长降序,供页面直接渲染横条。
  stats: ChannelListen[] = [];

  private static FILE = 'listen_stats.json';
  private static FLUSH_THRESHOLD_MS = 5000;
  /// 历史估算种子的共用分账键(所有设备同一格,合并取 max)。
  static readonly SEED_KEY = 'seed';

  private table: Map<string, ChannelListen> = new Map<string, ChannelListen>();
  private pendingMs = 0;
  private deviceId = '';

  load(): void {
    // 本机安装标识(首次生成后固定)
    let id = Prefs.getString('device_id', '');
    if (id.length === 0) {
      id = `${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
      Prefs.put('device_id', id);
    }
    this.deviceId = id;

    const arr = JsonFile.readArray(ListenStatsStore.FILE);
    let migrated = false;
    for (let i = 0; i < arr.length; i++) {
      const pair = Codec.channelListenFromJson(J.asObj(arr[i]));
      const c = pair[0];
      const legacy = pair[1];
      if (c.key.length === 0) continue;
      // 旧扁平格式迁移:既有时长归入本机名下
      if (Object.keys(c.perDevice).length === 0 && legacy > 0) {
        c.perDevice[this.deviceId] = legacy;
        migrated = true;
      }
      this.table.set(c.key, c);
    }
    this.publish();
    if (migrated) this.persist();
    Log.i('ListenStats', `加载 ${this.table.size} 个频道 device=${this.deviceId.substring(0, 8)} 迁移=${migrated}`);
  }

  /// 查询某频道累计毫秒(各设备之和)。
  listenedMsFor(key: string): number {
    const c = this.table.get(key);
    return c === undefined ? 0 : listenedMsOf(c);
  }

  /// 累加一段实际播放的内容毫秒到本机名下。
  add(e: Episode, deltaMs: number): void {
    if (deltaMs <= 0) return;
    const k = channelKeyOf(e);
    let c = this.table.get(k);
    if (c === undefined) {
      c = { key: k, title: e.podcastTitle, artworkUrl: e.artworkUrl, feedUrl: e.feedUrl, perDevice: {} };
    }
    const cur = c.perDevice[this.deviceId];
    c.perDevice[this.deviceId] = (cur === undefined ? 0 : cur) + deltaMs;
    if (e.podcastTitle.length > 0) c.title = e.podcastTitle;
    if (e.artworkUrl.length > 0) c.artworkUrl = e.artworkUrl;
    this.table.set(k, c);
    this.pendingMs += deltaMs;
    if (this.pendingMs >= ListenStatsStore.FLUSH_THRESHOLD_MS) this.flush();
  }

  /// 立即落盘并刷新(暂停/播完/切集时调用)。
  flush(): void {
    if (this.pendingMs <= 0) return;
    this.pendingMs = 0;
    this.persist();
    this.publish();
  }

  /// 供备份导出的快照。
  snapshot(): ChannelListen[] {
    const out: ChannelListen[] = [];
    this.table.forEach((c: ChannelListen) => out.push(c));
    return out;
  }

  /**
   * 备份恢复合并:**按设备逐格取 max**(绝不跨设备相加)。
   * 同一份备份重复恢复结果不变(幂等);不同设备的分账相加,故跨设备恢复自然汇总。
   * legacyMsByKey 承载旧格式备份的扁平时长(归入伪设备键,避免与本机数相加出错)。
   */
  merge(incoming: ChannelListen[], legacyMsByKey: Map<string, number>): void {
    if (incoming.length === 0) return;
    for (let i = 0; i < incoming.length; i++) {
      const inc = incoming[i];
      if (inc.key.length === 0) continue;
      let pd: Record<string, number> = inc.perDevice;
      if (Object.keys(pd).length === 0) {
        const legacy = legacyMsByKey.get(inc.key);
        if (legacy === undefined || legacy <= 0) continue;
        pd = {};
        pd[`legacy:${inc.key}`] = legacy;
      }
      const cur = this.table.get(inc.key);
      if (cur === undefined) {
        this.table.set(inc.key, {
          key: inc.key, title: inc.title, artworkUrl: inc.artworkUrl,
          feedUrl: inc.feedUrl, perDevice: pd
        });
      } else {
        const keys = Object.keys(pd);
        for (let j = 0; j < keys.length; j++) {
          const dev = keys[j];
          const mine = cur.perDevice[dev];
          cur.perDevice[dev] = Math.max(mine === undefined ? 0 : mine, pd[dev]);
        }
        if (cur.title.length === 0) cur.title = inc.title;
        if (cur.artworkUrl.length === 0) cur.artworkUrl = inc.artworkUrl;
        if (cur.feedUrl.length === 0) cur.feedUrl = inc.feedUrl;
        this.table.set(inc.key, cur);
      }
    }
    Log.i('ListenStats', `合并 ${incoming.length} 个频道(按设备取 max)`);
    this.persist();
    this.publish();
  }

  /// 首启种子:无既有统计时用历史做近似初值,记在共用 seed 格。
  seedFromHistory(history: HistoryEntry[]): void {
    if (this.table.size > 0 || history.length === 0) return;
    for (let i = 0; i < history.length; i++) {
      const h = history[i];
      const ms = h.played ? Math.max(h.durationMs, h.positionMs) : h.positionMs;
      if (ms <= 0) continue;
      const k = channelKeyOf(h.episode);
      let c = this.table.get(k);
      if (c === undefined) {
        c = {
          key: k, title: h.episode.podcastTitle, artworkUrl: h.episode.artworkUrl,
          feedUrl: h.episode.feedUrl, perDevice: {}
        };
      }
      const cur = c.perDevice[ListenStatsStore.SEED_KEY];
      c.perDevice[ListenStatsStore.SEED_KEY] = (cur === undefined ? 0 : cur) + ms;
      this.table.set(k, c);
    }
    Log.i('ListenStats', `种子 ${this.table.size} 个频道`);
    this.persist();
    this.publish();
  }

  private publish(): void {
    const list: ChannelListen[] = [];
    this.table.forEach((c: ChannelListen) => list.push(c));
    list.sort((a: ChannelListen, b: ChannelListen) => listenedMsOf(b) - listenedMsOf(a));
    this.stats = list;
  }

  private persist(): void {
    const arr: Object[] = [];
    this.table.forEach((c: ChannelListen) => arr.push(Codec.channelListenToJson(c, listenedMsOf(c))));
    JsonFile.writeJsonDebounced(ListenStatsStore.FILE, arr);
  }
}
