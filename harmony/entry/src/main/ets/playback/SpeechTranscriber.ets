import speechRecognizer from '@hms.ai.speechRecognizer';
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import type common from '@ohos.app.ability.common';
import { Episode, TranscribedSegment } from '../model/Models';
import { TranscriptState, TranscriptSink, SpeechTranscriberLike } from '../store/TranscriptStore';
import { TranscriptLines } from '../util/TranscriptLines';
import { PcmReader } from './PcmReader';
import { Log } from '../util/Logger';

/**
 * 用**系统的离线语音识别**(Core Speech Kit)把一集音频转成文字。
 *
 * 为什么用系统能力而不是像 Android 那样内置 whisper:
 * - 鸿蒙端只经应用市场分发,包体越小越好,而内置模型要几十 MB;
 * - 系统的识别是**设备端**的(`online: 1` 即离线档),音频不出设备,与"零后端"一致;
 * - 不引入任何第三方 SDK,合规口径最干净。
 *
 * 代价有两个,都写在这里免得后人重新踩:
 *
 * **1. 系统识别不给任何时间戳。** `SpeechRecognitionResult` 只有 `{isFinal, isLast, result}`
 *    —— 连句级时间都没有。所以时间轴必须自己造:把音频切成固定长度的**窗**,一窗一个识别
 *    会话,窗的起止时刻是我们自己算的(喂了多少 PCM ⇒ 多少毫秒,精确),窗内的几句话再按
 *    **字数占比**插值。窗取 20 秒,于是窗内插值的误差被压在一两秒内。
 *
 *    为什么不用"结果回调到达时已喂入多少音频"来定位:识别是流式的,结果比音频滞后且滞后量
 *    不固定;而且我们是尽可能快地喂,不是按实时速度喂 —— 那样所有结果都会挤在末尾到达,
 *    位置信息等于零。窗 + 字数插值不依赖回调时机,是这条路上唯一稳的做法。
 *
 * **2. 没有词级时间 ⇒ 本机识别出来的稿只能整句高亮。** 设置里的「逐字高亮」对这种稿没有效果,
 *    只对**发布方提供的 JSON 逐字稿**有效(那种稿一词一条)。设置项的副标题已如实说明。
 *
 * 将来若要换成三方引擎(拿到词级时间),替换点见 TRANSCRIPT.md 的迁移路径:
 * 只要满足 `SpeechTranscriberLike`,`TranscriptStore` 一行都不用改。
 */
export class SpeechTranscriber implements SpeechTranscriberLike {

  /**
   * 每个识别会话喂多少秒音频。
   *
   * 上限不是我们定的:系统的离线识别对单次会话的音频长度有上限
   * (超了报 `1002200003 Exceeded the maximum audio length supported`),文档没给具体数值,
   * 所以取一个明显安全的 20 秒,并且**真的撞上 1002200003 时会把这一窗提前收尾**(见 feed)。
   *
   * 20 秒同时也是时间轴精度的选择:窗越短,窗内按字数插值的误差越小;
   * 但会话切换有固定开销,窗太短会明显变慢。
   */
  private static readonly WINDOW_SEC: number = 20;
  /**
   * 每次 `writeAudio` 的字节数。**只能是 640 或 1280**(SDK 明确要求),
   * 16kHz / 16bit / 单声道下 1280 字节正好是 40 毫秒。
   */
  private static readonly FRAME_BYTES: number = 1280;
  private static readonly SAMPLE_RATE: number = 16000;
  private static readonly TAG: string = 'Speech';

  private ctx: common.UIAbilityContext;
  /// 这台设备到底能不能用系统识别。null = 还没试过(第一次问的时候试一次并记住)
  private ok: boolean | null = null;
  private cancelled: boolean = false;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  /**
   * 能不能用。两个条件都要满足:**native 的 PCM 解码模块在**(ArkTS 层没有解封装/解码 API,
   * 只能走 native,见 `PcmReader`),以及系统识别引擎创建得起来。
   *
   * 这里只做**不联网、不弹窗**的检查,结果缓存 —— 界面在每次切集时都会问一次。
   */
  available(): boolean {
    if (this.ok !== null) return this.ok;
    this.ok = PcmReader.available();
    if (!this.ok) {
      Log.w(SpeechTranscriber.TAG, 'PCM 解码模块不可用,系统识别这条路走不了');
    }
    return this.ok;
  }

  cancel(): void {
    this.cancelled = true;
  }

  async transcribe(
    episode: Episode,
    localPath: string,
    localeId: string,
    sink: TranscriptSink,
    onState: (s: TranscriptState) => void,
    stale: () => boolean
  ): Promise<boolean> {
    this.cancelled = false;

    // 1) 音频:已下载的直接用;否则先下到缓存目录(转完就删)
    let audio = localPath;
    let temp = '';
    if (audio.length === 0 || !SpeechTranscriber.exists(audio)) {
      onState(TranscriptState.DownloadingAudio);
      temp = await this.downloadToCache(episode);
      if (temp.length === 0) return false;
      audio = temp;
    }
    if (stale() || this.cancelled) { SpeechTranscriber.cleanup(temp); return false; }

    let reader: PcmReader | null = null;
    let engine: speechRecognizer.SpeechRecognitionEngine | null = null;
    try {
      // 2) 打开解码器。16kHz 单声道 16bit —— 识别引擎只吃这一种
      reader = PcmReader.open(audio, SpeechTranscriber.SAMPLE_RATE);
      if (reader === null) {
        Log.w(SpeechTranscriber.TAG, `打不开音频 ${audio}`);
        return false;
      }

      // 3) 建识别引擎。`online: 1` = 离线(设备端),音频不出设备
      engine = await speechRecognizer.createEngine({
        language: SpeechTranscriber.engineLang(localeId),
        online: 1
      });
      onState(TranscriptState.Running);

      let windowIndex = 0;
      let emitted = 0;
      const windowSamples = SpeechTranscriber.WINDOW_SEC * SpeechTranscriber.SAMPLE_RATE;
      while (true) {
        if (stale() || this.cancelled) break;
        const pcm = reader.read(windowSamples);
        if (pcm === null || pcm.byteLength === 0) break;

        const startMs = Math.round(windowIndex * SpeechTranscriber.WINDOW_SEC * 1000);
        // 末窗通常不足一整窗,时长按**实际样本数**算,不能按窗长算 —— 否则末窗的时间轴会被拉长
        const durMs = Math.round(pcm.byteLength / 2 * 1000 / SpeechTranscriber.SAMPLE_RATE);
        const sentences = await this.recognizeWindow(engine, pcm, `w${windowIndex}`, sink);
        windowIndex += 1;
        if (stale() || this.cancelled) break;

        const segs = SpeechTranscriber.layout(sentences, startMs, startMs + durMs);
        for (let i = 0; i < segs.length; i++) {
          sink.onSegment(segs[i]);
          emitted += 1;
        }
        Log.i(SpeechTranscriber.TAG,
          `窗 ${windowIndex - 1} [${startMs}~${startMs + durMs}ms] ${sentences.length} 句 → ${segs.length} 行`);
      }
      Log.i(SpeechTranscriber.TAG, `转写结束 共 ${emitted} 行 id=${episode.id}`);
      return !this.cancelled && !stale() && emitted > 0;
    } catch (e) {
      Log.e(SpeechTranscriber.TAG, `转写失败:${e}`);
      // 引擎创建失败通常意味着这台设备/系统版本没有离线识别能力 —— 记下来,别每次都重试
      if (this.ok === true) this.ok = null;
      return false;
    } finally {
      if (reader !== null) reader.close();
      if (engine !== null) {
        try { engine.shutdown(); } catch (e) { /* 忽略 */ }
      }
      SpeechTranscriber.cleanup(temp);
    }
  }

  /**
   * 一个窗 = 一个识别会话。把 PCM 按 1280 字节一帧喂进去,`finish` 之后等最后一句。
   *
   * 返回这一窗里**定稿的句子**(按到达顺序)。`isFinal` 之前的中间结果只用来喂"实时尾巴",
   * 让界面看着在动,不进最终稿。
   */
  private recognizeWindow(
    engine: speechRecognizer.SpeechRecognitionEngine,
    pcm: Uint8Array,
    sessionId: string,
    sink: TranscriptSink
  ): Promise<string[]> {
    return new Promise<string[]>((resolve) => {
      const finals: string[] = [];
      let settled = false;
      const done = (): void => {
        if (settled) return;
        settled = true;
        resolve(finals);
      };

      engine.setListener({
        onStart: (_sid: string, _msg: string) => {},
        onEvent: (_sid: string, _code: number, _msg: string) => {},
        onResult: (_sid: string, result: speechRecognizer.SpeechRecognitionResult) => {
          const text = result.result.trim();
          if (result.isFinal) {
            if (text.length > 0) finals.push(text);
            sink.onVolatile('');
          } else if (text.length > 0) {
            sink.onVolatile(text);
          }
          if (result.isLast) done();
        },
        onComplete: (_sid: string, _msg: string) => { done(); },
        onError: (_sid: string, code: number, msg: string) => {
          // 1002200003 = 这一窗超了引擎的单次上限。已经拿到的句子照用,不当失败
          if (code !== 1002200003) {
            Log.w(SpeechTranscriber.TAG, `识别出错 ${code} ${msg}`);
          }
          done();
        }
      });

      try {
        engine.startListening({
          sessionId: sessionId,
          audioInfo: {
            audioType: 'pcm',
            sampleRate: SpeechTranscriber.SAMPLE_RATE,
            soundChannel: 1,
            sampleBit: 16
          }
        });
      } catch (e) {
        Log.w(SpeechTranscriber.TAG, `startListening 失败:${e}`);
        done();
        return;
      }

      // 喂音频。**帧长必须是 640 或 1280**,所以末尾不足一帧的要补零凑满
      const frame = SpeechTranscriber.FRAME_BYTES;
      let at = 0;
      try {
        while (at < pcm.byteLength) {
          if (this.cancelled) break;
          const end = Math.min(at + frame, pcm.byteLength);
          let chunk: Uint8Array;
          if (end - at === frame) {
            chunk = pcm.subarray(at, end);
          } else {
            chunk = new Uint8Array(frame);
            chunk.set(pcm.subarray(at, end));
          }
          engine.writeAudio(sessionId, chunk);
          at = end;
        }
      } catch (e) {
        // 撞上长度上限等:把已喂进去的收尾,拿到手的句子照用
        Log.w(SpeechTranscriber.TAG, `writeAudio 中断于 ${at}/${pcm.byteLength}:${e}`);
      }
      try {
        engine.finish(sessionId);
      } catch (e) {
        done();
      }
      // 兜底:引擎没回 onComplete/isLast 也不能把整条流程吊死
      setTimeout(() => { done(); }, 20000);
    });
  }

  /**
   * 把一窗里的几句话摊到 `[startMs, endMs)` 上:**按字数占比**分时长,再逐句按屏宽切。
   *
   * 这是本端时间轴的全部来源(系统识别不给时间戳)。假设是"这一窗内语速大体均匀" ——
   * 20 秒的窗里这个近似很稳,误差远小于"整窗一起亮"。
   */
  private static layout(sentences: string[], startMs: number, endMs: number): TranscribedSegment[] {
    if (sentences.length === 0) return [];
    let total = 0;
    for (let i = 0; i < sentences.length; i++) total += sentences[i].length;
    if (total < 1) return [];
    const span = Math.max(endMs - startMs, 0);
    const out: TranscribedSegment[] = [];
    let acc = 0;
    for (let i = 0; i < sentences.length; i++) {
      const s = startMs + Math.round(span * acc / total);
      acc += sentences[i].length;
      const e = startMs + Math.round(span * acc / total);
      // 一句可能很长(引擎会把一大段话当一句),按屏宽再切,时间同样按字数插值
      const pieces = TranscriptLines.split(sentences[i], s, Math.max(e, s));
      for (let k = 0; k < pieces.length; k++) out.push(pieces[k]);
    }
    return TranscriptLines.glueOrphans(out);
  }

  /**
   * 界面/取稿语言 → 引擎的语言码。
   *
   * 系统离线识别支持的语种要用 `listLanguages` 查,**不能假定**。这里只做映射,
   * 真查不到时交给引擎报错、界面落到"这台设备不支持"。
   * 中文一律 `zh-CN`:引擎侧没有单独的繁体离线档,繁体界面下识别出简体也比不能用好。
   */
  private static engineLang(localeId: string): string {
    if (localeId.startsWith('zh')) return 'zh-CN';
    if (localeId.startsWith('en')) return 'en-US';
    return localeId.length > 0 ? localeId : 'zh-CN';
  }

  private async downloadToCache(episode: Episode): Promise<string> {
    if (episode.audioUrl.length === 0) return '';
    const dest = `${this.ctx.cacheDir}/asr-${SpeechTranscriber.hash(episode.id)}.audio`;
    const req = http.createHttp();
    try {
      const resp = await req.request(episode.audioUrl, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)' },
        connectTimeout: 15000,
        readTimeout: 180000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode !== 200) {
        Log.w(SpeechTranscriber.TAG, `音频下载失败 http ${resp.responseCode}`);
        return '';
      }
      const f = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, resp.result as ArrayBuffer);
      fs.closeSync(f);
      return dest;
    } catch (e) {
      Log.e(SpeechTranscriber.TAG, `音频下载失败:${e}`);
      return '';
    } finally {
      req.destroy();
    }
  }

  private static exists(p: string): boolean {
    try {
      return fs.accessSync(p);
    } catch (e) {
      return false;
    }
  }

  private static cleanup(p: string): void {
    if (p.length === 0) return;
    try { fs.unlinkSync(p); } catch (e) { /* 忽略 */ }
  }

  private static hash(s: string): number {
    let h = 0;
    for (let i = 0; i < s.length; i++) {
      h = (h * 31 + s.charCodeAt(i)) | 0;
    }
    return Math.abs(h);
  }
}
