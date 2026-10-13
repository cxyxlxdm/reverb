import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/// 一条音频缓存记录。`f` 是**相对缓存目录的文件名**,不是绝对路径。
export interface AudioCacheItem {
  id: string;
  url: string;
  f: string;
  bytes: number;
  cachedAt: number;
  lastAccess: number;
}

/**
 * 「播过即缓存」的账本 `audio_cache.json`(与 Android `AudioCacheStore.kt` 同一形状)。
 *
 * 与 `downloads.json` 是**两份独立的账**,这是需求里明确要区分的一件事:
 *  - 下载 = 用户点名要留的,永久有效、进备份、由「清除下载」负责;
 *  - 缓存 = App 自己为「下次别联网」攒的,可被预算挤掉、**不进备份**、由「清除缓存」负责。
 * 连目录都不同(`downloads/` 与 `audio_cache/`),所以两侧清理不可能互删文件。
 *
 * 只记 id/url/文件名/字节数,**不整份抄 Episode**:缓存条目唯一用途是「这集的音频在不在本地、
 * 在哪个文件」;起播时那一集的元数据本来就来自列表。抄整份只会让文件随集数线性膨胀。
 *
 * **带版本号**(硬规矩 11):口径以后会变,而旧账在新版本里照样解析成功、只是每条都指不到文件 ——
 * 界面上就是「缓存莫名其妙空了」,用户没有自救入口。版本不符整体作废,不猜。
 */
export class AudioCacheStore {
  private static readonly FILE = 'audio_cache.json';
  private static readonly VERSION = 1;

  /// episodeId → 记录。整份写回的缓存类数据,所以持久化走惰性去抖(见 persist)。
  private items: Map<string, AudioCacheItem> = new Map();

  load(): void {
    const root = JsonFile.readObject(AudioCacheStore.FILE);
    if (root === null) return;
    const v = J.num(root, 'v');
    if (v !== AudioCacheStore.VERSION) {
      Log.w('AudioCache', `账本版本 v=${v} 与当前 ${AudioCacheStore.VERSION} 不符,整体作废`);
      return;
    }
    const arr = J.arr(root, 'items');
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const id = J.str(o, 'id');
      const f = J.str(o, 'f');
      if (id.length === 0 || f.length === 0) continue;
      this.items.set(id, {
        id: id,
        url: J.str(o, 'url'),
        f: f,
        bytes: J.num(o, 'bytes'),
        cachedAt: J.num(o, 'cachedAt'),
        lastAccess: J.num(o, 'lastAccess')
      });
    }
    Log.i('AudioCache', `账本加载 ${this.items.size} 条`);
  }

  get(id: string): AudioCacheItem | null {
    const it = this.items.get(id);
    return it === undefined ? null : it;
  }

  put(id: string, url: string, fileName: string, bytes: number): void {
    const now = Date.now();
    this.items.set(id, { id: id, url: url, f: fileName, bytes: bytes, cachedAt: now, lastAccess: now });
    this.persist();
  }

  /**
   * 记一次「这一集真的从缓存里起播了」—— **LRU 的那个 L 全靠它**。
   * 淘汰只看 lastAccess,而「用过」只发生在起播那一刻;只在写入时更新的话,
   * 一条反复听的集会因 cachedAt 太旧而被优先挤掉,预算就白设了。
   */
  touch(id: string): void {
    const it = this.items.get(id);
    if (it === undefined) return;
    it.lastAccess = Date.now();
    this.persist();
  }

  remove(id: string): string | null {
    const it = this.items.get(id);
    if (it === undefined) return null;
    this.items.delete(id);
    this.persist();
    return it.f;
  }

  clearAll(): void {
    this.items.clear();
    this.persist();
  }

  count(): number {
    return this.items.size;
  }

  /// 全部记录,按最后一次访问**升序**(淘汰从头部开始)。
  byLeastRecent(): AudioCacheItem[] {
    const out: AudioCacheItem[] = [];
    this.items.forEach((v: AudioCacheItem) => { out.push(v); });
    out.sort((a: AudioCacheItem, b: AudioCacheItem): number => a.lastAccess - b.lastAccess);
    return out;
  }

  /// 账本里的文件名集合(对账用)。
  fileNames(): string[] {
    const out: string[] = [];
    this.items.forEach((v: AudioCacheItem) => { out.push(v.f); });
    return out;
  }

  /// 惰性去抖写:整份写回的数据,**取值也要一起推迟**(硬规矩 8,同 FeedCacheStore)。
  private persist(): void {
    JsonFile.writeJsonDebouncedLazy(AudioCacheStore.FILE, (): Object => {
      const arr: Object[] = [];
      this.items.forEach((v: AudioCacheItem) => {
        arr.push({
          'id': v.id, 'url': v.url, 'f': v.f,
          'bytes': v.bytes, 'cachedAt': v.cachedAt, 'lastAccess': v.lastAccess
        } as Record<string, Object>);
      });
      const root: Record<string, Object> = { 'v': AudioCacheStore.VERSION, 'items': arr };
      return root;
    });
  }
}
