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
  /// 每喂多少帧让出一次主线程。25 帧 = 1 秒音频(见 recognizeWindow 里的说明)
  private static readonly FRAMES_PER_YIELD: number = 25;
  /// 等 `onStart` 的上限。等不到就跳过这一窗 —— 硬喂会崩在系统库里
  private static readonly START_TIMEOUT_MS: number = 5000;
  /// `finish` 之后等收尾的上限
  private static readonly FINISH_TIMEOUT_MS: number = 15000;
  private static readonly TAG: string = 'Speech';

  private ctx: common.UIAbilityContext;
  /// 这台设备到底能不能用系统识别。null = 还没试过(第一次问的时候试一次并记住)
  private ok: boolean | null = null;
  private cancelled: boolean = false;
  /// 当前那一窗。监听器只绑一次,回调统一转给它(见 bindListener)
  private cur: WindowSession | null = null;

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
      engine = await this.createEngine(SpeechTranscriber.engineLang(localeId));
      if (engine === null) return false;
      this.bindListener(engine);
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
   * 建引擎。
   *
   * **试过给 `extraParams` 传"长语音"档,结果更差,已放弃。** 记录一下免得后人重试:
   * 系统库(`libspeechrecognizer.z.so`)里确实有 `SpeechRecognitionLong`、
   * `ParseAsrLongEngineOptions`,以及 `recognizerMode` / `maxAudioDuration` /
   * `vadBegin` / `vadEnd` 这些参数名(strings 抓出来的),但**取值字符串抓不到**;
   * 试传 `recognizerMode: 'long'` + `maxAudioDuration: 60000` 之后,
   * 真机上从"10 分钟出 14 行"变成"出 0 行"。既然拿不到官方的取值口径,
   * 就不要在这里瞎猜 —— 保持默认档,并如实向用户说明本机识别的局限。
   */
  private async createEngine(lang: string): Promise<speechRecognizer.SpeechRecognitionEngine | null> {
    try {
      return await speechRecognizer.createEngine({ language: lang, online: 1 });
    } catch (e) {
      Log.e(SpeechTranscriber.TAG, `建引擎失败:${e}`);
      return null;
    }
  }

  /**
   * **监听器只绑一次**(建引擎之后),回调统一转给"当前那一窗"。
   *
   * 为什么不是每窗 `setListener` 一次:真机上那样会**把进程搞崩** ——
   * 上一窗的 `onComplete` 还在派发的时候就换掉监听器、紧接着又 `writeAudio`,
   * 崩在系统的 `libspeechrecognizer.z.so` 里(`AsrEngine::WritePcm`)。
   * 绑一次 + 一个可变的"当前窗"指针,既没有这个竞态,也少了每窗的注册开销。
   */
  private bindListener(engine: speechRecognizer.SpeechRecognitionEngine): void {
    engine.setListener({
      onStart: (_sid: string, _msg: string) => {
        if (this.cur !== null) this.cur.onStarted();
      },
      onEvent: (_sid: string, _code: number, _msg: string) => {},
      onResult: (_sid: string, result: speechRecognizer.SpeechRecognitionResult) => {
        if (this.cur !== null) this.cur.onResult(result);
      },
      onComplete: (_sid: string, _msg: string) => {
        if (this.cur !== null) this.cur.onDone();
      },
      onError: (_sid: string, code: number, msg: string) => {
        if (this.cur !== null) this.cur.onError(code, msg);
      }
    });
  }

  /**
   * 一个窗 = 一个识别会话。顺序**必须是**:startListening → **等 onStart** → 喂帧 → finish → 等收尾。
   *
   * 「等 onStart」这一步是真机教出来的:`startListening` 是异步生效的,不等就喂,
   * 每一帧都报 `1002200010 Write audio failed because the start listening is failed`,
   * 整窗 0 句。
   *
   * 返回这一窗里**定稿的句子**。`isFinal` 之前的中间结果只喂"实时尾巴",让界面看着在动,不进稿。
   */
  private async recognizeWindow(
    engine: speechRecognizer.SpeechRecognitionEngine,
    pcm: Uint8Array,
    sessionId: string,
    sink: TranscriptSink
  ): Promise<string[]> {
    const win = new WindowSession(sink);
    this.cur = win;
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
      this.cur = null;
      return [];
    }

    // 等引擎真的就绪。等不到就放弃这一窗,**绝不硬喂**(硬喂会崩在系统库里)
    const ready = await win.waitStarted(SpeechTranscriber.START_TIMEOUT_MS);
    if (!ready) {
      Log.w(SpeechTranscriber.TAG, `会话 ${sessionId} 迟迟没有 onStart,跳过这一窗`);
      try { engine.cancel(sessionId); } catch (e) { /* 忽略 */ }
      this.cur = null;
      return [];
    }

    // 喂音频。**帧长必须是 640 或 1280**,末尾不足一帧的补零凑满
    const frame = SpeechTranscriber.FRAME_BYTES;
    let at = 0;
    let sinceYield = 0;
    try {
      while (at < pcm.byteLength) {
        if (this.cancelled || win.failed) break;
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
        /**
         * **每喂 1 秒音频让出一次**。一口气把 20 秒(500 帧)推进去会把引擎的 IPC 队列压满,
         * 而且这条链跑在 UI 线程上 —— 不让出的话界面会卡住十几秒。
         * 让出也给了识别结果回调派发的机会,实时尾巴才动得起来。
         */
        sinceYield += 1;
        if (sinceYield >= SpeechTranscriber.FRAMES_PER_YIELD) {
          sinceYield = 0;
          await SpeechTranscriber.yieldOnce();
        }
      }
    } catch (e) {
      // 撞上单次长度上限等:把已喂进去的收尾,拿到手的句子照用
      Log.w(SpeechTranscriber.TAG, `writeAudio 中断于 ${at}/${pcm.byteLength}:${e}`);
    }

    try {
      engine.finish(sessionId);
    } catch (e) {
      Log.w(SpeechTranscriber.TAG, `finish 失败:${e}`);
    }
    // 等收尾。兜底超时,引擎不回话也不能把整条流程吊死
    await win.waitDone(SpeechTranscriber.FINISH_TIMEOUT_MS);
    this.cur = null;
    return win.finals;
  }

  private static yieldOnce(): Promise<void> {
    return new Promise<void>((resolve) => { setTimeout(() => { resolve(); }, 0); });
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

/**
 * 一个识别窗的状态收集器。
 *
 * 存在的理由:监听器**只能绑一次**(每窗重绑会崩,见 `bindListener`),
 * 所以回调必须转给一个"当前窗"对象。这个类就是那个对象 ——
 * 它把回调翻译成两个可以 `await` 的时刻(引擎就绪 / 本窗收尾)与一串定稿句子。
 */
class WindowSession {
  /// 本窗定稿的句子,按到达顺序
  finals: string[] = [];
  /// 引擎报错过(撞上单次长度上限之类)。喂帧的循环看这个提前收手
  failed: boolean = false;

  private sink: TranscriptSink;
  private started: boolean = false;
  private done: boolean = false;
  private startWaiters: (() => void)[] = [];
  private doneWaiters: (() => void)[] = [];

  constructor(sink: TranscriptSink) {
    this.sink = sink;
  }

  onStarted(): void {
    if (this.started) return;
    this.started = true;
    const ws = this.startWaiters;
    this.startWaiters = [];
    for (let i = 0; i < ws.length; i++) ws[i]();
  }

  onResult(result: speechRecognizer.SpeechRecognitionResult): void {
    const text = result.result.trim();
    if (result.isFinal) {
      if (text.length > 0) this.finals.push(text);
      this.sink.onVolatile('');
    } else if (text.length > 0) {
      this.sink.onVolatile(text);
    }
    if (result.isLast) this.onDone();
  }

  onError(code: number, msg: string): void {
    // 1002200003 = 这一窗超了引擎的单次上限。已经拿到的句子照用,不当失败
    if (code !== 1002200003) {
      Log.w('Speech', `识别出错 ${code} ${msg}`);
    }
    this.failed = true;
    // 报错也算"就绪过了",否则 waitStarted 会一直等到超时
    this.onStarted();
    this.onDone();
  }

  onDone(): void {
    if (this.done) return;
    this.done = true;
    const ws = this.doneWaiters;
    this.doneWaiters = [];
    for (let i = 0; i < ws.length; i++) ws[i]();
  }

  /// @returns true = 引擎已就绪;false = 超时(调用方应跳过这一窗,**不要硬喂**)
  waitStarted(timeoutMs: number): Promise<boolean> {
    if (this.started) return Promise.resolve(true);
    return new Promise<boolean>((resolve) => {
      let settled = false;
      this.startWaiters.push(() => {
        if (settled) return;
        settled = true;
        resolve(true);
      });
      setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve(this.started);
      }, timeoutMs);
    });
  }

  waitDone(timeoutMs: number): Promise<void> {
    if (this.done) return Promise.resolve();
    return new Promise<void>((resolve) => {
      let settled = false;
      this.doneWaiters.push(() => {
        if (settled) return;
        settled = true;
        resolve();
      });
      setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve();
      }, timeoutMs);
    });
  }
}
