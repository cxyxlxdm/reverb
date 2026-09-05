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
    const gate = await this.downloadGate();
    if (gate !== DownloadResult.STARTED) return gate;

    this.setState(e.id, DownloadState.QUEUED, 0);
    const target = `${this.dir}/${DownloadManager.fileName(e.id, e.audioUrl)}`;
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

      const code = await req.requestInStream(e.audioUrl, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)' },
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

  private async downloadGate(): Promise<DownloadResult> {
    try {
      const handle = await connection.getDefaultNet();
      const caps = await connection.getNetCapabilities(handle);
      if (caps.bearerTypes.length === 0) return DownloadResult.NO_NETWORK;
      const settings = this.settings;
      if (settings === null || settings.allowCellular) return DownloadResult.STARTED;
      return caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0
        ? DownloadResult.STARTED : DownloadResult.WIFI_REQUIRED;
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

  /// 文件名:dl_<id 简易哈希><扩展名>。
  private static fileName(id: string, url: string): string {
    let h = 0;
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
}
