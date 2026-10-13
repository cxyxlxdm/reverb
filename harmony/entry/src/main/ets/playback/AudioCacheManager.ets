import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import connection from '@ohos.net.connection';
import { Episode } from '../model/Models';
import { AudioCacheStore, AudioCacheItem } from '../store/AudioCacheStore';
import { SettingsStore } from '../store/SettingsStore';
import { Log } from '../util/Logger';

/**
 * 播放过的整集音频落到 `filesDir/audio_cache/`,下次直接本地起播、不再联网。
 * (与 Android `AudioCacheManager.kt` 同一套设计,流式下载管道照抄本端 DownloadManager。)
 *
 * 为什么不是「边播边存」:本端 AVPlayer 播 http 流**拿不到字节流**(数据不经过 JS),
 * 所以"边播边存"在这一端压根不存在;能做的是首播时后台把整集拉全。多花一点流量
 * (受同一道蜂窝闸门管),换来「缓存里的每一集都能整集离线播」这个简单语义。
 *
 * 三条硬要求:
 *  1. **写完才认账** —— 先下 `.part`,成功再 rename 并记账;失败/中断不留半截可播文件。
 *  2. **单飞、最新优先** —— 连着点开三集只下最后一集:旧请求直接 destroy,不占带宽。
 *  3. **字节预算 + LRU** —— 无上限等于把用户手机当网盘。
 *
 * 与 DownloadManager 完全分开:不同目录(`audio_cache/` vs `downloads/`)、不同账本、不同清理入口。
 * 用户点名下载的那份永远不该被预算挤掉,所以本类**从不读写** `downloads/`。
 */
export class AudioCacheManager {
  /** 缓存总字节预算。整集 mp3 约 30–60 MB,300 MB 大约容下最近听过的 6–8 集。 */
  private static readonly BUDGET_BYTES = 300 * 1024 * 1024;

  private static inst: AudioCacheManager | null = null;
  static get(): AudioCacheManager {
    if (AudioCacheManager.inst === null) AudioCacheManager.inst = new AudioCacheManager();
    return AudioCacheManager.inst;
  }

  private dir = '';
  private store: AudioCacheStore | null = null;
  private settings: SettingsStore | null = null;
  /// episodeId → 已确认存在的本地文件路径。起播选源是**同步**调用,所以这里必须是内存表,
  /// 不能在调用点上 fs.stat(那是把 IO 摊到播放链路上)。
  private known: Map<string, string> = new Map();
  private inFlightId = '';
  private inFlightReq: http.HttpRequest | null = null;

  init(filesDir: string, store: AudioCacheStore, settings: SettingsStore): void {
    this.dir = `${filesDir}/audio_cache`;
    this.store = store;
    this.settings = settings;
    try {
      if (!fs.accessSync(this.dir)) fs.mkdirSync(this.dir);
    } catch (e) {
      Log.w('AudioCache', `创建目录失败 ${(e as Error).message}`);
    }
    // 账本里的每一条都要"文件在、非空"才认。这里是**同步**校验:条目数由预算封顶(个位数),
    // 与本端 DownloadStore.load 的同一做法(见那里注释);真正会长的目录扫描排在下面异步那一轮。
    const items = store.byLeastRecent();
    const dead: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const p = `${this.dir}/${items[i].f}`;
      let ok = false;
      try {
        if (fs.accessSync(p)) ok = fs.statSync(p).size > 0;
      } catch (e) {
        ok = false;
      }
      if (ok) this.known.set(items[i].id, p);
      else dead.push(items[i].id);
    }
    for (let i = 0; i < dead.length; i++) this.store.remove(dead[i]);
    Log.i('AudioCache', `就绪 可离线播 ${this.known.size} 集`);
    // 孤儿文件(含上次崩溃留下的 .part)要扫目录,是 O(文件数) 的 IO —— 挪出启动路径。
    this.sweepOrphans();
  }

  /**
   * 起播时的本地路径:命中就顺手记一次访问(LRU 的依据)。
   * **只在文件已确认存在时**返回路径 —— 把播不了的路径交给 AVPlayer 表现为"点了没反应"。
   */
  localPathForPlay(id: string): string | null {
    if (this.store === null) return null;
    const p = this.known.get(id);
    if (p === undefined) return null;
    this.store.touch(id);
    Log.i('AudioCache', `缓存命中 id=${id}`);
    return p;
  }

  /// 缓存条数与字节数(启动日志 / 设置页)。字节数要 stat,所以是异步。
  count(): number {
    return this.known.size;
  }

  async usageBytes(): Promise<number> {
    const store = this.store;
    if (store === null) return 0;
    let sum = 0;
    const items = store.byLeastRecent();
    for (let i = 0; i < items.length; i++) {
      try {
        if (await fs.access(`${this.dir}/${items[i].f}`)) {
          const st = await fs.stat(`${this.dir}/${items[i].f}`);
          sum += st.size;
        }
      } catch (e) {
        // 忽略
      }
    }
    return sum;
  }

  /**
   * 「清除缓存」:取消在途、清账、删目录。
   *
   * 顺序是硬的:**先**清认领字段再删文件。在途那次下载是靠 `inFlightId` 认自己的,
   * 不清掉它就会在目录已空之后继续往下写、并把这一集重新记进账本 ——
   * 用户点了「清除缓存」却看到数字没怎么变,而这条路径界面上无法解释。
   */
  async clearAll(): Promise<void> {
    const store = this.store;
    if (store === null || this.dir.length === 0) return;
    this.destroyInFlight();
    store.clearAll();
    this.known.clear();
    Log.i('AudioCache', '清空缓存目录');
    try {
      const names = await fs.listFile(this.dir);
      for (let i = 0; i < names.length; i++) {
        try {
          await fs.unlink(`${this.dir}/${names[i]}`);
        } catch (e) {
          // 忽略:单个文件删不掉不影响账已清
        }
      }
    } catch (e) {
      Log.w('AudioCache', `清目录失败 ${(e as Error).message}`);
    }
  }

  /**
   * 首播走网络时排一次「整集落缓存」。幂等且不排队:已缓存 / 正在下这一集的直接返回。
   * 由 PlayerController 的 networkPlayHook 调用(见 AppContainer 的注入)。
   */
  cache(e: Episode): void {
    const store = this.store;
    if (store === null || this.dir.length === 0) return;
    if (e.id.length === 0 || e.audioUrl.length === 0) return;
    if (store.get(e.id) !== null) return;
    if (this.known.has(e.id)) return;
    if (this.inFlightId === e.id) return;
    this.destroyInFlight();          // 单飞:挤掉上一个
    this.inFlightId = e.id;
    // fire-and-forget:结果只影响下次起播走哪条路,不能让它出现在播放链路的 await 上
    this.fetch(e.id, e.audioUrl).then((bytes: number) => {
      if (bytes > 0) {
        Log.i('AudioCache', `缓存完成 "${e.title}" ${Math.round(bytes / 1024)}KB`);
        this.evict(e.id);
      }
    }).catch((err: Error) => {
      Log.w('AudioCache', `缓存失败 id=${e.id} ${err.message}`);
    });
  }

  private async fetch(id: string, url: string): Promise<number> {
    const store = this.store;
    if (store === null) return 0;
    if (await this.blockedByCellular()) {
      Log.i('AudioCache', `蜂窝闸门拦下 id=${id}`);
      this.clearInFlight(id);
      return 0;
    }
    const name = AudioCacheManager.fileName(id, url);
    const target = `${this.dir}/${name}`;
    const part = `${target}.part`;
    const req = http.createHttp();
    this.inFlightReq = req;
    let file: fs.File | null = null;
    try {
      file = await fs.open(part, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const fd = file.fd;
      /**
       * 分片写要**串行**(与 DownloadManager 同一理由):dataReceive 可能比写盘快,
       * 并发写同一个 fd 会错序,而音频错序即损坏。
       */
      let chain: Promise<void> = Promise.resolve();
      let written = 0;
      let writeFailed = '';
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        chain = chain.then((): Promise<void> => {
          if (writeFailed.length > 0) return Promise.resolve();
          return fs.write(fd, chunk).then((n: number) => { written += n; })
            .catch((err: Error) => { writeFailed = err.message; });
        });
      });
      const code = await req.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)' },
        connectTimeout: 15000,
        readTimeout: 120000
      });
      await chain;
      await fs.close(file);
      file = null;

      // 被更新的请求挤掉(inFlightId 已不是自己)→ 这份不认账,直接扔
      if (this.inFlightId !== id) {
        Log.i('AudioCache', `已换集,丢弃这一份 id=${id}`);
        await this.unlinkQuiet(part);
        return 0;
      }
      if (code !== 200 || writeFailed.length > 0 || written === 0) {
        Log.w('AudioCache', `失败 code=${code} 写入=${written}B ${writeFailed} id=${id}`);
        await this.unlinkQuiet(part);
        this.clearInFlight(id);
        return 0;
      }
      // **先 rename 再记账**:反过来的话一次进程被杀就留下「账上有、文件没落地」的记录
      await this.unlinkQuiet(target);
      await fs.rename(part, target);
      store.put(id, url, name, written);
      this.known.set(id, target);
      this.clearInFlight(id);
      return written;
    } catch (err) {
      Log.w('AudioCache', `中断 id=${id} ${(err as Error).message}`);
      if (file !== null) {
        try {
          await fs.close(file);
        } catch (e2) {
          // 忽略
        }
      }
      await this.unlinkQuiet(part);
      this.clearInFlight(id);
      return 0;
    } finally {
      try {
        req.off('dataReceive');
        req.destroy();
      } catch (e3) {
        // 忽略
      }
      if (this.inFlightReq === req) this.inFlightReq = null;
    }
  }

  /** 超预算就按「最久没听」依次删。[keepId] 是刚下完的这集(大概率正在播,绝不能删)。 */
  private async evict(keepId: string): Promise<void> {
    const store = this.store;
    if (store === null) return;
    let usage = await this.usageBytes();
    if (usage <= AudioCacheManager.BUDGET_BYTES) return;
    const items: AudioCacheItem[] = store.byLeastRecent();
    for (let i = 0; i < items.length; i++) {
      if (usage <= AudioCacheManager.BUDGET_BYTES) break;
      const it = items[i];
      if (it.id === keepId) continue;
      const p = `${this.dir}/${it.f}`;
      const size = it.bytes;
      await this.unlinkQuiet(p);
      store.remove(it.id);
      this.known.delete(it.id);
      usage -= size;
      Log.i('AudioCache', `预算淘汰 id=${it.id} ${Math.round(size / 1024)}KB`);
    }
  }

  /** 目录与账本互相校正:文件没人认领的删掉(含半截 `.part`)。异步,不在启动路径上。 */
  private async sweepOrphans(): Promise<void> {
    if (this.dir.length === 0) return;
    try {
      const names = await fs.listFile(this.dir);
      const keep = this.store === null ? [] : this.store.fileNames();
      for (let i = 0; i < names.length; i++) {
        const n = names[i];
        if (keep.indexOf(n) >= 0) continue;
        await this.unlinkQuiet(`${this.dir}/${n}`);
      }
    } catch (e) {
      Log.w('AudioCache', `扫目录失败 ${(e as Error).message}`);
    }
  }

  /**
   * 蜂窝闸门:与本端 DownloadManager **同一套判据**(只在 bearer 是蜂窝且设置没允许时才拦)。
   * 为什么本端不能用 `NOT_METERED`、以及为什么与 Android 刻意不等价,长注释写在
   * `DownloadManager.downloadGate()`(见 H162、H166),这里不重复论证,只保证口径一致。
   *
   * 缓存必须走这道闸门:下载是用户点名要花的流量,而「播过就自动缓存」是 App 替他做的决定,
   * 更不该在流量上擅自跑几十 MB。
   */
  private async blockedByCellular(): Promise<boolean> {
    try {
      const handle = await connection.getDefaultNet();
      const caps = await connection.getNetCapabilities(handle);
      const bearers = caps.bearerTypes;
      if (bearers.length === 0) return true;      // 没网:下了也白费,按拦处理
      const settings = this.settings;
      if (settings !== null && settings.allowCellular) return false;
      const netCap = caps.networkCap;
      const declaredNotMetered = netCap !== undefined && netCap.length > 0
        && netCap.indexOf(connection.NetCap.NET_CAPABILITY_NOT_METERED) >= 0;
      const isCellular = bearers.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0;
      return !declaredNotMetered && isCellular;
    } catch (e) {
      Log.w('AudioCache', `读网络状态失败 ${(e as Error).message}`);
      return false;   // 拿不到信息时放行(与下载闸门"拦错不如拦对"同取向)
    }
  }

  private destroyInFlight(): void {
    const req = this.inFlightReq;
    this.inFlightId = '';
    this.inFlightReq = null;
    if (req !== null) {
      try {
        req.destroy();
      } catch (e) {
        // 忽略
      }
    }
  }

  private clearInFlight(id: string): void {
    if (this.inFlightId === id) this.inFlightId = '';
  }

  private async unlinkQuiet(p: string): Promise<void> {
    try {
      if (await fs.access(p)) await fs.unlink(p);
    } catch (e) {
      // 忽略
    }
  }

  /// 文件名:ca_<id 简易哈希><扩展名>(与 Android 同前缀;与下载的 dl_ 区分,便于装机看一眼目录就知道归谁管)。
  private static fileName(id: string, url: string): string {
    let h = 0;
    for (let i = 0; i < id.length; i++) {
      h = (h * 31 + id.charCodeAt(i)) | 0;
    }
    const name = `ca_${h < 0 ? `n${-h}` : `${h}`}`;
    const lower = url.toLowerCase();
    let ext = '.mp3';
    if (lower.indexOf('.m4a') >= 0) ext = '.m4a';
    else if (lower.indexOf('.aac') >= 0) ext = '.aac';
    else if (lower.indexOf('.ogg') >= 0) ext = '.ogg';
    else if (lower.indexOf('.wav') >= 0) ext = '.wav';
    return `${name}${ext}`;
  }
}
