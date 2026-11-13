import { Chapter } from '../model/Models';
import { ChaptersFetcher } from '../net/ChaptersFetcher';
import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/**
 * 章节弹层的状态。与 Android `ChapterStore.State` 一一对应:
 * - `Empty` 与 `Failed` 必须分开 —— 前者是"这集确实没有章节"(不摆重试),
 *   后者是"取不到"(要能再点一次);混成一个,用户就会对一个永远重试不好的按钮点。
 */
export enum ChapterState {
  Idle = 0,
  Loading = 1,
  Done = 2,
  Empty = 3,
  Failed = 4
}

/// 一条章表缓存。`url` 参与命中判据(见 `readCache` 的注释)。
class CachedChapters {
  version: number;
  url: string;
  fetchedAt: number;
  chapters: Chapter[];

  constructor(version: number, url: string, fetchedAt: number, chapters: Chapter[]) {
    this.version = version;
    this.url = url;
    this.fetchedAt = fetchedAt;
    this.chapters = chapters;
  }
}

/**
 * 章节表的状态机与缓存。与 Android `data/local/ChapterStore.kt`、
 * `TranscriptStore` 同一种形状:切集即重置、命中缓存秒显、失败可重试。
 *
 * **缓存不进备份**:章表能从 RSS 再取一遍,与逐字稿/音频缓存同待遇。
 * 为什么值得落盘:章节的价值恰好在"已经下载好、正在离线听"的时候最大 ——
 * 每次点开都现取一次,飞行模式下就永远只有"加载失败"。
 *
 * 与逐字稿不同,**没有代次流水线**:章表只有"一次请求 → 一份列表",没有流式输出。
 * 但请求仍可能晚回来(或用户中途切集),所以回来时要再核一次 `episodeId`。
 *
 * 缓存形态与 Android 不同:Android 是一集一个文件,本端用**单文件**
 * (章表极小,整份写也就几十 KB;`JsonFile` 的原子写比一目录碎文件更好管)。
 * 格式不跨端互通 —— 它是可再生的缓存,不在备份里。
 */
@Observed
export class ChapterStore {
  /** 界面直接观察这两个 */
  state: ChapterState = ChapterState.Idle;
  chapterList: Chapter[] = [];
  /**
   * 当前状态属于哪一集。公开出来是让界面自己判断"这份列表是不是当前这一集的" ——
   * 切集后入口还在、列表却还是上一集的,比没入口更让人怀疑点错了。
   */
  episodeId: string = '';

  /// 私有订阅的凭据查询(章表常挂在订阅源同域下)。由 AppContainer 注入。
  authHeaderProvider: ((url: string) => string | null) | null = null;

  private static readonly FILE: string = 'chapters_cache.json';
  /**
   * 缓存条数上限。章表每集几十条标题,80 集也就几十 KB —— 按最近使用淘汰。
   */
  private static readonly MAX_ENTRIES: number = 80;
  /**
   * 缓存口径版本。字段形状一变就加一 —— 旧文件读出来是"能解析但缺字段"的章,
   * 那种错不会崩,只会显示一片空白(与 `TranscriptStore.CACHE_VERSION` 同一条,硬规矩 11)。
   */
  private static readonly CACHE_VERSION: number = 1;
  private static readonly TAG: string = 'Chapters';

  private cache: Record<string, CachedChapters> = {};
  private cacheLoaded: boolean = false;
  /**
   * 请求代次。切集/重试都自增;晚回来的请求发现代次变了就悄悄退出 ——
   * 光靠"忽略当前状态"不够,旧结果会覆盖新集的列表。
   */
  private generation: number = 0;

  /**
   * 从盘上读回缓存。由 AppContainer.boot 调用(**纯本地读**,不联网)。
   * 也可以懒读,但放在 boot 里与其它 store 同一节奏,免得第一次点开章节时多一次同步 IO。
   */
  load(): void {
    if (this.cacheLoaded) return;
    this.cacheLoaded = true;
    const root = JsonFile.readObject(ChapterStore.FILE);
    if (root === null) return;
    const keys = Object.keys(root);
    for (let i = 0; i < keys.length; i++) {
      const o = J.asObj(root[keys[i]]);
      if (o === null) continue;
      const arr = J.arr(o, 'chapters');
      const list: Chapter[] = [];
      for (let k = 0; k < arr.length; k++) {
        const co = J.asObj(arr[k]);
        if (co === null) continue;
        list.push({
          startMs: J.num(co, 'startMs'),
          title: J.str(co, 'title'),
          imageUrl: J.str(co, 'imageUrl'),
          url: J.str(co, 'url')
        } as Chapter);
      }
      this.cache[keys[i]] = new CachedChapters(
        J.num(o, 'version'), J.str(o, 'url'), J.num(o, 'fetchedAt'), list);
    }
    Log.i(ChapterStore.TAG, `章节缓存加载 ${Object.keys(this.cache).length} 集`);
  }

  /**
   * 切到某一集。只重置内存状态,**不自动请求** —— 章表弹层要用户点开才有意义,
   * 冷启动时没有人看得见那份列表(与 Android 同一条)。
   */
  prepare(episodeId: string): void {
    if (episodeId === this.episodeId) return;
    this.generation += 1;          // 让在途请求失效
    this.episodeId = episodeId;
    this.chapterList = [];
    this.state = ChapterState.Idle;
  }

  /**
   * 用户点开章节弹层时调用。命中缓存秒显;已成功或正在跑就不重复请求;失败过的允许再点一次。
   */
  async loadFor(episodeId: string, chaptersUrl: string): Promise<void> {
    if (episodeId !== this.episodeId) this.prepare(episodeId);
    if (chaptersUrl.length === 0) {
      this.chapterList = [];
      this.state = ChapterState.Empty;
      return;
    }
    const cached = this.readCache(episodeId, chaptersUrl);
    if (cached !== null) {
      this.chapterList = cached;
      this.state = cached.length === 0 ? ChapterState.Empty : ChapterState.Done;
      return;
    }
    if (this.state === ChapterState.Loading) return;
    if (this.state === ChapterState.Done) return;

    this.generation += 1;
    const gen = this.generation;
    this.state = ChapterState.Loading;
    const auth = this.authHeaderProvider === null ? null : this.authHeaderProvider(chaptersUrl);
    const list = await ChaptersFetcher.fetch(chaptersUrl, auth);
    // 请求期间用户可能已经切到别的集(自动续播),这一份不能写进当前状态
    if (gen !== this.generation || episodeId !== this.episodeId) return;
    if (list === null) {
      this.state = ChapterState.Failed;
      return;
    }
    this.chapterList = list;
    this.writeCache(episodeId, chaptersUrl, list);
    this.state = list.length === 0 ? ChapterState.Empty : ChapterState.Done;
  }

  /**
   * 当前播到第几章(找最后一个 `startMs <= posMs`)。章表为空或还没播到时返回 -1。
   * 列表在数据出口已按 startMs 严格递增,所以从头扫到第一个更大的就能停。
   */
  indexAt(posMs: number): number {
    let idx = -1;
    for (let i = 0; i < this.chapterList.length; i++) {
      if (this.chapterList[i].startMs <= posMs) idx = i;
      else break;
    }
    return idx;
  }

  // ── 缓存 ──

  /**
   * 只认**同一条章节地址**的缓存。
   *
   * 判据必须带 URL:发布方换了章表地址(或同一集被重新发布),旧文件里的章节仍然"看得懂"、
   * 时间也对得上,但它已经不是这一版节目了 —— 这种过期比读不出来更难发现。
   */
  private readCache(episodeId: string, chaptersUrl: string): Chapter[] | null {
    this.load();
    const e = this.cache[episodeId];
    if (e === undefined) return null;
    if (e.version !== ChapterStore.CACHE_VERSION) return null;
    if (e.url !== chaptersUrl) return null;
    return e.chapters;
  }

  /// 整份写回。章表很小(单集几十条标题),同步写几十 KB 可以接受。
  private writeCache(episodeId: string, chaptersUrl: string, chapters: Chapter[]): void {
    this.load();
    this.cache[episodeId] = new CachedChapters(
      ChapterStore.CACHE_VERSION, chaptersUrl, Date.now(), chapters);
    const keys = Object.keys(this.cache);
    if (keys.length > ChapterStore.MAX_ENTRIES) {
      // 按 fetchedAt 升序淘汰最旧的。ArkTS 不支持 delete(arkts-no-delete),重建一份
      keys.sort((a: string, b: string) => this.cache[a].fetchedAt - this.cache[b].fetchedAt);
      const kept: Record<string, CachedChapters> = {};
      for (let i = keys.length - ChapterStore.MAX_ENTRIES; i < keys.length; i++) {
        kept[keys[i]] = this.cache[keys[i]];
      }
      this.cache = kept;
    }
    JsonFile.writeJson(ChapterStore.FILE, this.snapshot());
  }

  private snapshot(): Record<string, Object> {
    const out: Record<string, Object> = {};
    const keys = Object.keys(this.cache);
    for (let i = 0; i < keys.length; i++) {
      const e = this.cache[keys[i]];
      const arr: Object[] = [];
      for (let k = 0; k < e.chapters.length; k++) {
        const c = e.chapters[k];
        arr.push({
          'startMs': c.startMs, 'title': c.title, 'imageUrl': c.imageUrl, 'url': c.url
        } as Record<string, Object>);
      }
      out[keys[i]] = {
        'version': e.version, 'url': e.url, 'fetchedAt': e.fetchedAt, 'chapters': arr
      } as Record<string, Object>;
    }
    return out;
  }
}
