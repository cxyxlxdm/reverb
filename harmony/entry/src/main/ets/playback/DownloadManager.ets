import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import { Episode } from '../model/Models';
import { DownloadStore } from '../store/DownloadStore';
import { Log } from '../util/Logger';

/// 下载状态(纯内存态,不持久化;进程重启后由 DownloadStore 重建为已完成)。
export enum DownloadState {
  QUEUED = 0,
  DOWNLOADING = 1,
  COMPLETED = 2,
  FAILED = 3
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

  init(filesDir: string, store: DownloadStore): void {
    this.dir = `${filesDir}/downloads`;
    this.store = store;
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
  async download(e: Episode): Promise<void> {
    if (this.store === null || this.dir.length === 0) return;
    if (this.isDownloaded(e.id)) return;
    const cur = this.states[e.id];
    if (cur !== undefined && (cur.state === DownloadState.DOWNLOADING || cur.state === DownloadState.QUEUED)) return;
    if (e.audioUrl.length === 0) return;

    this.setState(e.id, DownloadState.QUEUED, 0);
    const target = `${this.dir}/${DownloadManager.fileName(e.id, e.audioUrl)}`;
    const part = `${target}.part`;
    const req = http.createHttp();
    try {
      this.setState(e.id, DownloadState.DOWNLOADING, 0);
      // ArkTS 的 http 无流式回调下载,这里整体取回再落盘(播客单集通常几十 MB,可接受)
      const resp = await req.request(e.audioUrl, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)' },
        connectTimeout: 15000,
        readTimeout: 120000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode !== 200) {
        Log.w('Download', `http ${resp.responseCode} id=${e.id}`);
        this.setState(e.id, DownloadState.FAILED, 0);
        return;
      }
      const buf = resp.result as ArrayBuffer;
      // 先写 .part,成功后再 rename —— 失败不留半截可播文件
      const f = fs.openSync(part, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, buf);
      fs.closeSync(f);
      try {
        if (fs.accessSync(target)) fs.unlinkSync(target);
      } catch (err) {
        // 忽略
      }
      fs.renameSync(part, target);

      this.store.add(e, target);
      this.setState(e.id, DownloadState.COMPLETED, 1);
      Log.i('Download', `完成 "${e.title}" ${Math.round(buf.byteLength / 1024)}KB`);
    } catch (err) {
      Log.e('Download', `失败 id=${e.id} ${(err as Error).message}`);
      this.cleanup(part);
      this.setState(e.id, DownloadState.FAILED, 0);
    } finally {
      req.destroy();
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

  /// 下载占用字节(设置页展示用量)。
  usageBytes(): number {
    if (this.store === null) return 0;
    let sum = 0;
    const list = this.store.downloads;
    for (let i = 0; i < list.length; i++) {
      try {
        if (fs.accessSync(list[i].localPath)) sum += fs.statSync(list[i].localPath).size;
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
