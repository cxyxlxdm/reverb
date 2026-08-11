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

  async setup(ctx: common.UIAbilityContext, player: PlayerController): Promise<void> {
    if (this.session !== null) return;
    this.ctx = ctx;
    try {
      const s = await avSession.createAVSession(ctx, 'reverb', 'audio');
      this.session = s;

      // 系统控制中心 / 锁屏 / 耳机媒体键的回调
      s.on('play', () => {
        Log.d('AVSession', 'play');
        player.togglePlayPause();
      });
      s.on('pause', () => {
        Log.d('AVSession', 'pause');
        player.togglePlayPause();
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
      // 元信息只在换集时写,避免每 0.5s 打扰系统
      if (e.id !== this.lastAssetId) {
        this.lastAssetId = e.id;
        await s.setAVMetadata({
          assetId: e.id,
          title: e.title,
          artist: e.podcastTitle,
          mediaImage: e.artworkUrl,
          duration: player.durationMs
        });
      }
      await s.setAVPlaybackState({
        state: player.isPlaying ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: { elapsedTime: player.positionMs, updateTime: Date.now() },
        speed: player.speed
      });
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
