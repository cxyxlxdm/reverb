import media from '@ohos.multimedia.media';
import { L } from '../util/L';
import { GuideEpisode } from '../store/GuideEpisode';
import fs from '@ohos.file.fs';
import audio from '@ohos.multimedia.audio';
import { Episode } from '../model/Models';
import { HistoryStore } from '../store/Stores';
import { SettingsStore } from '../store/SettingsStore';
import { PlaybackClock } from './PlaybackClock';
import { Log } from '../util/Logger';

/// 播放请求的 User-Agent。与 Http.ets 的 UA 同一形态 —— 不少播客 CDN 会按 UA 拒绝请求。
const PLAYER_UA = 'Reverb/1.0 (HarmonyOS podcast client)';

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
  durationMs: number = 0;
  loading: boolean = false;
  buffering: boolean = false;
  speed: number = 1.0;
  hasNext: boolean = false;
  hasPrev: boolean = false;
  userQueue: Episode[] = [];
  sleepRemainingMs: number = 0;
  sleepEndOfEpisode: boolean = false;
  playbackError: string = '';
  /// 是否在台(随机/情境电台):播完自动接下一首
  radioMode: boolean = false;

  readonly speedSteps: number[] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0];

  /**
   * 播放进度**不放在本类字段上**,而是放进这个普通对象里 —— 见 `PlaybackClock` 的注释:
   * 本类是 `@Observed`,而 ArkUI V1 的观察粒度是整个对象,`timeUpdate` 每 100ms 写一次
   * 就等于把界面整页重建 10 次/秒(H64)。
   *
   * `positionMs` 保留为 **getter**:读起来和以前一样,但 getter 不是自有属性,
   * 读它不会建立依赖、写 clock 也不会触发重建。需要连续进度的界面各自轮询。
   */
  readonly clock: PlaybackClock = new PlaybackClock();

  get positionMs(): number {
    return this.clock.positionMs;
  }

  // ── 内部 ──
  private player: media.AVPlayer | null = null;
  private readonly audioSessionManager: audio.AudioSessionManager =
    audio.getAudioManager().getSessionManager();
  /// AudioSession 的目标态与操作代次。系统接口是异步的,快速暂停/继续时必须串行收敛到最后一次意图,
  /// 不能让较早的 activate/deactivate 回来后覆盖较新的动作。
  private audioSessionDesiredActive = false;
  private audioSessionGeneration = 0;
  private audioSessionTask: Promise<void> = Promise.resolve();
  /// 用户最后一次明确的播放意图。加载阶段也必须保留暂停命令,不能只看尚未变成 true 的 isPlaying。
  private playbackDesiredPlaying = false;
  /// 明确的暂停/恢复也串行执行:pause 尚未完成时收到 resume,必须等 pause 落地后再恢复。
  private playbackActionGeneration = 0;
  private playbackActionTask: Promise<void> = Promise.resolve();
  private history: HistoryStore | null = null;
  private settings: SettingsStore | null = null;
  /// 已下载单集的本地路径提供者(闭包注入,解耦下载模块;采纳 macOS 设计)
  localFileProvider: ((e: Episode) => string | null) | null = null;
  /// 播放状态变化回调(供 AVSession 同步)
  onStateChanged: (() => void) | null = null;

  private queue: Episode[] = [];
  private queueIndex = 0;

  // 电台:下一首从哪来由 RadioStation 提供,是否在台/自动续播由本类统一持有
  private radioNext: (() => Promise<Episode | null>) | null = null;
  private radioAdvancing = false;
  private radioHistory: Episode[] = [];
  private radioPos = -1;
  private readonly radioHistoryCap = 100;

  private pendingSeekMs = 0;
  private tickTimer = -1;
  private loadRetries = 0;
  private loadGeneration = 0;
  private sourceGeneration = 0;
  private failedGeneration = -1;
  private retryTimer = -1;
  private loadTask: Promise<void> = Promise.resolve();
  private playerCreation: Promise<media.AVPlayer | null> | null = null;
  private released = false;
  /// 本地播放时打开的文件句柄(AVPlayer 的 url 只收 fd:// 或网络地址,本地必须走 fdSrc)
  private localFile: fs.File | null = null;

  // 收听时长计数基线放在 clock 里 —— 它每 500ms 变一次,留在本类字段上就会推动整页重建(H64)
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
    if (this.radioMode) this.stopRadio();   // 手动播放即退出电台
    this.queue = list;
    this.queueIndex = Math.max(0, Math.min(startIndex, list.length - 1));
    this.updateNavFlags();
    this.startEpisode(this.queue[this.queueIndex], true);
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

  private startEpisode(e: Episode, resetRetries: boolean): void {
    if (this.released) return;
    this.cancelLoadRetry();
    if (resetRetries) {
      this.loadRetries = 0;
      this.playbackError = '';
    }
    // 新音源会自动起播,此前排队的暂停/恢复动作不得再落到它身上。
    this.playbackDesiredPlaying = true;
    this.playbackActionGeneration += 1;
    const generation = ++this.loadGeneration;
    this.failedGeneration = -1;
    this.loadTask = this.loadTask
      .then((): Promise<void> => this.playEpisode(e, generation))
      .catch((err: Error): void => {
        Log.e('Player', `装载队列异常 ${(err as Error).message}`);
        this.handleLoadFailure(e, generation);
      });
  }

  private async playEpisode(e: Episode, generation: number): Promise<void> {
    if (generation !== this.loadGeneration) return;
    this.current = e;
    this.clock.positionMs = 0;
    this.durationMs = 0;
    this.loading = true;
    this.buffering = false;
    this.isPlaying = false;
    this.clearFade();
    this.stopTicker();
    this.notify();
    if (this.onListenFlush !== null) this.onListenFlush();   // 结算上一集残余

    // 内置引导音频不是一集真正的播客:不进历史、不计收听时长,
    // 否则"收听时长"榜首会是引导音频,「继续收听」里也会挂着它。
    const isGuide = GuideEpisode.isGuide(e.id);
    if (!isGuide && this.history !== null) this.history.record(e, Date.now());
    const resumeMs = (isGuide || this.history === null) ? 0 : this.history.positionFor(e.id);
    this.pendingSeekMs = resumeMs;
    // 统计基线对齐续播起点,避免把 resume 跳转记成收听
    this.clock.countedEpId = e.id;
    this.clock.countedPosMs = resumeMs;

    const local = this.localFileProvider === null ? null : this.localFileProvider(e);
    const useLocal = local !== null && local.length > 0;
    if (!useLocal && e.audioUrl.length === 0) {
      this.loading = false;
      this.playbackDesiredPlaying = false;
      this.playbackError = L.s('audio_url_invalid');
      this.deactivateAudioSession();
      this.notify();
      return;
    }
    Log.i('Player', `播放 "${e.title}" 源=${useLocal ? '本地' : '网络'} resume=${resumeMs}ms generation=${generation}`);

    try {
      const p = await this.ensurePlayer();
      if (generation !== this.loadGeneration) return;
      if (p === null) {
        this.handleLoadFailure(e, generation);
        return;
      }
      // 换源前先解绑旧音源回调;reset 的延迟事件不能套用新代次。
      this.sourceGeneration = 0;
      this.unbindSourceEvents(p);
      if (p.state !== 'idle') await p.reset();
      if (generation !== this.loadGeneration) return;
      this.closeLocalFile();
      this.sourceGeneration = generation;
      this.bindSourceEvents(p, generation);
      if (useLocal) {
        // AVPlayer 不接受普通文件路径,必须用 fdSrc 传文件描述符
        const f = fs.openSync(local, fs.OpenMode.READ_ONLY);
        this.localFile = f;
        p.fdSrc = { fd: f.fd };
      } else {
        await this.setNetworkSource(p, e.audioUrl);
      }
      // prepare 在 stateChange 的 'initialized' 分支触发
    } catch (err) {
      Log.e('Player', `装载失败 ${(err as Error).message}`);
      this.handleLoadFailure(e, generation);
    }
  }

  /**
   * 装载网络音源。**带 User-Agent**,而不是直接 `p.url = ...`。
   *
   * 起因:外部反馈「播放会提示加载失败,但偶尔可以播」。RSS/榜单那一侧一直正常,因为
   * `Http.ets` 每个请求都带 UA;而 `p.url = ...` 用的是 AVPlayer 默认请求头,相当多的
   * 播客 CDN(Libsyn / Megaphone / Podbean / 喜马拉雅一类)对无 UA 或陌生 UA 直接 403,
   * 于是"大部分节目放不出、少数能放"。Android 侧 ExoPlayer 默认就会带 UA,故无此问题。
   *
   * `createMediaSourceWithUrl` + `setMediaSource` 自 API 12 起提供。低版本或调用失败时
   * **回落到直接赋 url**,保持原行为,不至于因为这个增强反而放不出声。
   */
  private async setNetworkSource(p: media.AVPlayer, url: string): Promise<void> {
    try {
      const src = media.createMediaSourceWithUrl(url, { 'User-Agent': PLAYER_UA });
      await p.setMediaSource(src);
      return;
    } catch (err) {
      Log.w('Player', `setMediaSource 不可用,回落直接赋 url:${(err as Error).message}`);
    }
    p.url = url;
  }

  private async ensurePlayer(): Promise<media.AVPlayer | null> {
    if (this.released) return null;
    if (this.player !== null) return this.player;
    if (this.playerCreation === null) this.playerCreation = this.createPlayer();
    const creating = this.playerCreation;
    const p = await creating;
    if (this.playerCreation === creating) this.playerCreation = null;
    return p;
  }

  private async createPlayer(): Promise<media.AVPlayer | null> {
    let p: media.AVPlayer;
    try {
      p = await media.createAVPlayer();
    } catch (e) {
      Log.e('Player', `创建播放器失败 ${(e as Error).message}`);
      return null;
    }
    if (this.released) {
      try {
        await p.release();
      } catch (e) {
        Log.w('Player', `释放刚创建的播放器失败 ${(e as Error).message}`);
      }
      return null;
    }
    // 声明为音乐用途,系统才允许后台继续出声
    p.audioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0
    };
    p.audioInterruptMode = audio.InterruptMode.SHARE_MODE;

    p.on('timeUpdate', (t: number) => {
      // 约 100ms 一次。**只写 clock、不 notify** —— 这一行是整页重建的源头(H64)
      this.clock.positionMs = t;
    });
    this.player = p;
    return p;
  }

  /**
   * AudioSession 只有一条异步操作链。每次意图变化都换代,排到队头时已过期的任务直接跳过;
   * 已经发给系统的旧操作无法取消,但它结束后新代次一定紧跟着把系统状态收敛到最新目标。
   */
  private requestAudioSession(active: boolean): number {
    this.audioSessionDesiredActive = active;
    const generation = ++this.audioSessionGeneration;
    this.audioSessionTask = this.audioSessionTask.then((): Promise<void> => {
      return this.reconcileAudioSession(generation);
    });
    return generation;
  }

  private async reconcileAudioSession(generation: number): Promise<void> {
    if (generation !== this.audioSessionGeneration) return;
    try {
      const active = this.audioSessionManager.isAudioSessionActivated();
      if (this.audioSessionDesiredActive) {
        if (!active) {
          await this.audioSessionManager.activateAudioSession({
            concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS
          });
          Log.i('Player', `AudioSession 已激活 generation=${generation}`);
        }
      } else if (active) {
        await this.audioSessionManager.deactivateAudioSession();
        Log.i('Player', `AudioSession 已撤销 generation=${generation}`);
      }
    } catch (e) {
      Log.w('Player', `AudioSession 协调失败 generation=${generation} ${(e as Error).message}`);
    }
  }

  private async activateAudioSession(): Promise<number> {
    const generation = this.requestAudioSession(true);
    const task = this.audioSessionTask;
    await task;
    return generation;
  }

  private isAudioSessionReady(generation: number): boolean {
    if (generation !== this.audioSessionGeneration || !this.audioSessionDesiredActive || this.released) return false;
    try {
      return this.audioSessionManager.isAudioSessionActivated();
    } catch (e) {
      Log.w('Player', `读取 AudioSession 状态失败 ${(e as Error).message}`);
      return false;
    }
  }

  private deactivateAudioSession(): void {
    this.requestAudioSession(false);
  }

  private bindSourceEvents(p: media.AVPlayer, generation: number): void {
    p.on('stateChange', (state: string) => {
      this.onPlayerState(state as media.AVPlayerState, generation);
    });
    p.on('durationUpdate', (d: number) => {
      if (generation !== this.loadGeneration) return;
      this.durationMs = d;
      this.notify();
    });
    p.on('bufferingUpdate', (type: media.BufferingInfoType, _v: number) => {
      if (generation !== this.loadGeneration) return;
      const b = type === media.BufferingInfoType.BUFFERING_START;
      if (this.buffering !== b) {
        this.buffering = b;
        this.notify();
      }
    });
    p.on('error', (err: Error) => {
      Log.e('Player', `播放错误 generation=${generation} ${err.message}`);
      const cur = this.current;
      if (cur !== null) this.handleLoadFailure(cur, generation);
    });
  }

  private unbindSourceEvents(p: media.AVPlayer): void {
    p.off('stateChange');
    p.off('durationUpdate');
    p.off('bufferingUpdate');
    p.off('error');
  }

  private async onPlayerState(state: media.AVPlayerState, generation: number): Promise<void> {
    if (generation <= 0 || generation !== this.loadGeneration) return;
    const p = this.player;
    if (p === null) return;
    Log.d('Player', `state=${state} generation=${generation}`);
    if (state === 'initialized') {
      try {
        await p.prepare();
      } catch (e) {
        const cur = this.current;
        if (cur !== null) this.handleLoadFailure(cur, generation);
      }
      return;
    }
    if (state === 'prepared') {
      this.durationMs = p.duration > 0 ? p.duration : 0;
      // 续播两条护栏:>3s 才回跳、距末尾 10s 内不回跳(AVPlayer 必须在 prepared 后 seek)
      const seekMs = this.pendingSeekMs;
      this.pendingSeekMs = 0;
      if (seekMs > 3000 && (this.durationMs <= 0 || seekMs < this.durationMs - 10000)) {
        p.seek(seekMs, media.SeekMode.SEEK_PREV_SYNC);
        this.clock.positionMs = seekMs;
      }
      // 用户可能在 prepare 或 AudioSession 激活期间按了暂停。prepared 不能把旧的自动起播意图复活。
      if (!this.playbackDesiredPlaying) {
        this.loading = false;
        this.notify();
        return;
      }
      try {
        const sessionGeneration = await this.activateAudioSession();
        // 激活期间可能已经换集、释放或被暂停。旧异步结果只能退出,不能再让旧源开声。
        if (generation !== this.loadGeneration || this.sourceGeneration !== generation
          || this.released || this.player !== p || !this.playbackDesiredPlaying
          || sessionGeneration !== this.audioSessionGeneration || !this.audioSessionDesiredActive) return;
        if (!this.isAudioSessionReady(sessionGeneration)) {
          this.handleAudioSessionFailure(generation);
          return;
        }
        p.setVolume(0);         // 淡入起点
        await p.play();
        if (generation !== this.loadGeneration || this.sourceGeneration !== generation
          || this.released || this.player !== p || !this.playbackDesiredPlaying
          || sessionGeneration !== this.audioSessionGeneration || !this.audioSessionDesiredActive) {
          // pause 可能落在 play() 调用与 Promise 完成之间;只按最新目标态纠偏,不能反向覆盖更新的 resume。
          if (!this.audioSessionDesiredActive && this.player === p && p.state === 'playing') await p.pause();
          return;
        }
        this.applyRate(p, this.speed);
        this.fadeVolume(1.0, this.fadeInMs, generation);
      } catch (e) {
        Log.w('Player', `起播失败 ${(e as Error).message}`);
        const cur = this.current;
        if (cur !== null) this.handleLoadFailure(cur, generation);
      }
      return;
    }
    if (state === 'playing') {
      // pause 可能比 play() 的状态回调先到。最终意图已是暂停时,不能把迟到的 playing 当成成功起播。
      if (!this.playbackDesiredPlaying) {
        try {
          await p.pause();
        } catch (e) {
          Log.w('Player', `纠正迟到起播失败 ${(e as Error).message}`);
        }
        return;
      }
      this.loadRetries = 0;
      this.loading = false;
      this.buffering = false;
      this.playbackError = '';
      this.cancelLoadRetry();
      this.isPlaying = true;
      this.startTicker();
      this.notify();
      return;
    }
    if (state === 'paused') {
      this.loading = false;
      this.isPlaying = false;
      this.stopTicker();
      this.saveProgress();
      if (this.onListenFlush !== null) this.onListenFlush();
      // 快速 pause→resume 时旧 paused 事件可能晚到；只让仍然有效的暂停意图释放会话。
      if (!this.playbackDesiredPlaying) this.deactivateAudioSession();
      this.notify();
      return;
    }
    if (state === 'completed') {
      this.loading = false;
      this.isPlaying = false;
      this.stopTicker();
      const cur = this.current;
      if (cur !== null && this.history !== null && !GuideEpisode.isGuide(cur.id)) {
        this.history.updatePosition(cur.id, 0, this.durationMs);
        this.history.markPlayed(cur.id, true);
      }
      if (this.onListenFlush !== null) this.onListenFlush();
      const stopAfter = this.sleepEndOfEpisode;
      this.sleepEndOfEpisode = false;
      let continues = false;
      if (!stopAfter) {
        if (this.radioMode) {
          continues = true;
          this.advanceRadio();
        } else if (this.userQueue.length > 0) {
          continues = true;
          this.consumeQueueAt(0);
        } else if (this.queueIndex < this.queue.length - 1) {
          continues = true;
          this.next();
        }
      }
      // 自动续集/用户队列/电台取下一首期间保持会话;只有真正播完或睡眠到集尾才释放。
      if (!continues) {
        this.playbackDesiredPlaying = false;
        this.deactivateAudioSession();
      }
      this.notify();
    }
  }

  /// AudioSession 失败不是媒体源失败,不能为此重置音源并重新下载三次。
  private handleAudioSessionFailure(generation: number): void {
    if (generation <= 0 || generation !== this.loadGeneration) return;
    this.loading = false;
    this.isPlaying = false;
    this.buffering = false;
    this.playbackDesiredPlaying = false;
    this.playbackError = L.s('playback_load_failed');
    this.deactivateAudioSession();
    Log.e('Player', `AudioSession 激活失败 generation=${generation}`);
    this.notify();
  }

  /// 同一代次的 prepare/error/play 失败只处理一次;自动重试始终只有一个待执行任务。
  private handleLoadFailure(e: Episode, generation: number): void {
    if (generation <= 0 || generation !== this.loadGeneration
      || this.current === null || this.current.id !== e.id
      || this.failedGeneration === generation) return;
    this.failedGeneration = generation;
    this.clearFade();
    this.stopTicker();
    this.isPlaying = false;
    this.buffering = false;
    if (this.loadRetries < 3) {
      this.loadRetries += 1;
      this.loading = true;
      Log.w('Player', `加载失败,自动重试 ${this.loadRetries}/3 generation=${generation}`);
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        if (generation === this.loadGeneration && this.current !== null && this.current.id === e.id) {
          this.startEpisode(e, false);
        }
      }, 800);
    } else {
      this.loading = false;
      this.playbackDesiredPlaying = false;
      this.playbackError = L.s('playback_load_failed');
      this.deactivateAudioSession();
      Log.e('Player', `重试耗尽 generation=${generation},等待用户手动重试`);
    }
    this.notify();
  }

  private cancelLoadRetry(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  retry(): void {
    const e = this.current;
    if (e === null) return;
    this.startEpisode(e, true);
  }

  // ── 传输控制 ──

  togglePlayPause(): void {
    // loading 时 isPlaying 还没变成 true,只能按明确意图判断这次点击是暂停还是恢复。
    if (this.loading ? this.playbackDesiredPlaying : this.isPlaying) this.pausePlayback();
    else this.resumePlayback();
  }

  /// 明确暂停动作,重复调用不会反向恢复。公开方法保持 fire-and-forget,供 ArkUI 与 AVSession 同步调用。
  pausePlayback(): void {
    this.playbackDesiredPlaying = false;
    const actionGeneration = ++this.playbackActionGeneration;
    this.playbackActionTask = this.playbackActionTask.then((): Promise<void> => {
      return this.pausePlaybackAsync(actionGeneration);
    });
  }

  private async pausePlaybackAsync(actionGeneration: number): Promise<void> {
    if (actionGeneration !== this.playbackActionGeneration) return;
    const p = this.player;
    if (p === null || p.state !== 'playing') {
      this.deactivateAudioSession();
      return;
    }
    try {
      await p.pause();
      // resume 可能在 pause 的 Promise 返回前已经排队；旧暂停动作不能撤销新的恢复会话。
      if (actionGeneration === this.playbackActionGeneration && !this.playbackDesiredPlaying) {
        this.deactivateAudioSession();
      }
    } catch (e) {
      Log.w('Player', `暂停失败 ${(e as Error).message}`);
    }
  }

  /// 明确恢复动作,重复调用只会确认会话仍激活,不会反向暂停。
  resumePlayback(): void {
    this.playbackDesiredPlaying = true;
    const actionGeneration = ++this.playbackActionGeneration;
    // prepare 尚未完成时只更新意图；prepared 回调会按最新意图激活会话并起播。
    if (this.loading) return;
    if (this.playbackError.length > 0) {
      this.retry();
      return;
    }
    this.playbackActionTask = this.playbackActionTask.then((): Promise<void> => {
      return this.resumePlaybackAsync(actionGeneration);
    });
  }

  private async resumePlaybackAsync(actionGeneration: number): Promise<void> {
    if (actionGeneration !== this.playbackActionGeneration) return;
    const p = this.player;
    if (p === null) {
      const cur = this.current;
      if (cur !== null) this.retry();
      return;
    }
    const generation = this.sourceGeneration;
    try {
      const sessionGeneration = await this.activateAudioSession();
      // AudioSession 激活返回时重新确认播放器、音源和明确动作仍是发起恢复时的对象与代次。
      if (actionGeneration !== this.playbackActionGeneration
        || generation <= 0 || generation !== this.loadGeneration || this.sourceGeneration !== generation
        || this.released || this.player !== p || !this.playbackDesiredPlaying
        || sessionGeneration !== this.audioSessionGeneration || !this.audioSessionDesiredActive) return;
      if (!this.isAudioSessionReady(sessionGeneration)) {
        this.handleAudioSessionFailure(generation);
        return;
      }
      if (p.state !== 'playing') await p.play();
      if (actionGeneration !== this.playbackActionGeneration
        || generation !== this.loadGeneration || this.sourceGeneration !== generation
        || this.released || this.player !== p || !this.playbackDesiredPlaying
        || sessionGeneration !== this.audioSessionGeneration || !this.audioSessionDesiredActive) {
        if (!this.audioSessionDesiredActive && this.player === p && p.state === 'playing') await p.pause();
        return;
      }
      this.applyRate(p, this.speed);
    } catch (e) {
      Log.w('Player', `恢复播放失败 ${(e as Error).message}`);
      const cur = this.current;
      if (cur !== null) this.handleLoadFailure(cur, generation);
    }
  }

  seekTo(ms: number): void {
    const p = this.player;
    if (p === null) return;
    const t = Math.max(0, ms);
    try {
      p.seek(t, media.SeekMode.SEEK_PREV_SYNC);
    } catch (e) {
      Log.w('Player', `seek 失败 ${(e as Error).message}`);
      return;
    }
    this.clock.positionMs = t;
    // seek 后把基线推到新位置,避免跳变被计入收听
    this.clock.countedPosMs = t;
    // seek 是"位置突变",必须 notify:锁屏/控制中心的进度只靠这一下纠偏
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
    if (p !== null && this.isPlaying) this.applyRate(p, s);
    this.notify();
  }

  /// 设置倍速。AVPlayer 只有播放态允许 setPlaybackRate,状态切换中不发无效操作。
  private applyRate(p: media.AVPlayer, rate: number): void {
    if (p.state !== 'playing') return;
    try {
      p.setPlaybackRate(rate);
    } catch (e) {
      Log.w('Player', `设置倍速失败 ${(e as Error).message}`);
    }
  }

  // ── 队列导航 ──

  next(): void {
    if (this.radioMode) {
      if (this.radioPos >= 0 && this.radioPos < this.radioHistory.length - 1) {
        this.radioPos += 1;
        this.updateNavFlags();
        this.startEpisode(this.radioHistory[this.radioPos], true);
      } else {
        this.advanceRadio();
      }
      return;
    }
    if (this.userQueue.length > 0) {
      this.consumeQueueAt(0);
      return;
    }
    if (this.queueIndex < this.queue.length - 1) {
      this.queueIndex += 1;
      this.updateNavFlags();
      this.startEpisode(this.queue[this.queueIndex], true);
    }
  }

  previous(): void {
    if (this.radioMode) {
      if (this.radioPos > 0) {
        this.radioPos -= 1;
        this.updateNavFlags();
        this.startEpisode(this.radioHistory[this.radioPos], true);
      }
      return;
    }
    if (this.queueIndex > 0) {
      this.queueIndex -= 1;
      this.updateNavFlags();
      this.startEpisode(this.queue[this.queueIndex], true);
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

  // ── 随机 / 情境电台 ──

  startRadio(next: () => Promise<Episode | null>): void {
    Log.i('Radio', '开台');
    this.radioNext = next;
    this.radioHistory = [];
    this.radioPos = -1;
    this.radioMode = true;
    this.updateNavFlags();
  }

  stopRadio(): void {
    if (this.radioMode) Log.i('Radio', `停台 历史=${this.radioHistory.length}`);
    this.radioNext = null;
    this.radioMode = false;
    this.updateNavFlags();
  }

  /// 地区改变时只丢弃电台前后导航,当前音频与普通收听历史不受影响。
  resetRadioHistory(): void {
    this.radioHistory = [];
    this.radioPos = -1;
    this.updateNavFlags();
  }

  /// 播放电台抓到的一集(记入电台历史,便于「上一首」回看)。
  playRadioEpisode(e: Episode): void {
    this.radioHistory.push(e);
    if (this.radioHistory.length > this.radioHistoryCap) this.radioHistory.shift();
    this.radioPos = this.radioHistory.length - 1;
    this.updateNavFlags();
    this.startEpisode(e, true);
  }

  /// 本集播完:抓下一首;抓不到则自动停台。
  /// 单飞:快速连点「下一首」会并发进来多个,只让第一个真正抓源,
  /// 否则后到的 null 结果会把前一个成功请求刚开的台停掉(见 H74)。
  private async advanceRadio(): Promise<void> {
    if (this.radioAdvancing) return;
    const next = this.radioNext;
    if (next === null) {
      this.playbackDesiredPlaying = false;
      this.deactivateAudioSession();
      return;
    }
    this.radioAdvancing = true;
    Log.i('Radio', '抓下一首…');
    try {
      const e = await next();
      if (e !== null && this.radioMode) this.playRadioEpisode(e);
      else {
        Log.w('Radio', '无下一首,停台');
        this.stopRadio();
        this.playbackDesiredPlaying = false;
        this.deactivateAudioSession();
      }
    } catch (e) {
      Log.w('Radio', `抓下一首失败 ${(e as Error).message}`);
      this.stopRadio();
      this.playbackDesiredPlaying = false;
      this.deactivateAudioSession();
    } finally {
      this.radioAdvancing = false;
    }
  }

  /// 队列内重排(上移/下移)。
  moveInQueue(from: number, to: number): void {
    const n = this.userQueue.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from === to) return;
    const next = this.userQueue.slice();
    const item = next.splice(from, 1)[0];
    next.splice(to, 0, item);
    this.userQueue = next;
    this.updateNavFlags();
  }

  clearQueue(): void {
    this.userQueue = [];
    this.updateNavFlags();
  }

  private consumeQueueAt(index: number): void {
    const e = this.userQueue[index];
    if (!e) return;
    this.userQueue = this.userQueue.filter((x: Episode) => x.id !== e.id);
    // 队列上下文改为单曲:本集播完按既有规则推进(剩余用户队列优先,其次上下文队列)
    this.queue = [e];
    this.queueIndex = 0;
    this.updateNavFlags();
    this.startEpisode(e, true);
  }

  /// 点击队列中的单集直接跳播:从队列摘出立即播放,剩余顺序不动。
  playFromQueue(id: string): void {
    this.consumeQueueAt(this.userQueue.findIndex((x: Episode) => x.id === id));
  }

  private updateNavFlags(): void {
    if (this.radioMode) {
      this.hasPrev = this.radioPos > 0;
      this.hasNext = true;   // 在台永远有下一首(现抓)
    } else {
      this.hasPrev = this.queueIndex > 0;
      this.hasNext = (this.queueIndex >= 0 && this.queueIndex < this.queue.length - 1) || this.userQueue.length > 0;
    }
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
        if (p !== null) p.setVolume(1.0);
        this.pausePlayback();
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

  private fadeVolume(target: number, durationMs: number, generation: number): void {
    this.clearFade();
    const steps = Math.max(1, Math.floor(durationMs / 50));
    let i = 0;
    this.fadeTimer = setInterval(() => {
      if (generation !== this.loadGeneration) {
        this.clearFade();
        return;
      }
      const p = this.player;
      if (p === null || (p.state !== 'prepared' && p.state !== 'playing'
        && p.state !== 'paused' && p.state !== 'completed')) {
        this.clearFade();
        return;
      }
      i += 1;
      const f = Math.min(1, i / steps);
      try {
        p.setVolume(target * f);
      } catch (e) {
        Log.w('Player', `淡入失败 ${(e as Error).message}`);
        this.clearFade();
        return;
      }
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

  /**
   * 这里**刻意不 notify**。
   *
   * 原先每 500ms notify 一次,用来驱动界面进度刷新 —— 但 notify 会把 `Index` 的
   * `@State tick` +1,那是整棵树的重建,而且还顺带每 500ms 往 AVSession 推一次状态
   * (日志里伴随 `syncExecutor timeout`)。进度改由各界面按需轮询 `clock` 之后,
   * 这一跳就没有消费者了:notify 只留给**真实状态变化**(播放/暂停/换集/seek/倍速/缓冲/时长)。
   */
  private startTicker(): void {
    this.stopTicker();
    this.tickTimer = setInterval(() => {
      const p = this.player;
      if (p === null) return;
      this.countListening();
      this.clock.ticks += 1;
      if (this.clock.ticks % 10 === 0) this.saveProgress();   // 约每 5 秒
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
    // 引导音频不写历史:playEpisode 已跳过 record,这里若还写就会又建出一条
    if (GuideEpisode.isGuide(e.id)) return;
    this.history.updatePosition(e.id, Math.max(0, this.positionMs), Math.max(0, this.durationMs));
  }

  /// 累计"实际播放过的内容毫秒":同一集 + 播放中 + 增量 ∈[1,3000]ms。
  /// 快进/快退的大跳变与暂停自然被剔除;倍速下按内容时长计。
  private countListening(): void {
    const e = this.current;
    if (e === null) {
      this.clock.countedEpId = '';
      return;
    }
    if (GuideEpisode.isGuide(e.id)) return;   // 引导音频不计时长
    if (e.id === this.clock.countedEpId) {
      const delta = this.positionMs - this.clock.countedPosMs;
      if (this.isPlaying && delta >= 1 && delta <= 3000 && this.onListened !== null) {
        this.onListened(e, delta);
      }
    }
    this.clock.countedPosMs = this.positionMs;
    this.clock.countedEpId = e.id;
  }

  /// 关闭上一次本地播放的文件句柄(换源/释放时必须调,否则 fd 泄漏)。
  private closeLocalFile(): void {
    const f = this.localFile;
    this.localFile = null;
    if (f !== null) {
      try {
        fs.closeSync(f);
      } catch (e) {
        // 忽略
      }
    }
  }

  private notify(): void {
    if (this.onStateChanged !== null) this.onStateChanged();
  }

  async release(): Promise<void> {
    this.released = true;
    this.playbackDesiredPlaying = false;
    this.loadGeneration += 1;
    this.playbackActionGeneration += 1;
    this.sourceGeneration = 0;
    this.failedGeneration = -1;
    this.cancelLoadRetry();
    this.stopTicker();
    this.clearFade();
    this.clearSleepTicker();
    this.loading = false;
    this.buffering = false;
    try {
      await this.loadTask;
      await this.playbackActionTask;
      let p = this.player;
      const creating = this.playerCreation;
      if (p === null && creating !== null) p = await creating;
      this.playerCreation = null;
      this.player = null;
      this.closeLocalFile();
      if (p !== null) {
        try {
          this.unbindSourceEvents(p);
          p.off('timeUpdate');
          await p.release();
        } catch (e) {
          // 忽略
        }
      }
    } finally {
      // 不论播放器释放是否成功,最终都要让串行状态机收敛到「无 AudioSession」。
      this.deactivateAudioSession();
      const task = this.audioSessionTask;
      await task;
    }
  }
}
