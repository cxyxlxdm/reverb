import { Episode, Podcast, HistoryEntry } from '../model/Models';
import { JsonFile } from './JsonFile';
import { Codec } from './Codec';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/// 订阅 / 收藏 / 历史 / 热门榜缓存。均为 @Observed,界面直接观察;
/// 每次改动先改内存态再落盘(与 Android/macOS 同一范式)。

@Observed
export class SubscriptionStore {
  subscriptions: Podcast[] = [];
  private static FILE = 'subscriptions.json';

  /**
   * 退订回调:让凭据随之作废。
   *
   * 凭据只服务于「还在订阅的私有源」——退订后用户已经把链接删了,再留着口令等于
   * 在磁盘上多存一份没用的密码。AppContainer 把它接到 `repository.forgetAuth`。
   */
  onRemoved: ((p: Podcast) => void) | null = null;

  load(): void {
    const arr = JsonFile.readArray(SubscriptionStore.FILE);
    const out: Podcast[] = [];
    for (let i = 0; i < arr.length; i++) {
      // 逐条判,坏的那一条只丢那一条:原先把非对象元素也交给 Codec,会得到一条**全空**的
      // 订阅(标题/封面/feedUrl 全空)挂在列表里 —— 它点不动、刷不动,还占一格
      // (见 REVIEW-2026-10-25 高-3 附带项:单条坏元素不该污染整份)。
      // feedUrl 是订阅的身份键(所有查找与退订都按它),空串等于这条根本不可用。
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const p = Codec.podcastFromJson(o);
      if (p.feedUrl.length === 0) continue;
      out.push(p);
    }
    this.subscriptions = out;
    Log.i('Store', `订阅加载 ${out.length} 条`);
  }

  isSubscribed(feedUrl: string): boolean {
    return this.subscriptions.some((p: Podcast) => p.feedUrl === feedUrl);
  }

  toggle(p: Podcast): void {
    const idx = this.subscriptions.findIndex((x: Podcast) => x.feedUrl === p.feedUrl);
    const next = this.subscriptions.slice();
    if (idx >= 0) {
      next.splice(idx, 1);
      Log.i('Store', `取消订阅 "${p.title}"`);
      if (this.onRemoved !== null) this.onRemoved(p);
    } else {
      next.unshift(p);
      Log.i('Store', `订阅 "${p.title}"`);
    }
    this.subscriptions = next;
    this.persist();
  }

  /// 合并语义:按 feedUrl 去重后尾部追加(备份恢复用)。
  addAll(items: Podcast[]): void {
    const next = this.subscriptions.slice();
    for (let i = 0; i < items.length; i++) {
      if (!next.some((x: Podcast) => x.feedUrl === items[i].feedUrl)) next.push(items[i]);
    }
    this.subscriptions = next;
    this.persist();
  }

  private persist(): void {
    const arr: Object[] = [];
    for (let i = 0; i < this.subscriptions.length; i++) arr.push(Codec.podcastToJson(this.subscriptions[i]));
    JsonFile.writeJson(SubscriptionStore.FILE, arr);
  }
}

@Observed
export class FavoriteStore {
  favorites: Episode[] = [];
  private static FILE = 'favorites.json';

  load(): void {
    const arr = JsonFile.readArray(FavoriteStore.FILE);
    const out: Episode[] = [];
    for (let i = 0; i < arr.length; i++) {
      // 同 SubscriptionStore:一条坏元素只丢那一条,不让它变成一个全空收藏挤在列表里
      // (见 REVIEW-2026-10-25 高-3 附带项)。id 是收藏的身份键(isFavorite / toggle 都按它),
      // 空 id 的条目点掉之后 findIndex 命中不了,界面上永远取消不掉。
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const e = Codec.episodeFromJson(o);
      if (e.id.length === 0) continue;
      out.push(e);
    }
    this.favorites = out;
    Log.i('Store', `收藏加载 ${out.length} 条`);
  }

  isFavorite(id: string): boolean {
    return this.favorites.some((e: Episode) => e.id === id);
  }

  toggle(e: Episode): void {
    const idx = this.favorites.findIndex((x: Episode) => x.id === e.id);
    const next = this.favorites.slice();
    if (idx >= 0) next.splice(idx, 1); else next.unshift(e);
    this.favorites = next;
    this.persist();
  }

  /// 合并语义:按 id 去重后尾部追加(备份恢复用)。
  addAll(items: Episode[]): void {
    const next = this.favorites.slice();
    for (let i = 0; i < items.length; i++) {
      if (!next.some((x: Episode) => x.id === items[i].id)) next.push(items[i]);
    }
    this.favorites = next;
    this.persist();
  }

  private persist(): void {
    const arr: Object[] = [];
    for (let i = 0; i < this.favorites.length; i++) arr.push(Codec.episodeToJson(this.favorites[i]));
    JsonFile.writeJson(FavoriteStore.FILE, arr);
  }
}

/// 播放历史:最近置顶,记录续播进度,最多 100 条。
@Observed
export class HistoryStore {
  history: HistoryEntry[] = [];
  private static FILE = 'history.json';
  private static MAX = 100;

  load(): void {
    const arr = JsonFile.readArray(HistoryStore.FILE);
    const out: HistoryEntry[] = [];
    for (let i = 0; i < arr.length; i++) {
      // 同收藏:一条坏记录只丢那一条(见 REVIEW-2026-10-25 高-3 附带项)。
      // 历史的身份键是 episode.id —— positionFor / isPlayed / updatePosition 都按它找,
      // 空 id 的记录既找不到也删不掉,还会把历史里的「已看过」判断带偏。
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const h = Codec.historyFromJson(o);
      if (h.episode.id.length === 0) continue;
      out.push(h);
    }
    this.history = out;
    Log.i('Store', `历史加载 ${out.length} 条`);
  }

  positionFor(id: string): number {
    const h = this.history.find((x: HistoryEntry) => x.episode.id === id);
    return h === undefined ? 0 : h.positionMs;
  }

  isPlayed(id: string): boolean {
    const h = this.history.find((x: HistoryEntry) => x.episode.id === id);
    return h === undefined ? false : h.played;
  }

  /// 开始播放某集:置顶,保留已有进度。
  record(e: Episode, nowMs: number): void {
    const existing = this.history.find((x: HistoryEntry) => x.episode.id === e.id);
    const next = this.history.filter((x: HistoryEntry) => x.episode.id !== e.id);
    next.unshift({
      episode: e,
      positionMs: existing === undefined ? 0 : existing.positionMs,
      durationMs: existing === undefined ? 0 : existing.durationMs,
      updatedAt: nowMs,
      played: existing === undefined ? false : existing.played
    });
    this.history = next.length > HistoryStore.MAX ? next.slice(0, HistoryStore.MAX) : next;
    this.persist();
  }

  /// 更新进度(不改顺序,避免频繁写导致列表抖动)。
  updatePosition(id: string, positionMs: number, durationMs: number): void {
    let hit = false;
    const next = this.history.map((x: HistoryEntry) => {
      if (x.episode.id !== id) return x;
      hit = true;
      return {
        episode: x.episode, positionMs: positionMs, durationMs: durationMs,
        updatedAt: x.updatedAt, played: x.played
      } as HistoryEntry;
    });
    if (!hit) return;
    this.history = next;
    this.persist();
  }

  markPlayed(id: string, played: boolean): void {
    let hit = false;
    const next = this.history.map((x: HistoryEntry) => {
      if (x.episode.id !== id || x.played === played) return x;
      hit = true;
      return {
        episode: x.episode, positionMs: x.positionMs, durationMs: x.durationMs,
        updatedAt: x.updatedAt, played: played
      } as HistoryEntry;
    });
    if (!hit) return;
    this.history = next;
    this.persist();
  }

  /// 备份恢复合并:同一集两边都有时**按 updatedAt 取更新的那条**,避免用旧备份把当前进度倒退。
  /// 先快照现状再比较(边并入边比较会失真);倒序导入使原本较新的记录最终位于前列。
  mergeAll(incoming: HistoryEntry[]): void {
    const snapshot = new Map<string, number>();
    for (let i = 0; i < this.history.length; i++) {
      snapshot.set(this.history[i].episode.id, this.history[i].updatedAt);
    }
    for (let i = incoming.length - 1; i >= 0; i--) {
      const h = incoming[i];
      // 时间戳口径归一(H86):本端是毫秒,macOS 端是秒 —— 1e11 以下按秒×1000
      // (现时秒级时间戳 ~1.8e9,毫秒级 ~1.8e12,阈值两侧都有足够余量)。
      // 不归一的话,macOS 备份恢复到本端会被整批判旧跳过,历史一条都进不来。
      const updatedAt = h.updatedAt > 0 && h.updatedAt < 100_000_000_000 ? h.updatedAt * 1000 : h.updatedAt;
      const cur = snapshot.get(h.episode.id);
      if (cur !== undefined && cur >= updatedAt) continue;
      this.record(h.episode, updatedAt);
      this.updatePosition(h.episode.id, h.positionMs, h.durationMs);
      if (h.played) this.markPlayed(h.episode.id, true);
    }
  }

  clear(): void {
    Log.i('Store', `清空历史(原 ${this.history.length} 条)`);
    this.history = [];
    this.persist();
  }

  /// 惰性落盘:播放中每 5 秒就更新一次进度,而这里是**整份历史写回**(可达几百 KB),
  /// 序列化推迟到去抖到期,连续多次只做一次(见 `JsonFile.writeJsonDebouncedLazy`)。
  private persist(): void {
    JsonFile.writeJsonDebouncedLazy(HistoryStore.FILE, (): Object => {
      const arr: Object[] = [];
      for (let i = 0; i < this.history.length; i++) arr.push(Codec.historyToJson(this.history[i]));
      return arr;
    });
  }
}

/// 热门榜磁盘缓存:单文件 + 启动一次性读入内存 Map(之后读取零 IO)。
/// 采用 Android 的形态(macOS 是每 key 一个文件、按需读盘)。
export class PopularCacheStore {
  private static FILE = 'popular_cache.json';
  private mem: Record<string, Podcast[]> = {};

  load(): void {
    const o = JsonFile.readObject(PopularCacheStore.FILE);
    if (o === null) return;
    const keys = Object.keys(o);
    for (let i = 0; i < keys.length; i++) {
      const raw = o[keys[i]];
      if (!Array.isArray(raw)) continue;
      const list: Podcast[] = [];
      const a = raw as Object[];
      for (let j = 0; j < a.length; j++) {
        // 同收藏/订阅:一条坏元素只丢那一条(见 REVIEW-2026-10-25 高-3 附带项)。
        // 榜单条目点进详情页靠 feedUrl 拉 RSS,空 feedUrl 的条目是一张点不开的卡片。
        const o = J.asObj(a[j]);
        if (o === null) continue;
        const p = Codec.podcastFromJson(o);
        if (p.feedUrl.length === 0) continue;
        list.push(p);
      }
      this.mem[keys[i]] = list;
    }
    Log.i('Store', `热门缓存加载 ${keys.length} 组`);
  }

  get(key: string): Podcast[] {
    const v = this.mem[key];
    return v === undefined ? [] : v;
  }

  /// 空列表不写(失败保留旧缓存,这是关键设计)。
  put(key: string, list: Podcast[]): void {
    if (list.length === 0) return;
    this.mem[key] = list;
    this.persist();
  }

  clear(): void {
    this.mem = {};
    JsonFile.remove(PopularCacheStore.FILE);
  }

  async sizeBytes(): Promise<number> {
    return JsonFile.sizeBytesAsync(PopularCacheStore.FILE);
  }

  private persist(): void {
    const out: Record<string, Object> = {};
    const keys = Object.keys(this.mem);
    for (let i = 0; i < keys.length; i++) {
      const list = this.mem[keys[i]];
      const arr: Object[] = [];
      for (let j = 0; j < list.length; j++) arr.push(Codec.podcastToJson(list[j]));
      out[keys[i]] = arr;
    }
    JsonFile.writeJsonDebounced(PopularCacheStore.FILE, out);
  }
}
