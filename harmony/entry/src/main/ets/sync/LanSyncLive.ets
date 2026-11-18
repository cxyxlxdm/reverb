import { Episode } from '../model/Models';
import { Codec } from '../store/Codec';
import { Log } from '../util/Logger';

/**
 * 交接时一台设备要告诉对方的播放状态。`episode == null` 表示"已经没有可交接的内容"。
 *
 * **只带播放要用的字段**:`description`(shownotes)是几十 KB 的常客,1 Hz 发一遍等于
 * 把整篇稿件每秒传一次;接手的设备要的是 id / 标题 / 音频地址 / 封面。
 * 字段名与 Android `LanPlaybackStatus` / Apple 同名类型逐字相同 —— 三端互相解对方的帧。
 */
export class LanPlaybackStatus {
  episode: Episode | null = null;
  positionMs: number = 0;
  durationMs: number = 0;
  playing: boolean = false;
  rate: number = 1.0;
  /** 发送者的墙钟毫秒。**只用于显示外推**,不参与任何排序。 */
  atMs: number = 0;

  static nowMs(): number {
    return Date.now();
  }

  /** 线格式:`{t, ep?, pos, dur, playing, rate, at}`。 */
  frame(type: string): Record<string, Object> {
    const f: Record<string, Object> = {};
    f['t'] = type;
    f['pos'] = Math.round(this.positionMs);
    f['dur'] = Math.round(this.durationMs);
    f['playing'] = this.playing;
    f['rate'] = this.rate;
    f['at'] = Math.round(this.atMs);
    const ep = this.episode;
    if (ep !== null) {
      const obj = Codec.episodeToJson(ep);
      obj['description'] = '';
      f['ep'] = obj;
    }
    return f;
  }

  /** 解析失败(缺 pos)返回 null —— 调用方按「对方没有内容」处理,不把半条帧当状态。 */
  static parse(f: Record<string, Object>): LanPlaybackStatus | null {
    const pos = f['pos'];
    if (typeof pos !== 'number') return null;
    const s = new LanPlaybackStatus();
    const raw = f['ep'];
    if (raw !== undefined && raw !== null) {
      s.episode = Codec.episodeFromJson(raw as Record<string, Object>);
    }
    s.positionMs = pos as number;
    s.durationMs = LanPlaybackStatus.num(f, 'dur');
    s.playing = f['playing'] === true;
    const rate = LanPlaybackStatus.num(f, 'rate');
    s.rate = rate > 0 ? rate : 1.0;
    s.atMs = LanPlaybackStatus.num(f, 'at');
    return s;
  }

  private static num(f: Record<string, Object>, key: string): number {
    const v = f[key];
    return typeof v === 'number' ? v as number : 0;
  }
}

/** 界面拿到的「另一台设备」状态。位置已按估计的时钟偏差外推到**现在**。 */
export class LanPeerHint {
  episode: Episode;
  positionMs: number;
  playing: boolean;
  /** 时钟样本不足 / 往返太大 ⇒ 位置只当参考,界面写「约 12:34」。 */
  approximate: boolean;

  constructor(episode: Episode, positionMs: number, playing: boolean, approximate: boolean) {
    this.episode = episode;
    this.positionMs = positionMs;
    this.playing = playing;
    this.approximate = approximate;
  }
}

/** ping-pong 四时间戳的偏差估计。`offset` 是「对端时钟 − 本机时钟」的毫秒数。 */
export class LanClockSample {
  offsetMs: number;
  rttMs: number;

  constructor(offsetMs: number, rttMs: number) {
    this.offsetMs = offsetMs;
    this.rttMs = rttMs;
  }
}

export class LanClockEstimator {
  private samples: LanClockSample[] = [];

  get offsetMs(): number {
    return LanClockEstimator.median(this.samples.map((s: LanClockSample): number => s.offsetMs));
  }

  get rttMs(): number {
    return LanClockEstimator.median(this.samples.map((s: LanClockSample): number => s.rttMs));
  }

  /** 少于两组就不外推:只有一组时无法判断它是不是恰好被调度尖峰拉偏。 */
  get usable(): boolean {
    return this.samples.length >= 2;
  }

  add(s: LanClockSample): void {
    if (!Number.isFinite(s.rttMs) || s.rttMs < 0 || s.rttMs > 2_000) return;
    this.samples.push(s);
    if (this.samples.length > LanClockEstimator.CAPACITY) {
      this.samples.splice(0, this.samples.length - LanClockEstimator.CAPACITY);
    }
  }

  /** t0 = 本机发出 ping,t1 = 对端收到,t2 = 对端发出 pong,t3 = 本机收到。 */
  static sample(t0: number, t1: number, t2: number, t3: number): LanClockSample | null {
    const rtt = (t3 - t0) - (t2 - t1);
    if (rtt < 0 || rtt > 2_000) return null;
    const offset = ((t1 - t0) + (t2 - t3)) / 2.0;
    return new LanClockSample(offset, rtt);
  }

  static median(values: number[]): number {
    if (values.length === 0) return 0;
    const sorted = values.slice(0).sort((a: number, b: number): number => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
  }

  static readonly CAPACITY: number = 5;
}

/**
 * 交接的实时通道。同步完成之后**复用同一条已认证的 TCP**,不再配对一次。
 *
 * 产品边界(见 `docs/research/2026-11-11-lan-sync.md` §6):
 * - 只在「正在播放」时 1 Hz 发状态;暂停/跳转/切集立即补一条;
 * - **不自动接管** —— 必须对方屏幕上点「在此设备继续」;
 * - 交接流程固定为「请求方 take → 播放方先暂停并回 taken(带最终位置)→ 请求方 seek 再播」,
 *   所以两台设备不会同时出声;
 * - 面板关掉 socket 就断,这也是「不在后台常驻」承诺的实现方式。
 *
 * 鸿蒙的 socket 是事件回调(见 `LanSyncWire` 的 `LanSyncChannel`),所以这里是一个
 * 「读循环 + 250ms 定时器」的两条 async 链:读循环只处理帧,定时器只推本机状态。
 * 不共享可重入的队列 —— 收发互不阻塞,与 Android 的协程版同一个结构。
 */
export class LanSyncLive {
  private send: (f: Record<string, Object>) => Promise<void>;
  private receive: () => Promise<Record<string, Object>>;
  private provider: () => Promise<LanPlaybackStatus | null>;
  private pauseForTake: () => Promise<LanPlaybackStatus | null>;
  private onPeer: (hint: LanPeerHint | null, clock: LanClockEstimator) => void;
  private onTaken: (ep: Episode, positionMs: number) => void;
  private onEnded: () => void;

  private stopped: boolean = false;
  private tickTimer: number = -1;
  private clock: LanClockEstimator = new LanClockEstimator();
  private lastPeerStatus: LanPlaybackStatus | null = null;
  private lastSignature: string = 'none';
  private lastSentAt: number = 0;
  private lastPositionMs: number = 0;
  /** -1 = 没发过 take;超时后 `takeTimedOut` 置 true,迟到的 taken 不再把播放器拽走。 */
  private takeSentAt: number = -1;
  private takeTimedOut: boolean = false;
  private nextPing: number = 0;
  private pingBurst: number = 0;

  constructor(
    send: (f: Record<string, Object>) => Promise<void>,
    receive: () => Promise<Record<string, Object>>,
    provider: () => Promise<LanPlaybackStatus | null>,
    pauseForTake: () => Promise<LanPlaybackStatus | null>,
    onPeer: (hint: LanPeerHint | null, clock: LanClockEstimator) => void,
    onTaken: (ep: Episode, positionMs: number) => void,
    onEnded: () => void
  ) {
    this.send = send;
    this.receive = receive;
    this.provider = provider;
    this.pauseForTake = pauseForTake;
    this.onPeer = onPeer;
    this.onTaken = onTaken;
    this.onEnded = onEnded;
  }

  /** 读循环。阻塞在对端帧上;对端关面板 / 本端关闭 socket 时返回。 */
  async run(): Promise<void> {
    this.scheduleTick();
    try {
      while (!this.stopped) {
        const frame = await this.receive();
        await this.handle(frame);
      }
    } catch (e) {
      if (!this.stopped) {
        // 对端关面板 / 老版本在同步完就断开,都走到这里。不是错误,不弹窗。
        Log.i('LanSync.Live', `交接通道结束:${(e as Error).message}`);
      }
    }
    this.stopTicker();
    this.onEnded();
  }

  stop(): void {
    this.stopped = true;
    this.stopTicker();
  }

  /** 用户点「在此设备继续」。**只发请求,不先播** —— 等对方的 `taken` 带最终位置回来。 */
  async take(): Promise<void> {
    if (this.takeSentAt >= 0 || this.takeTimedOut) return;
    this.takeSentAt = LanPlaybackStatus.nowMs();
    const f: Record<string, Object> = {};
    f['t'] = 'take';
    await this.send(f);
  }

  /** 超时后取消这次请求:迟到的 `taken` 不再把播放器拽走。 */
  cancelTake(): void {
    this.takeSentAt = -1;
    this.takeTimedOut = true;
  }

  allowTakeAgain(): void {
    this.takeTimedOut = false;
  }

  // ---- 帧 ----

  private async handle(frame: Record<string, Object>): Promise<void> {
    const t = frame['t'] as string;
    if (t === 'pb') {
      const status = LanPlaybackStatus.parse(frame);
      if (status !== null) {
        this.onPeer(this.hint(status), this.clock);
      } else {
        // 「对方现在没有在播的内容」:清掉上一份,否则下一次 pong 会把旧提示又推回来。
        this.lastPeerStatus = null;
        this.onPeer(null, this.clock);
      }
      return;
    }
    if (t === 'ping') {
      const t1 = LanPlaybackStatus.nowMs();
      const pong: Record<string, Object> = {};
      pong['t'] = 'pong';
      pong['t0'] = LanSyncLive.num(frame, 't0');
      pong['t1'] = t1;
      pong['t2'] = LanPlaybackStatus.nowMs();
      await this.send(pong);
      return;
    }
    if (t === 'pong') {
      const s = LanClockEstimator.sample(
        LanSyncLive.num(frame, 't0'),
        LanSyncLive.num(frame, 't1'),
        LanSyncLive.num(frame, 't2'),
        LanPlaybackStatus.nowMs()
      );
      if (s !== null) {
        this.clock.add(s);
        const st = this.lastPeerStatus;
        this.onPeer(st === null ? null : this.hint(st), this.clock);
      }
      return;
    }
    if (t === 'take') {
      const status = await this.pauseForTake();
      if (status !== null) {
        await this.send(status.frame('taken'));
      } else {
        const none: Record<string, Object> = {};
        none['t'] = 'taken';
        none['none'] = true;
        await this.send(none);
      }
      return;
    }
    if (t === 'taken') {
      const sentAt = this.takeSentAt;
      this.takeSentAt = -1;
      if (sentAt < 0) return;
      if (frame['none'] === true) return;
      const status = LanPlaybackStatus.parse(frame);
      if (status === null || status.episode === null) return;
      const rtt = Math.max(0, LanPlaybackStatus.nowMs() - sentAt);
      this.onTaken(
        status.episode,
        LanSyncLive.handoffPosition(status.positionMs, rtt, status.rate, status.durationMs)
      );
    }
  }

  private hint(status: LanPlaybackStatus): LanPeerHint | null {
    this.lastPeerStatus = status;
    const ep = status.episode;
    if (ep === null) return null;
    const approximate = !this.clock.usable || this.clock.rttMs > 2_000;
    let pos = status.positionMs;
    if (!approximate && status.playing) {
      const peerNow = status.atMs + this.clock.offsetMs;
      const elapsed = (LanPlaybackStatus.nowMs() - peerNow) / 1000.0;
      // 外推只在一分钟内可信;对端时钟被改过 / 休眠很久时不要画出离谱的位置。
      if (elapsed > -5 && elapsed < 60) pos = pos + elapsed * status.rate * 1000.0;
    }
    if (status.durationMs > 0) pos = Math.min(Math.max(0, pos), status.durationMs);
    return new LanPeerHint(ep, Math.max(0, Math.round(pos)), status.playing, approximate);
  }

  // ---- 本机状态推送 ----

  private scheduleTick(): void {
    this.tickTimer = setTimeout((): void => {
      this.onTick();
    }, 0);
  }

  private stopTicker(): void {
    if (this.tickTimer >= 0) {
      clearTimeout(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private onTick(): void {
    if (this.stopped) return;
    this.tickOnce().then((): void => {
      if (!this.stopped) {
        this.tickTimer = setTimeout((): void => this.onTick(), 250);
      }
    });
  }

  private async tickOnce(): Promise<void> {
    const now = LanPlaybackStatus.nowMs();
    if (now >= this.nextPing) {
      const ping: Record<string, Object> = {};
      ping['t'] = 'ping';
      ping['t0'] = now;
      this.fire(ping);
      if (this.pingBurst < 5) {
        this.pingBurst++;
        this.nextPing = now + 400;
      } else {
        this.nextPing = now + 5_000;
      }
    }
    await this.pushLocal(now);
  }

  private async pushLocal(now: number): Promise<void> {
    const status = await this.provider();
    let signature = 'none';
    if (status !== null) {
      const id = status.episode === null ? '' : status.episode.id;
      signature = `${id}|${status.playing}|${Math.round(status.rate * 100)}`;
    }
    let seeked = false;
    if (status !== null && status.playing && signature === this.lastSignature && this.lastSentAt > 0) {
      const dt = (now - this.lastSentAt) / 1000.0;
      const expected = this.lastPositionMs + dt * status.rate * 1000.0;
      seeked = Math.abs(status.positionMs - expected) > 2_500;
    }
    const due = signature !== this.lastSignature || seeked ||
      (status !== null && status.playing && now - this.lastSentAt >= 1_000);
    if (!due) return;
    if (status !== null) {
      this.fire(status.frame('pb'));
      this.lastPositionMs = status.positionMs;
    } else {
      this.lastPositionMs = 0;
      const empty: Record<string, Object> = {};
      empty['t'] = 'pb';
      this.fire(empty);
    }
    this.lastSignature = signature;
    this.lastSentAt = now;
  }

  private fire(f: Record<string, Object>): void {
    this.send(f).catch((e: Error) => Log.w('LanSync.Live', `发送失败:${e.message}`));
  }

  /**
   * 交接位置 = 对方暂停时的位置 + 这次 `take` 往返的一半 × 对方速率。
   * 为什么用往返一半而不是时钟偏差:整条路径里只需要知道「消息在网线里走了多久」,
   * 两台的墙钟差多少与这件事无关。末尾留 1.5 秒余量,避免刚好落在结尾被判成已播完。
   */
  static handoffPosition(positionMs: number, rttMs: number, rate: number, durationMs: number): number {
    const advance = Math.max(0, rttMs) / 2.0 * Math.max(0.1, rate);
    let target = Math.max(0, Math.round(positionMs + advance));
    if (durationMs > 1_500) target = Math.min(target, Math.round(durationMs) - 1_500);
    return Math.max(0, target);
  }

  private static num(f: Record<string, Object>, key: string): number {
    const v = f[key];
    return typeof v === 'number' ? v as number : 0;
  }
}
