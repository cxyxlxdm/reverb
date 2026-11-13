import { AppContainer } from '../AppContainer';
import { BackupManager, BackupSection } from '../store/BackupManager';
import { J } from '../net/Http';
import { SyncTombstones } from './SyncTombstones';
import { LanSyncException, LanSyncFail } from './LanSyncWire';
import { Log } from '../util/Logger';

interface TombstoneLike {
  kind: string;
  id: string;
  deletedAt: number;
}

/**
 * 同步用的合并策略 = **备份 v1 的合并语义 + 一道订阅去重 + 删除墓碑**。
 *
 * 与 Android `sync/LanSyncMerge.kt` 逐条同构。为什么不另发明一套数据结构:备份 v1 的
 * 六个分区本来就在四端之间互通,且 `BackupManager.applyRoot` 里已经有冲突解法的成文规则
 * (历史按 `updatedAt` 取新、收听统计按设备取 max)。同步传的就是同一份 JSON ——
 * 少一套格式,就少一处"两端对同一件事有两套理解"。
 *
 * 唯一补的一步:`BackupManager` 的订阅去重按 **feedUrl**,而同一个 RSS 源从 Apple 目录
 * 加进来时 id 是 `collectionId`、从 OPML/RSS 直接加进来时 id 是 `feedUrl`。两边各自加过
 * 这个频道时,id 不同但其实是同一个源 —— 不先去重,一次同步就会出现两条一模一样的频道。
 *
 * **删除会传播**:快照里另带一段 `tombstones`(见 [SyncTombstones]),四个可删除的集合
 * (订阅 / 收藏 / 印记 / 批注)删除后保留 90 天。合并时先把两边墓碑并起来,再:
 *  ① 删掉本端还被墓碑指着的条目;② 把远端快照里同 id 的条目剔掉;③ 才交给 `applyRoot` 取并集。
 *
 * 已知边界:墓碑**优先于**对端快照里的同 id 条目 —— 订阅与收藏没有 `updatedAt`,
 * 无法证明"重新添加"比"删除"更晚。彻底解决要 HLC,见研究文档 §5。
 */
export class LanSyncMerge {
  static readonly SECTIONS: BackupSection[] = [
    BackupSection.SUBSCRIPTIONS,
    BackupSection.FAVORITES,
    BackupSection.STAMPS,
    BackupSection.NOTES,
    BackupSection.HISTORY,
    BackupSection.LISTEN_STATS
  ];

  /** 本端参与同步的分区快照(下载与设置**不在其中**:下载是这台设备的选择,设置是这台设备的偏好)。 */
  static async build(app: AppContainer): Promise<string> {
    const base = await BackupManager.build(app, LanSyncMerge.SECTIONS);
    try {
      const root = JSON.parse(base) as Record<string, Object>;
      // 全量快照必须带墓碑:对端拿这份恢复/合并时,没有墓碑就仍会把旧条目带回来。
      root['tombstones'] = SyncTombstones.snapshot() as Object;
      return JSON.stringify(root);
    } catch (e) {
      Log.w('LanSync.Merge', `快照附加墓碑失败,按原样发送:${(e as Error).message}`);
      return base;
    }
  }

  /**
   * 把远端快照并入本端,返回**各分区新增的条数**。
   *
   * 新增数按"合并前后集合大小之差"算,不是按远端条数算 —— 远端带 100 条而本端已有 90 条时,
   * 界面上写"新增 100"就是在说假话。
   */
  static async apply(app: AppContainer, remoteJson: string): Promise<Int32Array> {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(remoteJson) as Record<string, Object>;
    } catch (e) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, '远端快照不是合法 JSON');
    }

    // ① 两边墓碑取并集(同时也把过期的剪掉)。
    const remoteTombstones = LanSyncMerge.readTombstones(root);
    SyncTombstones.merge(remoteTombstones);
    const deadSubs = SyncTombstones.ids(SyncTombstones.SUBSCRIPTIONS);
    const deadFavs = SyncTombstones.ids(SyncTombstones.FAVORITES);
    const deadStamps = SyncTombstones.ids(SyncTombstones.STAMPS);
    const deadNotes = SyncTombstones.ids(SyncTombstones.NOTES);

    // ② 本端还被墓碑指着的条目先删掉(这可能是一次早先同步留下的"复活",在这次同步里对上)。
    LanSyncMerge.pruneLocal(app, deadSubs, deadFavs, deadStamps, deadNotes);

    // ③ 远端快照里同 id 的条目剔掉,剩下的才参与并集。
    LanSyncMerge.filterSection(root, 'subscriptions', deadSubs, (o: Record<string, Object>): string => {
      return SyncTombstones.subscriptionKey(J.str(o, 'feedUrl'), J.str(o, 'id'));
    });
    LanSyncMerge.filterSection(root, 'favorites', deadFavs,
      (o: Record<string, Object>): string => J.str(o, 'id'));
    LanSyncMerge.filterSection(root, 'stamps', deadStamps,
      (o: Record<string, Object>): string => J.str(o, 'episodeId'));
    LanSyncMerge.filterSection(root, 'notes', deadNotes,
      (o: Record<string, Object>): string => J.str(o, 'noteId'));

    // 新增数从"删掉本地复活条目之后"起算,否则会报一个负数再被夹成 0。
    const before = LanSyncMerge.counts(app);
    const deduped = LanSyncMerge.dedupeSubscriptions(app, root);
    BackupManager.applyRoot(app, deduped, LanSyncMerge.SECTIONS);
    const after = LanSyncMerge.counts(app);
    const out = new Int32Array(before.length);
    for (let i = 0; i < before.length; i++) out[i] = Math.max(0, after[i] - before[i]);
    return out;
  }

  private static readTombstones(root: Record<string, Object>): TombstoneLike[] | null {
    const arr = J.arr(root, 'tombstones');
    if (arr.length === 0) return null;
    const out: TombstoneLike[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      out.push({
        kind: J.str(o, 'kind'),
        id: J.str(o, 'id'),
        deletedAt: J.num(o, 'deletedAt')
      } as TombstoneLike);
    }
    return out;
  }

  /**
   * 删掉本端仍存在、但两边墓碑已经判死的条目。
   * 走各 store 自己的删除入口 —— 它们会顺手把墓碑补记一次(同 kind/id),不会丢信息。
   */
  private static pruneLocal(
    app: AppContainer,
    deadSubs: Set<string>,
    deadFavs: Set<string>,
    deadStamps: Set<string>,
    deadNotes: Set<string>
  ): void {
    if (deadSubs.size > 0) {
      const victims = app.subscriptions.subscriptions.filter(
        (p) => deadSubs.has(SyncTombstones.subscriptionKey(p.feedUrl, p.id)));
      for (let i = 0; i < victims.length; i++) app.subscriptions.toggle(victims[i]);
    }
    if (deadFavs.size > 0) {
      const victims = app.favorites.favorites.filter((e) => deadFavs.has(e.id));
      for (let i = 0; i < victims.length; i++) app.favorites.toggle(victims[i]);
    }
    if (deadStamps.size > 0) {
      const ids = app.stamps.stamps.filter((s) => deadStamps.has(s.episodeId))
        .map((s): string => s.episodeId);
      for (let i = 0; i < ids.length; i++) app.stamps.remove(ids[i]);
    }
    if (deadNotes.size > 0) {
      const ids = app.notes.notes.filter((n) => deadNotes.has(n.noteId)).map((n): string => n.noteId);
      for (let i = 0; i < ids.length; i++) app.notes.remove(ids[i]);
    }
  }

  /** 只保留"墓碑没判死"的条目;剔空了就整段删掉。 */
  private static filterSection(
    root: Record<string, Object>,
    name: string,
    dead: Set<string>,
    keyOf: (o: Record<string, Object>) => string
  ): void {
    if (dead.size === 0) return;
    const arr = J.arr(root, name);
    if (arr.length === 0) return;
    const kept: Object[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const k = keyOf(o);
      if (k.length > 0 && dead.has(k)) continue;
      kept.push(o);
    }
    root[name] = kept;
  }

  static counts(app: AppContainer): Int32Array {
    const out = new Int32Array(6);
    out[0] = app.subscriptions.subscriptions.length;
    out[1] = app.favorites.favorites.length;
    out[2] = app.stamps.stamps.length;
    out[3] = app.notes.notes.length;
    out[4] = app.history.history.length;
    out[5] = app.listenStats.snapshot().length;
    return out;
  }

  /**
   * 订阅按 feedUrl 去重。远端 JSON 里**只保留本端没有的源**,以及远端自身第一次出现的源。
   * 其余分区原样带回 —— 这一步只解决"A 端用 collectionId、B 端用 feedUrl"这一种重复。
   */
  private static dedupeSubscriptions(app: AppContainer, root: Record<string, Object>): Record<string, Object> {
    const arr = J.arr(root, 'subscriptions');
    if (arr.length === 0) return root;
    const seen = new Set<string>();
    const local = app.subscriptions.subscriptions;
    for (let i = 0; i < local.length; i++) {
      const n = SyncTombstones.normalizeFeed(local[i].feedUrl);
      if (n.length > 0) seen.add(n);
    }
    const kept: Object[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const feed = SyncTombstones.normalizeFeed(J.str(o, 'feedUrl'));
      if (feed.length > 0 && seen.has(feed)) continue;
      if (feed.length > 0) seen.add(feed);
      kept.push(o);
    }
    root['subscriptions'] = kept;
    return root;
  }
}
