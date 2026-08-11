import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';
import { Episode } from '../model/Models';
import { HistoryStore } from '../store/Stores';
import { SettingsStore } from '../store/SettingsStore';
import { Log } from '../util/Logger';

/**
 * 播放门面。与 Android `PlayerController.kt` / macOS `PlayerController.swift` 行为对齐:
 * 队列上下文(上/下一集)、倍速 6 档、睡眠定时 + 渐弱、淡入、进度续播、收听时长计数。
 *
 * 三处必须精确移植的要点(踩坑换来的):
 *  1. **pendingSeek 状态机**:AVPlayer 是状态机,seek 必须等 `prepared`;
 *     且保留两条护栏 —— 仅 >3s 才续播、距末尾 10s 内不续播。
 *  2. **countListening 三重门**:同一集 + 播放中 + 增量 ∈[1,3000]ms 才计入,
 *     并在换集时把基线对齐到续播起点(否则 resume 跳转会被误记成收听)。
 *  3. **失败重试 + 可见错误**(采纳 macOS 的更优设计,Android 侧只有日志)。
 */
@Observed
export class PlayerController {
  private static inst: PlayerController | null = null;
  static get(): PlayerController {
    if (PlayerController.inst === null) PlayerController.inst = new PlayerController();
    return PlayerController.inst;
  }

  // ── 对外状态(界面直接观察)──
  current: Episode | null = null;
  isPlaying: boolean = false;
  positionMs: number = 0;
  durationMs: number = 0;
  buffering: boolean = false;
  speed: number = 1.0;
  hasNext: boolean = false;
  hasPrev: boolean = false;
  userQueue: Episode[] = [];
  sleepRemainingMs: number = 0;
  sleepEndOfEpisode: boolean = false;
  playbackError: string = '';

  readonly speedSteps: number[] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0];

  // ── 内部 ──
  private player: media.AVPlayer | null = null;
  private history: HistoryStore | null = null;
  private settings: SettingsStore | null = null;
  /// 已下载单集的本地路径提供者(闭包注入,解耦下载模块;采纳 macOS 设计)
  localFileProvider: ((e: Episode) => string | null) | null = null;
  /// 播放状态变化回调(供 AVSession 同步)
  onStateChanged: (() => void) | null = null;

  private queue: Episode[] = [];
  private queueIndex = 0;

  private pendingSeekMs = 0;
  private tickTimer = -1;
  private tickCount = 0;
  private loadRetries = 0;

  // 收听时长计数基线
  private lastCountedPosMs = 0;
  private lastCountedEpId = '';
  private onListened: ((e: Episode, deltaMs: number) => void) | null = null;
  private onListenFlush: (() => void) | null = null;

  // 淡入 / 睡眠
  private fadeTimer = -1;
  private sleepTimer = -1;
  private readonly fadeInMs = 900;
  private readonly sleepFadeMs = 8000;

  bind(history: HistoryStore, settings: SettingsStore): void {
    this.history = history;
    this.settings = settings;
    this.speed = settings.defaultSpeed;
  }

  bindListen(add: (e: Episode, deltaMs: number) => void, flush: () => void): void {
    this.onListened = add;
    this.onListenFlush = flush;
  }

  // ── 播放入口 ──

  play(e: Episode): void {
    this.playQueue([e], 0);
  }

  playQueue(list: Episode[], startIndex: number): void {
    if (list.length === 0) return;
    this.queue = list;
    this.queueIndex = Math.max(0, Math.min(startIndex, list.length - 1));
    this.loadRetries = 0;
    this.updateNavFlags();
    this.playEpisode(this.queue[this.queueIndex]);
  }

  /// 同一集则暂停/继续,否则以该列表为队列起播。
  playOrToggle(e: Episode, queue: Episode[]): void {
    if (this.current !== null && this.current.id === e.id) {
      this.togglePlayPause();
      return;
    }
    let idx = queue.findIndex((x: Episode) => x.id === e.id);
    if (idx < 0) idx = 0;
    this.playQueue(queue.length > 0 ? queue : [e], idx);
  }

  private async playEpisode(e: Episode): Promise<void> {
    this.playbackError = '';
    this.current = e;
    this.positionMs = 0;
    this.durationMs = 0;
    if (this.onListenFlush !== null) this.onListenFlush();   // 结算上一集残余

    if (this.history !== null) this.history.record(e, Date.now());
    const resumeMs = this.history === null ? 0 : this.history.positionFor(e.id);
    this.pendingSeekMs = resumeMs;
    // 统计基线对齐续播起点,避免把 resume 跳转记成收听
    this.lastCountedEpId = e.id;
    this.lastCountedPosMs = resumeMs;

    const local = this.localFileProvider === null ? null : this.localFileProvider(e);
    const src = local !== null && local.length > 0 ? local : e.audioUrl;
    if (src.length === 0) {
      this.playbackError = '音频地址无效';
      return;
    }
    Log.i('Player', `播放 "${e.title}" 源=${local !== null ? '本地' : '网络'} resume=${resumeMs}ms`);

    try {
      await this.ensurePlayer();
      const p = this.player;
      if (p === null) return;
      // 换源必须先回到 idle
      if (p.state !== 'idle') await p.reset();
      p.url = src;
      // prepare 在 stateChange 的 'initialized' 分支触发
    } catch (err) {
      Log.e('Player', `装载失败 ${(err as Error).message}`);
      this.handleLoadFailure(e);
    }
    this.notify();
  }

  private async ensurePlayer(): Promise<void> {
    if (this.player !== null) return;
    const p = await media.createAVPlayer();
    // 声明为音乐用途,系统才允许后台继续出声
    p.audioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0
    };
    p.audioInterruptMode = audio.InterruptMode.SHARE_MODE;

    p.on('stateChange', (state: string) => {
      this.onPlayerState(state as media.AVPlayerState);
    });
    p.on('timeUpdate', (t: number) => {
      this.positionMs = t;
    });
    p.on('durationUpdate', (d: number) => {
      this.durationMs = d;
      this.notify();
    });
    p.on('bufferingUpdate', (type: media.BufferingInfoType, _v: number) => {
      const b = type === media.BufferingInfoType.BUFFERING_START;
      if (this.buffering !== b) {
        this.buffering = b;
        this.notify();
      }
    });
    p.on('error', (err: Error) => {
      Log.e('Player', `播放错误 ${err.message}`);
      const cur = this.current;
      if (cur !== null) this.handleLoadFailure(cur);
    });
    this.player = p;
  }

  private async onPlayerState(state: media.AVPlayerState): Promise<void> {
    const p = this.player;
    if (p === null) return;
    Log.d('Player', `state=${state}`);
    if (state === 'initialized') {
      try {
        await p.prepare();
      } catch (e) {
        const cur = this.current;
        if (cur !== null) this.handleLoadFailure(cur);
      }
      return;
    }
    if (state === 'prepared') {
      this.loadRetries = 0;
      this.durationMs = p.duration > 0 ? p.duration : 0;
      // 续播两条护栏:>3s 才回跳、距末尾 10s 内不回跳(AVPlayer 必须在 prepared 后 seek)
      const seekMs = this.pendingSeekMs;
      this.pendingSeekMs = 0;
      if (seekMs > 3000 && (this.durationMs <= 0 || seekMs < this.durationMs - 10000)) {
        p.seek(seekMs, media.SeekMode.SEEK_PREV_SYNC);
        this.positionMs = seekMs;
      }
      p.setVolume(0);         // 淡入起点
      try {
        await p.play();
      } catch (e) {
        Log.w('Player', '起播失败');
      }
      p.setPlaybackRate(this.speed);
      this.fadeVolume(1.0, this.fadeInMs);
      return;
    }
    if (state === 'playing') {
      this.isPlaying = true;
      this.startTicker();
      this.notify();
      return;
    }
    if (state === 'paused') {
      this.isPlaying = false;
      this.stopTicker();
      this.saveProgress();
      if (this.onListenFlush !== null) this.onListenFlush();
      this.notify();
      return;
    }
    if (state === 'completed') {
      this.isPlaying = false;
      this.stopTicker();
      const cur = this.current;
      if (cur !== null && this.history !== null) {
        this.history.updatePosition(cur.id, 0, this.durationMs);
        this.history.markPlayed(cur.id, true);
      }
      if (this.onListenFlush !== null) this.onListenFlush();
      const stopAfter = this.sleepEndOfEpisode;
      this.sleepEndOfEpisode = false;
      if (!stopAfter) {
        if (this.userQueue.length > 0) this.consumeQueueHead();
        else if (this.queueIndex < this.queue.length - 1) this.next();
      }
      this.notify();
    }
  }

  /// 加载失败:同集自动重试至多 3 次(退避 0.8s),超限给出可见提示。
  private handleLoadFailure(e: Episode): void {
    if (this.current === null || this.current.id !== e.id) return;
    if (this.loadRetries < 3) {
      this.loadRetries += 1;
      Log.w('Player', `加载失败,自动重试 ${this.loadRetries}/3`);
      setTimeout(() => {
        if (this.current !== null && this.current.id === e.id) this.playEpisode(e);
      }, 800);
    } else {
      this.loadRetries = 0;
      this.playbackError = '加载失败,请检查网络后重试';
      Log.e('Player', '重试耗尽,等待用户手动重试');
      this.notify();
    }
  }

  retry(): void {
    const e = this.current;
    if (e === null) return;
    this.loadRetries = 0;
    this.playEpisode(e);
  }

  // ── 传输控制 ──

  togglePlayPause(): void {
    const p = this.player;
    if (p === null) return;
    if (this.isPlaying) {
      p.pause();
    } else {
      p.play();
      p.setPlaybackRate(this.speed);
    }
  }

  seekTo(ms: number): void {
    const p = this.player;
    if (p === null) return;
    const t = Math.max(0, ms);
    p.seek(t, media.SeekMode.SEEK_PREV_SYNC);
    this.positionMs = t;
    // seek 后把基线推到新位置,避免跳变被计入收听
    this.lastCountedPosMs = t;
    this.notify();
  }

  seekBy(delta: number): void {
    this.seekTo(this.positionMs + delta);
  }

  skipForward(): void {
    this.seekBy((this.settings === null ? 30 : this.settings.skipForwardSec) * 1000);
  }

  skipBackward(): void {
    this.seekBy(-((this.settings === null ? 10 : this.settings.skipBackSec) * 1000));
  }

  setSpeed(s: number): void {
    this.speed = s;
    const p = this.player;
    if (p !== null && this.isPlaying) p.setPlaybackRate(s);
    this.notify();
  }

  // ── 队列导航 ──

  next(): void {
    this.loadRetries = 0;
    if (this.userQueue.length > 0) {
      this.consumeQueueHead();
      return;
    }
    if (this.queueIndex < this.queue.length - 1) {
      this.queueIndex += 1;
      this.updateNavFlags();
      this.playEpisode(this.queue[this.queueIndex]);
    }
  }

  previous(): void {
    this.loadRetries = 0;
    if (this.queueIndex > 0) {
      this.queueIndex -= 1;
      this.updateNavFlags();
      this.playEpisode(this.queue[this.queueIndex]);
    }
  }

  enqueue(e: Episode): void {
    if (this.userQueue.some((x: Episode) => x.id === e.id)) return;
    this.userQueue = this.userQueue.concat([e]);
    this.updateNavFlags();
  }

  playNext(e: Episode): void {
    const rest = this.userQueue.filter((x: Episode) => x.id !== e.id);
    this.userQueue = [e].concat(rest);
    this.updateNavFlags();
  }

  removeFromQueue(id: string): void {
    this.userQueue = this.userQueue.filter((x: Episode) => x.id !== id);
    this.updateNavFlags();
  }

  clearQueue(): void {
    this.userQueue = [];
    this.updateNavFlags();
  }

  private consumeQueueHead(): void {
    if (this.userQueue.length === 0) return;
    const head = this.userQueue[0];
    this.userQueue = this.userQueue.slice(1);
    this.queue = [head];
    this.queueIndex = 0;
    this.updateNavFlags();
    this.playEpisode(head);
  }

  private updateNavFlags(): void {
    this.hasPrev = this.queueIndex > 0;
    this.hasNext = (this.queueIndex >= 0 && this.queueIndex < this.queue.length - 1) || this.userQueue.length > 0;
    this.notify();
  }

  // ── 睡眠定时 ──

  setSleepTimer(minutes: number): void {
    this.sleepEndOfEpisode = false;
    this.sleepRemainingMs = minutes * 60000;
    this.startSleepTicker();
    this.notify();
  }

  setSleepEndOfEpisode(): void {
    this.clearSleepTicker();
    this.sleepRemainingMs = 0;
    this.sleepEndOfEpisode = true;
    this.notify();
  }

  cancelSleep(): void {
    this.clearSleepTicker();
    this.clearFade();
    this.sleepRemainingMs = 0;
    this.sleepEndOfEpisode = false;
    const p = this.player;
    if (p !== null) p.setVolume(1.0);
    this.notify();
  }

  private startSleepTicker(): void {
    this.clearSleepTicker();
    this.sleepTimer = setInterval(() => {
      const remain = this.sleepRemainingMs - 1000;
      if (remain <= 0) {
        this.sleepRemainingMs = 0;
        const p = this.player;
        if (p !== null) {
          p.pause();
          p.setVolume(1.0);
        }
        this.clearSleepTicker();
      } else {
        this.sleepRemainingMs = remain;
        // 最后 8 秒线性渐弱
        if (remain <= this.sleepFadeMs) {
          const p = this.player;
          if (p !== null) p.setVolume(remain / this.sleepFadeMs);
        }
      }
      this.notify();
    }, 1000);
  }

  private clearSleepTicker(): void {
    if (this.sleepTimer >= 0) {
      clearInterval(this.sleepTimer);
      this.sleepTimer = -1;
    }
  }

  // ── 淡入(50ms 步进软件调音量,与两端一致)──

  private fadeVolume(target: number, durationMs: number): void {
    this.clearFade();
    const steps = Math.max(1, Math.floor(durationMs / 50));
    let i = 0;
    this.fadeTimer = setInterval(() => {
      i += 1;
      const f = Math.min(1, i / steps);
      const p = this.player;
      if (p !== null) p.setVolume(target * f);
      if (i >= steps) this.clearFade();
    }, 50);
  }

  private clearFade(): void {
    if (this.fadeTimer >= 0) {
      clearInterval(this.fadeTimer);
      this.fadeTimer = -1;
    }
  }

  // ── 500ms ticker:进度落盘 + 收听时长计数 ──

  private startTicker(): void {
    this.stopTicker();
    this.tickTimer = setInterval(() => {
      const p = this.player;
      if (p === null) return;
      this.countListening();
      this.tickCount += 1;
      if (this.tickCount % 10 === 0) this.saveProgress();   // 约每 5 秒
      this.notify();
    }, 500);
  }

  private stopTicker(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private saveProgress(): void {
    const e = this.current;
    if (e === null || this.history === null) return;
    this.history.updatePosition(e.id, Math.max(0, this.positionMs), Math.max(0, this.durationMs));
  }

  /// 累计"实际播放过的内容毫秒":同一集 + 播放中 + 增量 ∈[1,3000]ms。
  /// 快进/快退的大跳变与暂停自然被剔除;倍速下按内容时长计。
  private countListening(): void {
    const e = this.current;
    if (e === null) {
      this.lastCountedEpId = '';
      return;
    }
    if (e.id === this.lastCountedEpId) {
      const delta = this.positionMs - this.lastCountedPosMs;
      if (this.isPlaying && delta >= 1 && delta <= 3000 && this.onListened !== null) {
        this.onListened(e, delta);
      }
    }
    this.lastCountedPosMs = this.positionMs;
    this.lastCountedEpId = e.id;
  }

  private notify(): void {
    if (this.onStateChanged !== null) this.onStateChanged();
  }

  async release(): Promise<void> {
    this.stopTicker();
    this.clearFade();
    this.clearSleepTicker();
    const p = this.player;
    this.player = null;
    if (p !== null) {
      try {
        await p.release();
      } catch (e) {
        // 忽略
      }
    }
  }
}
