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
  private bgRunning = false;
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
    // 播放中申请长时任务,暂停即释放(不白占系统资源)
    if (player.isPlaying) await this.startBackground();
    else await this.stopBackground();
  }

  private async startBackground(): Promise<void> {
    // bgFailed 守卫:失败就不再每 0.5s 重试(否则日志刷屏、白耗资源)
    if (this.bgRunning || this.bgFailed || this.ctx === null) return;
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'com.yuyin.reverb', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      // 用字符串模式版接口(与 module.json5 的 backgroundModes 对应)
      await backgroundTaskManager.startBackgroundRunning(this.ctx, ['audioPlayback'], agent);
      this.bgRunning = true;
      Log.i('Background', '长时任务已申请(audioPlayback)');
    } catch (e) {
      this.bgFailed = true;
      Log.w('Background', `申请失败,后台播放可能被系统回收 ${(e as Error).message}`);
    }
  }

  private async stopBackground(): Promise<void> {
    if (!this.bgRunning || this.ctx === null) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.ctx);
      this.bgRunning = false;
      Log.i('Background', '长时任务已释放');
    } catch (e) {
      Log.w('Background', `释放失败 ${(e as Error).message}`);
    }
  }

  async destroy(): Promise<void> {
    await this.stopBackground();
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
