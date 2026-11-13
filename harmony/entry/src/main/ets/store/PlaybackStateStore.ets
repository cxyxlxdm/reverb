import { Episode } from '../model/Models';
import { Codec } from './Codec';
import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

const FILE_NAME = 'playback_state.json';
/// 口径变了要让旧数据作废时改这里(硬规矩 11)。目前只有一版。
const VERSION = 1;
/// 上下文窗口:当前集前后各留这么多集。
const CONTEXT_HALF = 40;
/// up next 的条数上限:超出截断队尾(没人真会排 300 集,留这个数是防文件无限长)。
const UP_NEXT_CAP = 300;

/** 读回来的原样快照;字段含义见 `PlaybackStateStore.save`。 */
export class PlaybackSnapshot {
  current: Episode | null = null;
  listTag: string = '';
  context: Episode[] = [];
  contextIndex: number = 0;
  upNext: Episode[] = [];

  isEmpty(): boolean {
    return this.current === null && this.upNext.length === 0;
  }
}

/**
 * 一份「正在播什么」的跨启动快照(`playback_state.json`),与 Android
 * `data/local/PlaybackStateStore.kt` **同名同格式同文件名**(2026-10-06 从 Android 移植)。
 *
 * 存三样东西,缺一样就会露出用户报的那种症状:
 *  - `current`:正在播(或上次在播)的那一集 —— 没有它,迷你播放条在冷启动后整条不出现,
 *    用户只能回历史里凭标题把那集再点一次;
 *  - `context` + `contextIndex`:**这一集来自哪一列** —— 没有它,重启后「上一集/下一集」
 *    与「播完自动接下一集」全部失效,而系列节目恰恰靠这两条连着听;
 *  - `upNext`:用户手动排的队列 —— 就是那条反馈的本体(此前只在内存里,进程结束即丢)。
 *
 * 为什么不进任何备份(与 Android 同判据):队列与「正在播哪一集」是**这台设备上的一次性排程**,
 * 换机/恢复后大概率已经过期;而里面每一集都能从历史或订阅里找回,没有任何东西会永久丢失。
 * (批注 `notes.json` 正相反 —— 那是用户写出来的字,所以它进白名单。)
 * 也不占手动备份的 8 分区:那 8 项的顺序是三端 `reverb-backup.json` 的互通契约,不为临时态动它。
 * 所以 `backup_config.json` 里**刻意没有这个文件名**,别在补白名单时顺手加进去。
 */
export class PlaybackStateStore {
  snapshot: PlaybackSnapshot = new PlaybackSnapshot();

  /**
   * 从盘上读回。**由 AppContainer.boot 调用**(那时 `JsonFile.init` 才刚做完),
   * 不能在构造时读 —— 构造发生在 boot 之前,那个时刻 filesDir 还是空串,
   * 症状是"永远读不到、又没有任何报错"。
   */
  load(): void {
    this.snapshot = PlaybackStateStore.readFromDisk();
    const s = this.snapshot;
    Log.i('State', `启动读回播放态 cur=${s.current === null ? '-' : s.current.id} ` +
      `ctx=${s.context.length}@${s.contextIndex} upNext=${s.upNext.length} tag='${s.listTag}'`);
  }

  /**
   * 落一份当前播放态。**同步写**(`JsonFile.writeJson` → `fs.writeSync`):与订阅/收藏/批注同口径。
   *
   * 为什么在这里不用 `writeJsonDebouncedLazy`:去抖的代价正是「进程被杀时丢掉窗口内那一次」,
   * 而这条反馈报的就是"排好队、切出去再回来就没了" —— 用去抖写会把同一个症状留在原地。
   * UI 线程这一笔的体量由下面两道裁剪兜住(整份上限约几百 KB,且只在用户动作时写,不在渲染路径里)。
   *
   * [context] 收**整条**列上下文,裁剪在这里做(硬规矩 10:不变式在数据出口保证):
   * 只保留以 [contextIndex] 为中心的 ±[CONTEXT_HALF] 集。理由是一份 RSS 常有上千集,
   * 整列落盘就是每次动作同步写几 MB —— 那是 H65 那笔账的同一个形状。
   * 代价:重启后连续按「上一集/下一集」超出窗口会到边界(按钮置灰),重新点一下列表即拿回全量。
   */
  save(current: Episode | null, listTag: string, context: Episode[], contextIndex: number, upNext: Episode[]): void {
    const cur: Episode | null = current !== null && current.audioUrl.length > 0 ? current : null;
    if (cur === null && upNext.length === 0) {
      this.clear();
      return;
    }
    const full: Episode[] = context.filter((e: Episode) => e.audioUrl.length > 0);
    let idx = -1;
    if (cur !== null) {
      for (let i = 0; i < full.length; i++) if (full[i].id === cur.id) { idx = i; break; }
    }
    if (idx < 0) {
      // 上下文里找不到正在播的那一集(例如「下一个播放」摘出来单播,上下文只有它自己)
      // 时才走这里;此时以传入的下标为准,别硬把 0 当答案。
      idx = (contextIndex >= 0 && contextIndex < full.length) ? contextIndex : 0;
    }
    const from = Math.max(0, idx - CONTEXT_HALF);
    const to = Math.min(full.length - 1, idx + CONTEXT_HALF);
    const kept = (from > 0 || to < full.length - 1) ? full.slice(from, to + 1) : full;
    const queued = upNext.length > UP_NEXT_CAP ? upNext.slice(0, UP_NEXT_CAP) : upNext;
    const localIndex = idx - from;

    const ctxArr: Object[] = [];
    for (let i = 0; i < kept.length; i++) ctxArr.push(PlaybackStateStore.slim(kept[i]));
    const upArr: Object[] = [];
    for (let i = 0; i < queued.length; i++) upArr.push(PlaybackStateStore.slim(queued[i]));
    const body: Record<string, Object> = {
      'version': VERSION,
      'listTag': listTag,
      'contextIndex': localIndex,
      'context': ctxArr,
      'upNext': upArr
    };
    // 只有 current 带完整字段(含简介):播放页要画节目简介,而列表行与队列页不读它。
    if (cur !== null) body['current'] = Codec.episodeToJson(cur);

    this.snapshot = PlaybackStateStore.snapshotOf(cur, listTag, kept, localIndex, queued);
    JsonFile.writeJson(FILE_NAME, body);
    Log.i('State', `落盘播放态 cur=${cur === null ? '-' : cur.id} ctx=${kept.length}@${localIndex}` +
      `(全列 ${full.length}) upNext=${queued.length} tag='${listTag}'`);
  }

  /** 清空:退电台、播完、数据无效时都落到「没有可恢复的东西」这个状态,而不是留一份半成品。 */
  clear(): void {
    this.snapshot = new PlaybackSnapshot();
    JsonFile.remove(FILE_NAME);
  }

  /**
   * 列表条目用的**瘦身版**序列化:去掉 `description`(节目简介)。
   *
   * 理由是体量:简介常有 1~5 KB,而这一份快照一次要写 上下文 81 条 + 队列最多 300 条,
   * 带着简介就是**每次用户动作同步写几百 KB 到上限 1 MB 级**(冷启动读回时 `load()` 也在 UI 线程,
   * 那份体量会变成启动耗时)。列表行与队列页只需要标题/频道名/时长/封面/音频地址,
   * 简介在下次刷新 feed 时自然回来;唯一真需要它的是"正在播那一集"的播放页,所以那份保留完整字段。
   */
  private static slim(e: Episode): Record<string, Object> {
    return {
      'id': e.id, 'title': e.title, 'audioUrl': e.audioUrl, 'artworkUrl': e.artworkUrl,
      'podcastTitle': e.podcastTitle, 'durationSec': e.durationSec, 'pubDate': e.pubDate,
      'feedUrl': e.feedUrl, 'transcriptUrl': e.transcriptUrl, 'transcriptType': e.transcriptType,
      // 章表地址必须在这里:冷启动恢复的"正在播那一集"就是播放页上那一集,
      // 缺了它,重启后章节入口整条消失(Android 2026-11-11 装机验收抓到)
      'chaptersUrl': e.chaptersUrl, 'chaptersType': e.chaptersType
    };
  }

  private static snapshotOf(cur: Episode | null, listTag: string, context: Episode[],
                             contextIndex: number, upNext: Episode[]): PlaybackSnapshot {
    const s = new PlaybackSnapshot();
    s.current = cur;
    s.listTag = listTag;
    s.context = context;
    s.contextIndex = contextIndex;
    s.upNext = upNext;
    return s;
  }

  /** 公开给服务卡片的 FormExtensionAbility:它在独立进程里,只能按同一份文件自己读一遍。 */
  static readFromDisk(): PlaybackSnapshot {
    const out = new PlaybackSnapshot();
    const root = JsonFile.readObject(FILE_NAME);
    if (root === null) return out;
    // 逐键宽容解析:这份文件是跨版本边界,任何一键坏掉都不该让整份读不出来
    // (H86 那个坑的同一形状 —— 只是这里失败的方向是"重启后没有播放栏")。
    if (J.num(root, 'version') > VERSION) {
      // 新格式被老版本读到:整份作废,别拿半懂不懂的字段去恢复播放态
      Log.w('State', `播放态 version=${J.num(root, 'version')} > ${VERSION},忽略`);
      return out;
    }
    const curObj = J.obj(root, 'current');
    if (curObj !== null) {
      const cur = Codec.episodeFromJson(curObj);
      if (cur.audioUrl.length > 0) out.current = cur;
    }
    out.upNext = PlaybackStateStore.readList(J.arr(root, 'upNext'));
    out.context = PlaybackStateStore.readList(J.arr(root, 'context'));
    let idx = J.num(root, 'contextIndex');
    // 位置以「current 在上下文里的那一格」为准自我纠正:窗口裁剪与版本升级都可能让存的
    // 下标对不上,而对不上的后果是上一集/下一集整条错位在另一列里跳。
    if (out.current !== null) {
      for (let i = 0; i < out.context.length; i++) {
        if (out.context[i].id === out.current.id) { idx = i; break; }
      }
    }
    if (out.context.length === 0) idx = 0;
    else if (idx < 0 || idx >= out.context.length) idx = 0;
    out.contextIndex = idx;
    out.listTag = J.str(root, 'listTag');
    return out;
  }

  private static readList(arr: Object[]): Episode[] {
    const out: Episode[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const e = Codec.episodeFromJson(o);
      // 没有可播地址的条目直接跳过:恢复出一条点不动的"正在播",比不恢复更让人怀疑是 bug
      if (e.audioUrl.length === 0) continue;
      out.push(e);
    }
    return out;
  }
}
