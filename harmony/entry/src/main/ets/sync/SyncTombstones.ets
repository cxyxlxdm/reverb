import { JsonFile } from '../store/JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/**
 * 删除墓碑账本:让「这台设备上删掉的条目」不会在下一次同步时被对端带回来。
 *
 * 与 Android `sync/SyncTombstones.kt` **逐字对齐**(文件格式、键名、90 天保留期、
 * 订阅键的归一化判据)。同步传的就是同一份 `tombstones` 数组,少一套格式就少一处
 * "两端对同一件事有两套理解"。
 *
 * 形状只有一个:按 `kind + id` 记 `deletedAt`(毫秒),保留 90 天:
 *  - 只记**可删除的集合**:订阅 / 收藏 / 印记 / 批注。历史是 LWW、收听统计按设备取 max,
 *    它们本来就不是"删一条"的语义;
 *  - 订阅的 id 用 **feedUrl 归一化**后的串(与同步去重同一个判据),因为同一频道在不同端
 *    可能一个用 `collectionId`、一个用 `feedUrl` 当 `id`;
 *  - 本地**重新添加**同一项时清掉墓碑(用户改主意了,不能还被自己 90 天前的删除压着)。
 *
 * 已知边界(与 Android / Apple 同一条):墓碑**优先于**对端快照里的同 id 条目 ——
 * 订阅与收藏没有 `updatedAt`,"重新添加"无法证明自己比删除更晚。彻底解决要 HLC,
 * 见研究文档 §5。
 *
 * 落盘走 `JsonFile`(原子替换的 tmp + rename)。账本是派生数据:读坏了按空处理,
 * 最坏结果是"这一次同步可能复活一条已删项",不值得像订阅那样留证与服务降级。
 */
interface TombstoneEntry {
  kind: string;
  id: string;
  deletedAt: number;
}

export class SyncTombstones {
  static readonly SUBSCRIPTIONS: string = 'subscriptions';
  static readonly FAVORITES: string = 'favorites';
  static readonly STAMPS: string = 'stamps';
  static readonly NOTES: string = 'notes';

  private static readonly FILE: string = 'sync_tombstones.json';
  private static readonly RETENTION_MS: number = 90 * 24 * 60 * 60 * 1000;
  private static readonly SEP: string = '\u0000';

  private static loaded: boolean = false;
  /** key = kind + SEP + id,value = deletedAt(毫秒)。 */
  private static entries: Map<string, number> = new Map<string, number>();

  private static ensureLoaded(): void {
    if (SyncTombstones.loaded) return;
    SyncTombstones.loaded = true;
    const root = JsonFile.readObject(SyncTombstones.FILE);
    if (root === null) return;
    const arr = J.arr(root, 'items');
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const kind = J.str(o, 'kind');
      const id = J.str(o, 'id');
      const at = J.num(o, 'deletedAt');
      if (kind.length === 0 || id.length === 0 || at <= 0) continue;
      SyncTombstones.entries.set(SyncTombstones.key(kind, id), at);
    }
    SyncTombstones.prune(Date.now());
    Log.i('Sync', `墓碑账本加载 ${SyncTombstones.entries.size} 条`);
  }

  static record(kind: string, id: string, now: number = Date.now()): void {
    if (kind.length === 0 || id.length === 0) return;
    SyncTombstones.ensureLoaded();
    SyncTombstones.prune(now);
    SyncTombstones.entries.set(SyncTombstones.key(kind, id), now);
    SyncTombstones.save();
  }

  /** 本地重新添加时调用:墓碑清掉,否则下一次同步会把这项再删一次。 */
  static clear(kind: string, id: string): void {
    if (kind.length === 0 || id.length === 0) return;
    SyncTombstones.ensureLoaded();
    const k = SyncTombstones.key(kind, id);
    if (SyncTombstones.entries.delete(k)) SyncTombstones.save();
  }

  /**
   * 并入远端快照里的 `tombstones`(可以没有),剪掉过期项并落盘。
   * 返回后 `ids(kind)` 就是"两边合起来仍然有效的删除"。
   *
   * 远端条目用 `J` 宽松读取:对端可能是 Android / Apple,少一个字段只丢那一条,
   * 不整份作废 —— 与 `LanSyncMerge.filterSection` 同一条读取口径。
   */
  static merge(remote: TombstoneEntry[] | null, now: number = Date.now()): void {
    SyncTombstones.ensureLoaded();
    if (remote !== null) {
      for (let i = 0; i < remote.length; i++) {
        const o = remote[i];
        const kind = o.kind;
        const id = o.id;
        const at = o.deletedAt;
        if (kind === undefined || id === undefined || at === undefined) continue;
        if (kind.length === 0 || id.length === 0 || at <= 0) continue;
        const k = SyncTombstones.key(kind, id);
        const prev = SyncTombstones.entries.get(k);
        if (prev === undefined || at > prev) SyncTombstones.entries.set(k, at);
      }
    }
    SyncTombstones.prune(now);
    SyncTombstones.save();
  }

  static ids(kind: string, now: number = Date.now()): Set<string> {
    SyncTombstones.ensureLoaded();
    SyncTombstones.prune(now);
    const out = new Set<string>();
    SyncTombstones.entries.forEach((at: number, k: string) => {
      const pair = SyncTombstones.decode(k);
      if (pair !== null && pair[0] === kind) out.add(pair[1]);
    });
    return out;
  }

  /** 快照里要带的那一段。空账本也返回空数组 —— 形状固定,对端不必判空。 */
  static snapshot(now: number = Date.now()): TombstoneEntry[] {
    SyncTombstones.ensureLoaded();
    SyncTombstones.prune(now);
    const out: TombstoneEntry[] = [];
    SyncTombstones.entries.forEach((at: number, k: string) => {
      const pair = SyncTombstones.decode(k);
      if (pair === null) return;
      out.push({ kind: pair[0], id: pair[1], deletedAt: at } as TombstoneEntry);
    });
    return out;
  }

  /** 订阅的墓碑键:`feedUrl` 归一化优先,没有可用 URL 时退回频道 id(与同步去重同一判据)。 */
  static subscriptionKey(feedUrl: string, fallbackId: string): string {
    const n = SyncTombstones.normalizeFeed(feedUrl);
    return n.length > 0 ? n : fallbackId;
  }

  /**
   * 认源不认写法:尾部斜杠与**协议/主机名**大小写不该让同一个源变成两条。
   * 路径部分大小写敏感,不能一起小写。与 Android `normalizeFeed` / Apple 端逐条一致。
   */
  static normalizeFeed(feedUrl: string): string {
    const t = feedUrl.trim();
    if (t.length === 0) return '';
    let stripped = t;
    if (stripped.endsWith('/')) stripped = stripped.substring(0, stripped.length - 1);
    const m = /^([a-zA-Z][a-zA-Z0-9+.\-]*:\/\/)([^/?#]*)/.exec(stripped);
    if (m !== null) {
      const head = m[1].toLowerCase() + m[2].toLowerCase();
      return head + stripped.substring(m[0].length);
    }
    return stripped;
  }

  private static key(kind: string, id: string): string {
    return kind + SyncTombstones.SEP + id;
  }

  private static decode(k: string): string[] | null {
    const i = k.indexOf(SyncTombstones.SEP);
    if (i <= 0 || i === k.length - 1) return null;
    return [k.substring(0, i), k.substring(i + 1)];
  }

  private static prune(now: number): void {
    const cutoff = now - SyncTombstones.RETENTION_MS;
    const dead: string[] = [];
    SyncTombstones.entries.forEach((at: number, k: string) => {
      if (at < cutoff) dead.push(k);
    });
    for (let i = 0; i < dead.length; i++) SyncTombstones.entries.delete(dead[i]);
  }

  private static save(): void {
    const arr: TombstoneEntry[] = SyncTombstones.snapshot();
    const out: Record<string, Object> = {};
    out['version'] = 1;
    out['items'] = arr;
    JsonFile.writeJson(SyncTombstones.FILE, out);
  }
}
