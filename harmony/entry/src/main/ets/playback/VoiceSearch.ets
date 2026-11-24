import audio from '@ohos.multimedia.audio';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import type common from '@ohos.app.ability.common';
import { SenseVoiceText } from './asr/SenseVoiceText';
import { SenseVoiceTranscriber } from './asr/SenseVoiceTranscriber';
import { Log } from '../util/Logger';

/// `start()` 的三种失败各有不同的界面提示,不能混成一句"失败了"。
export enum VoiceStart {
  Started = 0,
  PermissionDenied = 1,
  Unsupported = 2,
  Failed = 3
}

/**
 * 语音搜索的录音侧:点一下开录、再点一下收尾 → 本机识别成文字 → 填进搜索框。
 *
 * 与 Android `playback/asr/VoiceSearch.kt` 同一条口径:
 *  - **录音只进内存**,不上传、不落盘 —— 识别完数组即丢;应用里没有任何代码路径能把它带走;
 *  - **30 秒上限**:SenseVoice 是 30 秒窗模型,录更长既不增值,又让数组一直涨;
 *    到顶后释放麦克风(用户再点一下照样出结果,只是后面那段没录进去);
 *  - 识别走 `SenseVoiceTranscriber.transcribeSamples`(独立的常驻 Worker,不与整集转写排队)。
 *
 * 生命周期:单例,`AppContainer.boot` 里 attach 一次(只记引用,不申请权限、不碰麦克风)。
 * 麦克风权限**在第一次点麦克风时**才申请 —— 同意隐私政策之前没有任何音频相关调用。
 */
export class VoiceSearch {
  private static instance: VoiceSearch | null = null;
  private static readonly TAG: string = 'Voice';
  /// 30 秒 × 16k × 2 字节。到顶就停收,已收到的照常识别。
  private static readonly MAX_BYTES: number = 30 * 16000 * 2;
  /// 少于 0.3 秒视为误触(按一下就松),不值得起一次识别
  private static readonly MIN_BYTES: number = Math.round(0.3 * 16000 * 2);

  private ctx: common.UIAbilityContext | null = null;
  private transcriber: SenseVoiceTranscriber | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private chunks: ArrayBuffer[] = [];
  private bytes: number = 0;
  private capped: boolean = false;
  /// 每次开录 +1。`cancel()` / 新一次 `start()` 都会推进它,
  /// 在途的 `stopAndTranscribe` 回来时对不上就丢弃结果(与搜索代次同一条思路)。
  private session: number = 0;

  static get(): VoiceSearch {
    if (VoiceSearch.instance === null) VoiceSearch.instance = new VoiceSearch();
    return VoiceSearch.instance;
  }

  attach(ctx: common.UIAbilityContext, transcriber: SenseVoiceTranscriber): void {
    this.ctx = ctx;
    this.transcriber = transcriber;
  }

  /// 这台设备上语音搜索能不能用(引擎装配了 + 模型支持当前界面语言)
  supports(localeId: string): boolean {
    return this.transcriber !== null && this.transcriber.available()
      && this.transcriber.supports(localeId);
  }

  get recording(): boolean {
    return this.capturer !== null;
  }

  /**
   * 开录。先确认麦克风授权(系统只在第一次弹框,之后立即返回),
   * 再建 16k 单声道 s16le 采集器,`readData` 回调里只做拷贝,不碰网络与磁盘。
   */
  async start(): Promise<VoiceStart> {
    const ctx = this.ctx;
    if (ctx === null || this.transcriber === null) return VoiceStart.Unsupported;
    if (this.capturer !== null) return VoiceStart.Started;

    let granted = false;
    try {
      const res = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      granted = res.authResults.length > 0 && res.authResults[0] === 0;
    } catch (e) {
      Log.e(VoiceSearch.TAG, `申请麦克风权限失败:${(e as Error).message}`);
      return VoiceStart.Failed;
    }
    if (!granted) return VoiceStart.PermissionDenied;

    this.chunks = [];
    this.bytes = 0;
    this.capped = false;
    this.session += 1;
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      };
      const c = await audio.createAudioCapturer(options);
      c.on('readData', (buf: ArrayBuffer) => {
        if (this.capped || this.capturer !== c) return;
        const room = VoiceSearch.MAX_BYTES - this.bytes;
        if (room <= 0) {
          this.capped = true;
          return;
        }
        const take = Math.min(room, buf.byteLength);
        // 截断时 slice 一份,别把整块(可能超过上限)留在数组里
        this.chunks.push(take === buf.byteLength ? buf : buf.slice(0, take));
        this.bytes += take;
        if (this.bytes >= VoiceSearch.MAX_BYTES) this.capped = true;
      });
      await c.start();
      this.capturer = c;
      Log.i(VoiceSearch.TAG, '开始录音(16k 单声道,30 秒上限)');
      return VoiceStart.Started;
    } catch (e) {
      Log.e(VoiceSearch.TAG, `开始录音失败:${(e as Error).message}`);
      await this.releaseCapturer();
      return VoiceStart.Failed;
    }
  }

  /**
   * 结束录音并识别。返回 null = 没听清 / 太短 / 出错(界面统一提示"再试一次")。
   * 麦克风在识别**之前**就释放 —— 识别要几秒,没有理由继续占着它。
   */
  async stopAndTranscribe(localeId: string): Promise<string | null> {
    if (this.capturer === null) return null;
    const session = this.session;
    await this.releaseCapturer();

    const total = this.bytes;
    const chunks = this.chunks;
    this.chunks = [];
    this.bytes = 0;
    if (total < VoiceSearch.MIN_BYTES) {
      Log.i(VoiceSearch.TAG, `录音太短,忽略 ${total} 字节`);
      return null;
    }
    const merged = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      const part = new Uint8Array(chunks[i]);
      merged.set(part, offset);
      offset += part.byteLength;
    }
    const samples = SenseVoiceText.pcm16ToFloat(merged);
    if (this.transcriber === null) return null;
    const text = await this.transcriber.transcribeSamples(samples, localeId);
    // 期间被取消 / 又开了新的一次录音:这一份结果作废
    if (session !== this.session) return null;
    return text;
  }

  /// 页面销毁 / 用户离开时收尾:停采集、丢缓冲、作废在途识别。
  cancel(): void {
    this.session += 1;
    this.chunks = [];
    this.bytes = 0;
    this.releaseCapturer();
  }

  private async releaseCapturer(): Promise<void> {
    const c = this.capturer;
    this.capturer = null;
    if (c === null) return;
    try {
      await c.stop();
    } catch (e) {
      // 忽略:可能已经停了
    }
    try {
      c.off('readData');
    } catch (e) {
      // 忽略
    }
    try {
      await c.release();
    } catch (e) {
      // 忽略
    }
  }
}
