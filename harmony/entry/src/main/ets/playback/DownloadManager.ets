import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import connection from '@ohos.net.connection';
import { Episode } from '../model/Models';
import { DownloadStore } from '../store/DownloadStore';
import { SettingsStore } from '../store/SettingsStore';
import { Log } from '../util/Logger';

/// 下载状态(纯内存态,不持久化;进程重启后由 DownloadStore 重建为已完成)。
export enum DownloadState {
  QUEUED = 0,
  DOWNLOADING = 1,
  COMPLETED = 2,
  FAILED = 3
}

export enum DownloadResult {
  STARTED = 0,
  IGNORED = 1,
  WIFI_REQUIRED = 2,
  NO_NETWORK = 3,
  FAILED = 4
}

export interface DownloadProgress {
  state: DownloadState;
  progress: number;   // 0~1
}

/**
 * 单集离线下载。目录 filesDir/downloads,文件名 dl_<hash><ext>。
 *
 * 相比 Android 版顺手修掉一个既有缺陷:**先写 .part 再 rename**,
 * 失败/中断不会残留半截可播文件(Android 侧是直接写目标文件,失败即留垃圾)。
 */
@Observed
export class DownloadManager {
  private static inst: DownloadManager | null = null;
  static get(): DownloadManager {
    if (DownloadManager.inst === null) DownloadManager.inst = new DownloadManager();
    return DownloadManager.inst;
  }

  /// episodeId → 进度(界面观察)
  states: Record<string, DownloadProgress> = {};

  /// 私有订阅的取流凭据。与 PlayerController 同一个口径:按 URL 判主机,不给就不带。
  /// 下载落在 CDN 上也要能过 401,所以这里必须与播放侧吃同一份判断。
  authHeaderProvider: ((url: string) => string | null) | null = null;

  private dir = '';
  private store: DownloadStore | null = null;
  private settings: SettingsStore | null = null;

  init(filesDir: string, store: DownloadStore, settings: SettingsStore): void {
    this.dir = `${filesDir}/downloads`;
    this.store = store;
    this.settings = settings;
    try {
      if (!fs.accessSync(this.dir)) fs.mkdirSync(this.dir);
    } catch (e) {
      Log.w('Download', `创建目录失败 ${(e as Error).message}`);
    }
    // 已落盘的记录一律视为已完成
    const done = store.downloads;
    const next: Record<string, DownloadProgress> = {};
    for (let i = 0; i < done.length; i++) {
      next[done[i].episode.id] = { state: DownloadState.COMPLETED, progress: 1 };
    }
    this.states = next;
    Log.i('Download', `就绪 已下载 ${done.length} 集`);
  }

  isDownloaded(id: string): boolean {
    return this.store !== null && this.store.contains(id);
  }

  localPath(id: string): string | null {
    return this.store === null ? null : this.store.pathOf(id);
  }

  stateOf(id: string): DownloadProgress | null {
    const s = this.states[id];
    return s === undefined ? null : s;
  }

  /// 开始下载(幂等:已下载 / 正在下 / 已排队都直接返回)。
  async download(e: Episode): Promise<DownloadResult> {
    if (this.store === null || this.dir.length === 0) return DownloadResult.IGNORED;
    if (this.isDownloaded(e.id)) return DownloadResult.IGNORED;
    const cur = this.states[e.id];
    if (cur !== undefined && (cur.state === DownloadState.DOWNLOADING || cur.state === DownloadState.QUEUED)) {
      return DownloadResult.IGNORED;
    }
    if (e.audioUrl.length === 0) return DownloadResult.IGNORED;
    // 占位必须挂在**唯一那个 await 之前**(见 REVIEW-2026-10-25 低·族D D3)。
    // 原先顺序是:查重 → `await downloadGate()` → setState(QUEUED)。中间那个 await 是两次系统调用
    // (getDefaultNet + getNetCapabilities),几十到几百毫秒;快速连点两下时两次都越过上面的
    // 「正在下载/已排队」判据,于是两条下载各自 open 同一个 `.part`、两个 fd 交替写 requestInStream
    // 的分片 —— 音频字节错序即损坏,而这一份照样 rename 成正式文件并 `store.add`,
    // 用户拿到一条"已下载"却播不了的记录。
    // 与 `AudioCacheManager.cache()` 的 `inFlightId` 是同一条经验:**认领要在同步段里完成**,
    // 异步检查排在认领之后,没过再把占位撤掉。
    this.setState(e.id, DownloadState.QUEUED, 0);
    const gate = await this.downloadGate();
    if (gate !== DownloadResult.STARTED) {
      // 闸门没过就撤掉占位:界面上不能留一条永远没人改的「排队中」(见上面 setState 的观察代价)。
      this.clearState(e.id);
      return gate;
    }

    const target = `${this.dir}/${this.uniqueName(e.id, e.audioUrl)}`;
    const part = `${target}.part`;
    const req = http.createHttp();
    let file: fs.File | null = null;
    try {
      this.setState(e.id, DownloadState.DOWNLOADING, 0);
      file = await fs.open(part, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const fd = file.fd;

      /*
       * **流式下载 + 异步分片写**。原先是 `expectDataType: ARRAY_BUFFER` 整块取回、
       * 再 `fs.writeSync` 一次写完 —— 两个问题:
       *  1. 一集几十 MB **整块进 JS 堆**(大文件还有 OOM 风险);
       *  2. `writeSync` 是同步的,**几十 MB 的写卡在 UI 线程上**(见 H64/H65 的教训:
       *     ArkTS 没有协程,同步调用占的就是调用方的线程,而这里的调用方是 UI 线程)。
       * Android 侧本来就是 `Dispatchers.IO` + `byteStream()` 流式拷贝,macOS 是
       * `URLSession.downloadTask` 由系统托管落盘 —— 只有这一端是整块同步写。
       *
       * `requestInStream` 的分片通过 `dataReceive` 事件到达,**可能比写盘更快**,
       * 所以用一条 Promise 串行链把写序列化:既保证顺序(音频文件错序即损坏),
       * 又不会同时发起多个写。
       */
      let chain: Promise<void> = Promise.resolve();
      let written = 0;
      let writeFailed = '';
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        chain = chain.then((): Promise<void> => {
          if (writeFailed.length > 0) return Promise.resolve();
          return fs.write(fd, chunk).then((n: number) => {
            written += n;
          }).catch((err: Error) => {
            // 记下来,等 requestInStream 返回后统一按失败处理(这里抛出去没人接)
            writeFailed = err.message;
          });
        });
      });
      // 真实进度:按**整数百分比**去重再写状态。states 挂在 @Observed 上,
      // 每次赋值都会让持有者重渲 —— 一次下载几千个分片,不去重就是几千次重渲(H64)。
      let lastPct = -1;
      req.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
        if (info.totalSize <= 0) return;
        const pct = Math.floor(info.receiveSize / info.totalSize * 100);
        if (pct !== lastPct) {
          lastPct = pct;
          this.setState(e.id, DownloadState.DOWNLOADING, pct / 100);
        }
      });

      const auth = this.authHeaderProvider === null ? null : this.authHeaderProvider(e.audioUrl);
      // 先落成一个带类型的 Record 再加字段:三元里给两个对象字面量过不了 arkts-no-untyped-obj-literals。
      const headers: Record<string, string> = { 'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)' };
      if (auth !== null) headers['Authorization'] = auth;
      const code = await req.requestInStream(e.audioUrl, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 120000
      });
      await chain;          // 等最后几片写完
      await fs.close(file);
      file = null;

      if (code !== 200 || writeFailed.length > 0 || written === 0) {
        Log.w('Download', `失败 code=${code} 写入=${written}B ${writeFailed} id=${e.id}`);
        await this.cleanupAsync(part);
        this.setState(e.id, DownloadState.FAILED, 0);
        return DownloadResult.FAILED;
      }

      // 先写 .part,成功后再 rename —— 失败不留半截可播文件
      try {
        if (await fs.access(target)) await fs.unlink(target);
      } catch (err) {
        // 忽略
      }
      await fs.rename(part, target);

      this.store.add(e, target);
      this.setState(e.id, DownloadState.COMPLETED, 1);
      Log.i('Download', `完成 "${e.title}" ${Math.round(written / 1024)}KB`);
      return DownloadResult.STARTED;
    } catch (err) {
      Log.e('Download', `失败 id=${e.id} ${(err as Error).message}`);
      if (file !== null) {
        try {
          await fs.close(file);
        } catch (e2) {
          // 忽略
        }
      }
      await this.cleanupAsync(part);
      this.setState(e.id, DownloadState.FAILED, 0);
      return DownloadResult.FAILED;
    } finally {
      req.off('dataReceive');
      req.off('dataReceiveProgress');
      req.destroy();
    }
  }

  /**
   * 下载闸门。**只有链路是蜂窝时才拦**(2026-10-09 真机改定,判据来源见下面第二段)。
   *
   * 上一版把判据从 bearer 改成"networkCap 里有没有 NOT_METERED",理由是要与 Android 的
   * `isActiveNetworkMetered` 同口径 —— 方向没错,**这台设备根本不提供这个信号**:连着 Wi-Fi
   * (实测 `bearer=[1]`)时系统给的 `networkCap` 是 `[12,15,16]`,即 INTERNET / NOT_VPN /
   * VALIDATED,**不含 NOT_METERED(11)**。于是"没上报不计费"被读成"计费",Wi-Fi 下载当场被拦,
   * 用户报的那条 bug 原样复现(取证日志:`闸门拦下 bearer=[1] cap=[12,15,16]`)。
   * 所以本端的 `networkCap` 只能当**放行信号**(含 11 一定不计费),不能当拦截依据;
   * 拦截依据只能用链路类型 —— 这也正是"仅在 Wi-Fi 下载"这个开关对用户承诺的东西(别走流量)。
   *
   * 代价写清楚:**本端识别不了"计费的 Wi-Fi 热点"**(限量热点会被放行),因为连普通 Wi-Fi
   * 都不上报 NOT_METERED,这个信号在 ArkTS 侧不可用;Android 侧仍能识别,两端在这条上
   * 就是不等价,不要试图"修一致"。
   *
   * 三个兜底方向(2026-10-25 复核后按代码逐条改写成实话 —— 原先最后一条写「拿不到 capability
   * 数组时放行」,而代码在**蜂窝**链路上其实是拦;见 REVIEW-2026-10-25 低·族D D2):
   * - **设置读不到**(`settings === null`)按"不允许蜂窝"处理,蜂窝链路照拦(Android 是 `?: false`,同向);
   * - **capability 数组缺失**时 `declaredNotMetered` 记 false ⇒ 非蜂窝照常放行、蜂窝仍按拦。
   *   这不是"拦错比拦对烦人"的宽容,而是:没有证据说这条链路不计费,就不在用户承诺过的开关上擅自下载;
   * - **整个读取过程抛异常** → `NO_NETWORK`,同样是拦。另一道闸门 `AudioCacheManager.blockedByCellular()`
   *   原先在 catch 里返回"放行"、注释还声称与本端一致,本次一并改成拦,取舍写在它那侧的注释里(互指)。
   */
  private async downloadGate(): Promise<DownloadResult> {
    try {
      const handle = await connection.getDefaultNet();
      const caps = await connection.getNetCapabilities(handle);
      const bearers = caps.bearerTypes;
      if (bearers.length === 0) return DownloadResult.NO_NETWORK;
      const settings = this.settings;
      if (settings !== null && settings.allowCellular) return DownloadResult.STARTED;
      const netCap = caps.networkCap;
      const declaredNotMetered = netCap !== undefined && netCap.length > 0
        && netCap.indexOf(connection.NetCap.NET_CAPABILITY_NOT_METERED) >= 0;
      // VPN 隧道挂在蜂窝上时 bearer 只给 4,这条会放行 —— 漏拦的情形写在这里,不装看不见。
      const isCellular = bearers.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0;
      if (declaredNotMetered || !isCellular) return DownloadResult.STARTED;
      // 拦下来的时候把系统给的两组值原样打出来:判据按 bearer 判,而提示文案历史上说过两次
      // 别的口径(「不是 Wi-Fi」/「按用量计费」)—— 只有这两行能分辨"真连着蜂窝"与"设备上报得不对"(见 H162、H166)。
      Log.i('Download', `闸门拦下 bearer=${JSON.stringify(bearers)} `
        + `cap=${JSON.stringify(netCap)} 判定=蜂窝`);
      return DownloadResult.WIFI_REQUIRED;
    } catch (e) {
      Log.w('Download', `读取当前网络失败 ${(e as Error).message}`);
      return DownloadResult.NO_NETWORK;
    }
  }

  delete(id: string): void {
    if (this.store === null) return;
    const p = this.store.pathOf(id);
    if (p !== null) this.cleanup(p);
    this.store.remove(id);
    const next: Record<string, DownloadProgress> = {};
    const keys = Object.keys(this.states);
    for (let i = 0; i < keys.length; i++) if (keys[i] !== id) next[keys[i]] = this.states[keys[i]];
    this.states = next;
  }

  deleteAll(): void {
    if (this.store === null) return;
    const list = this.store.downloads.slice();
    for (let i = 0; i < list.length; i++) this.cleanup(list[i].localPath);
    this.store.clearAll();
    this.states = {};
  }

  /// 下载占用字节(设置页展示用量)。**异步**:每个已下载单集一次 access+stat,
  /// 原先是 O(N) 同步 IO 摊在设置页首帧上(见 H65)。
  async usageBytes(): Promise<number> {
    if (this.store === null) return 0;
    let sum = 0;
    const list = this.store.downloads;
    for (let i = 0; i < list.length; i++) {
      try {
        if (await fs.access(list[i].localPath)) {
          const st = await fs.stat(list[i].localPath);
          sum += st.size;
        }
      } catch (e) {
        // 忽略
      }
    }
    return sum;
  }

  private cleanup(path: string): void {
    try {
      if (fs.accessSync(path)) fs.unlinkSync(path);
    } catch (e) {
      // 忽略
    }
  }

  /// 下载路径上用的删除:异步版,不占 UI 线程(删一个大文件也要几毫秒)。
  private async cleanupAsync(path: string): Promise<void> {
    try {
      if (await fs.access(path)) await fs.unlink(path);
    } catch (e) {
      // 忽略
    }
  }

  private setState(id: string, state: DownloadState, progress: number): void {
    const next: Record<string, DownloadProgress> = {};
    const keys = Object.keys(this.states);
    for (let i = 0; i < keys.length; i++) next[keys[i]] = this.states[keys[i]];
    next[id] = { state: state, progress: progress };
    this.states = next;
  }

  /**
   * 撤掉一条进度。ArkTS 没有 `delete`(arkts-no-delete),所以重建一份不含该键的表 ——
   * 与 `FeedCacheStore` 淘汰、`PlaybackClock` 各处同一个写法。
   * 整体赋值是**必须**的:`states` 挂在 @Observed 上,原地改属性不通知(见 H27)。
   */
  private clearState(id: string): void {
    if (this.states[id] === undefined) return;
    const next: Record<string, DownloadProgress> = {};
    const keys = Object.keys(this.states);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== id) next[keys[i]] = this.states[keys[i]];
    }
    this.states = next;
  }

  /// 文件名:dl_<id 简易哈希><扩展名>。
  /**
   * **哈希只是"够用"的短键,不是唯一键**(见 REVIEW-2026-10-25 低·族A)。它是 int32,
   * 两个不同 id 撞上同一个名字时,后下完的那集会 `rename` 盖掉前一集的文件,而两条账本
   * 记录都指向那个路径 —— 症状就是审核给这一族写的最坏后果:「播 A 集出 B 集的声音」。
   * 两道处理,都不动哈希本体:
   *  ① 种子放**串长**:原先 h 从 0 起,长度信息在第一轮就被 `|0` 绕掉了,
   *     长短不同的 id 更容易同余;先播种长度,不同长度从第一轮就分道(零成本)。
   *  ② 真正兜住的是写盘前的 `uniqueName()` 探测:账本里已有**别的集**占着这个名字时换名,
   *     不给别人覆盖。
   * 换命名只影响**之后的新下载**:`downloads.json` 存的是 `localPath` 全路径(见 DownloadStore.load
   * 还会上逐个 `accessSync` 校验),老条目照旧按记下的路径读,不需要迁移。
   * 前缀 `dl_` 与音频缓存的 `ca_` 区分不变 —— 装机看一眼目录就知道归谁管。
   * Android 侧这一族由另一个代理同步加长;缓存文件名**不是三端互通格式**(互通的是备份 JSON),
   * 所以两端各自加长、不要求逐字节相同。
   */
  private static fileName(id: string, url: string): string {
    let h = id.length;
    for (let i = 0; i < id.length; i++) {
      h = (h * 31 + id.charCodeAt(i)) | 0;
    }
    const name = `dl_${h < 0 ? `n${-h}` : `${h}`}`;
    const lower = url.toLowerCase();
    let ext = '.mp3';
    if (lower.indexOf('.m4a') >= 0) ext = '.m4a';
    else if (lower.indexOf('.aac') >= 0) ext = '.aac';
    else if (lower.indexOf('.ogg') >= 0) ext = '.ogg';
    else if (lower.indexOf('.wav') >= 0) ext = '.wav';
    return `${name}${ext}`;
  }

  /**
   * 撞名探测(低·族A ②):只有当账本里**另一集**的落盘文件名正好等于候选名时才换名。
   * 同步、线性扫,只在用户点下载时跑一次(不在渲染路径),账本条数量级是"手动下载的几十集"。
   * 极端情况连撞 9 次(概率上不会)就退回原名并记一行日志,别把下载这条路堵死。
   */
  private uniqueName(id: string, url: string): string {
    const store = this.store;
    const base = DownloadManager.fileName(id, url);
    if (store === null || !DownloadManager.claimedByOther(store, base, id)) return base;
    const dot = base.indexOf('.');
    const stem = dot > 0 ? base.substring(0, dot) : base;
    const ext = dot > 0 ? base.substring(dot) : '';
    for (let n = 2; n <= 9; n++) {
      const cand = `${stem}-${n}${ext}`;
      if (!DownloadManager.claimedByOther(store, cand, id)) {
        Log.w('Download', `文件名撞车(${base}),这一集改用 ${cand} 落盘 —— 见 REVIEW-2026-10-25 低·族A`);
        return cand;
      }
    }
    Log.w('Download', `文件名 ${base} 连续撞车 8 次,仍按原名落盘`);
    return base;
  }

  private static claimedByOther(store: DownloadStore, name: string, id: string): boolean {
    const done = store.downloads;
    for (let i = 0; i < done.length; i++) {
      const p = done[i].localPath;
      if (p.substring(p.lastIndexOf('/') + 1) === name && done[i].episode.id !== id) return true;
    }
    return false;
  }
}
