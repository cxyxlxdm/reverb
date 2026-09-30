import avSession from '@ohos.multimedia.avsession';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import type common from '@ohos.app.ability.common';
import { PlayerController } from './PlayerController';
import { Log } from '../util/Logger';

/**
 * 系统媒体会话 + 长时任务保活。
 *
 * Android 侧 Media3 的 `MediaSessionService` 把前台服务 + 通知 + 锁屏 + 媒体键全包了
 * (99 行换全套能力);鸿蒙需手动装配:建 session → 写 metadata/playbackState →
 * 注册控制回调 → 申请 AUDIO_PLAYBACK 长时任务。
 */
export class AvSessionBridge {
  private static inst: AvSessionBridge | null = null;
  static get(): AvSessionBridge {
    if (AvSessionBridge.inst === null) AvSessionBridge.inst = new AvSessionBridge();
    return AvSessionBridge.inst;
  }

  private session: avSession.AVSession | null = null;
  /**
   * 长时任务的**目标态 / 已确认态**分开存,再用一条串行队列收敛 ——
   * 系统的 `startBackgroundRunning` / `stopBackgroundRunning` 都是异步的,
   * 而调用方(`sync`)是按播放状态变化触发的,一秒内可以来两次。
   * 见 H125:原先用单个 `bgRunning` 布尔、且在 `await` **之后**才置位,
   * 于是两次重叠的 tick 都看到"还在 running",各自去释放,第二次抛 `9800005`。
   */
  private bgDesired = false;
  private bgHeld = false;
  private bgGeneration = 0;
  private bgTask: Promise<void> = Promise.resolve();
  private bgFailed = false;
  private ctx: common.UIAbilityContext | null = null;
  private lastAssetId = '';
  private lastDuration = 0;
  /// 上一次推给系统的播放状态签名与位置锚点(用于跳过无意义的重复同步,见 sync 注释)
  private lastStateSig = '';
  private lastPushedPosMs = -1;
  private lastPushedAt = 0;

  async setup(ctx: common.UIAbilityContext, player: PlayerController): Promise<void> {
    if (this.session !== null) return;
    this.ctx = ctx;
    try {
      const s = await avSession.createAVSession(ctx, 'reverb', 'audio');
      this.session = s;

      // 系统控制中心 / 锁屏 / 耳机媒体键的回调。play/pause 必须是幂等的明确动作:
      // 系统重复派发同一命令时若走 toggle,第二次会把第一次的结果反转。
      s.on('play', () => {
        Log.d('AVSession', 'play');
        player.resumePlayback();
      });
      s.on('pause', () => {
        Log.d('AVSession', 'pause');
        player.pausePlayback();
      });
      s.on('playNext', () => {
        Log.d('AVSession', 'playNext');
        player.next();
      });
      s.on('playPrevious', () => {
        Log.d('AVSession', 'playPrevious');
        player.previous();
      });
      s.on('seek', (t: number) => {
        Log.d('AVSession', `seek ${t}`);
        player.seekTo(t);
      });
      s.on('fastForward', () => player.skipForward());
      s.on('rewind', () => player.skipBackward());

      await s.activate();
      Log.i('AVSession', '会话已激活');
    } catch (e) {
      Log.e('AVSession', `创建失败 ${(e as Error).message}`);
    }
  }

  /// 把当前播放状态同步到系统(通知栏/锁屏展示 + 进度条)。
  async sync(player: PlayerController): Promise<void> {
    const s = this.session;
    const e = player.current;
    if (s === null || e === null) return;
    try {
      // 元信息在换集时写;时长是异步到达的(durationUpdate),首次拿到后必须补写一次,
      // 否则锁屏/控制中心的进度会一直显示 --:--(duration=0)。
      const durKnown = player.durationMs > 0;
      if (e.id !== this.lastAssetId || (durKnown && this.lastDuration !== player.durationMs)) {
        this.lastAssetId = e.id;
        this.lastDuration = player.durationMs;
        await s.setAVMetadata({
          assetId: e.id,
          title: e.title,
          artist: e.podcastTitle,
          mediaImage: e.artworkUrl,
          duration: player.durationMs
        });
        Log.i('AVSession', `元信息已写 duration=${player.durationMs} title="${e.title}"`);
      }
      // 只在**真的有变化**时才推播放状态。
      //
      // 系统自己会按 `elapsedTime + (now − updateTime) × speed` 外推位置,所以
      // 稳态播放期间反复推同一个状态毫无意义 —— 原先跟着 500ms ticker 走,一秒两次 IPC,
      // 日志里还常伴 `SetAVPlaybackState in syncExecutor timeout`。
      //
      // 判据两条:① 状态签名(播放中/倍速)变了;② 实际位置与"系统按上次锚点外推出来的值"
      // 差超过 1.5 秒 —— seek、自动续集、缓冲卡顿造成的偏差都落在这一条里,
      // 于是不必让调用方区分"这次变化要不要同步"。
      const sig = `${player.isPlaying ? 1 : 0}|${player.speed}`;
      const now = new Date().getTime();
      const predicted = this.lastPushedPosMs < 0 ? -1
        : this.lastPushedPosMs + (player.isPlaying ? (now - this.lastPushedAt) * player.speed : 0);
      const drifted = predicted < 0 || Math.abs(player.positionMs - predicted) > 1500;
      // 注意:这里不能 return —— 后面还有长时任务的申请/释放。
      if (sig !== this.lastStateSig || drifted) {
        this.lastStateSig = sig;
        this.lastPushedPosMs = player.positionMs;
        this.lastPushedAt = now;
        await s.setAVPlaybackState({
          state: player.isPlaying ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
            : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
          // updateTime = 「设置 elapsedTime 时的系统时间」,实测就是 **epoch 毫秒**
          // (`Date.now()`)。系统按 elapsedTime + (now − updateTime) 外推当前位置,
          // 传开机 uptime(量级小 5 个数量级)会让外推值溢出、被钳到时长 ——
          // 表现为锁屏两端都显示总时长、进度条满格。详见 TROUBLESHOOTING H17。
          position: {
            elapsedTime: player.positionMs,
            updateTime: now
          },
          speed: player.speed
        });
      }
    } catch (err) {
      Log.w('AVSession', `同步失败 ${(err as Error).message}`);
    }
    // 保活的判据是**「用户还想不想听」**,不是「AVPlayer 此刻在不在 playing」。
    // 换集那一跳里旧播放器已 completed、新音源还在装,`isPlaying` 会假 0.8~1.2 秒 ——
    // 原先跟着它走会先把长时任务放了再重新申请,系统在那段空窗里就把它回收了(见 H125)。
    this.setBackgroundWanted(player.wantsPlayback());
  }

  /**
   * 声明"现在要不要保活"。**同步置位、异步执行**:目标态在 `await` 之前就写定,
   * 真正的系统调用挂在 `bgTask` 这条串行链上,同一时刻最多只有一个在途操作。
   *
   * 为什么不用"直接 await 一次":`sync` 由播放状态变化驱动,一秒可来多次;
   * 换集时 completed 与 loading 两次 tick 的目标态相反,并发 await 会让后一次
   * 在前一次还没回来时就判"仍持有"而去重复释放 —— 第二次抛 `BussinessError 9800005`。
   */
  private setBackgroundWanted(want: boolean): void {
    if (this.ctx === null) return;
    this.bgDesired = want;
    // 目标态与已确认态一致就不排队:排队本身也是去重(在途那一次回来时会读到最新 desired)
    if (want === this.bgHeld) return;
    const generation = ++this.bgGeneration;
    this.bgTask = this.bgTask.then((): Promise<void> => this.applyBackground(generation));
  }

  private async applyBackground(generation: number): Promise<void> {
    // 过期代次直接丢弃:排队期间目标态可能已经变了,以**运行时的 bgDesired** 为准
    if (generation !== this.bgGeneration) return;
    const want = this.bgDesired;
    if (want === this.bgHeld) return;
    const ctx = this.ctx;
    if (ctx === null) return;
    if (want) {
      // bgFailed 守卫:申请失败过就不再每次状态变化重试(否则日志刷屏、白耗资源)
      if (this.bgFailed) return;
      try {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: 'com.yuyin.reverb', abilityName: 'EntryAbility' }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        // 用字符串模式版接口(与 module.json5 的 backgroundModes 对应)
        await backgroundTaskManager.startBackgroundRunning(ctx, ['audioPlayback'], agent);
        this.bgHeld = true;
        Log.i('Background', '长时任务已申请(audioPlayback)');
      } catch (e) {
        this.bgFailed = true;
        Log.w('Background', `申请失败,后台播放可能被系统回收 ${(e as Error).message}`);
      }
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      Log.i('Background', '长时任务已释放');
    } catch (e) {
      // 释放失败**也认它没了**:`9800005` 本来就是"当前没持有"的意思,
      // 若继续当 running,下次想播时 `want === bgHeld` 会直接跳过申请 —— 那才是真漏。
      Log.w('Background', `释放失败 ${(e as Error).message}`);
    }
    this.bgHeld = false;
  }

  async destroy(): Promise<void> {
    // 等在途的申请/释放收敛完再动,免得 destroy 与它并发(又是 9800005)
    this.setBackgroundWanted(false);
    await this.bgTask;
    const s = this.session;
    this.session = null;
    if (s !== null) {
      try {
        await s.destroy();
      } catch (e) {
        // 忽略
      }
    }
  }
}
