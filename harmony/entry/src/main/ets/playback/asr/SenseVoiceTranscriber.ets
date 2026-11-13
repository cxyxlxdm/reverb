import worker from '@ohos.worker';
import type { MessageEvents, ErrorEvent } from '@ohos.worker';
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import resourceManager from '@ohos.resourceManager';
import type common from '@ohos.app.ability.common';
import { Episode, TranscribedSegment } from '../../model/Models';
import { TranscriptState, TranscriptSink, SpeechTranscriberLike } from '../../store/TranscriptStore';
import { SettingsStore } from '../../store/SettingsStore';
import { blockedByCellular } from '../../util/CellularGate';
import { Log } from '../../util/Logger';
import { PcmReader } from '../PcmReader';
import { SenseVoiceText } from './SenseVoiceText';

interface ModelFiles {
  model: string;
  tokens: string;
}

interface AsrCommand {
  cmd: string;
  jobId: number;
  audio: string;
  model: string;
  tokens: string;
  lang: string;
}

interface AsrMessage {
  cmd: string;
  jobId: number;
  ok: boolean;
  message: string;
  seg: TranscribedSegment | null;
}

/**
 * 本机离线识别:**sherpa-onnx + SenseVoiceSmall int8**(1.0.8 起替换系统 Core Speech Kit)。
 *
 * 为什么换掉系统识别(真机实测的结论,见 Features.LOCAL_ASR 的注释与 H62):
 * 系统的 Core Speech Kit 离线档是给"短语音输入/命令词"设计的 —— 一次会话的 VAD
 * 检测到句末静音就收工,10 分钟的中文单集只出 14 行碎片。换成本端后同一段素材能出完整稿件,
 * 中文准确率也明显更好;代价是模型 228 MB 要进包(与 Android 同一取舍,用户已拍板)。
 *
 * 结构上与 Android `SenseVoiceEngine` 一一对应,但**多一层 Worker**:
 * sherpa 的 `decode()` 是同步阻塞的 native 调用,放在 UI 线程上每块 26 秒音频要冻两三秒
 * (见 `asr/AsrWorker.ets` 的文件头)。宿主这里只负责:下载音频 → 把模型从 rawfile
 * 拷到私有目录 → 起 Worker → 把 Worker 回传的句子转给 `TranscriptStore`。
 *
 * 与另三端的差别(写在这里免得对不上):
 *  - 官方逐字稿那条路不经过这里,与引擎是否可用无关;
 *  - 模型只认 zh / en / ja / ko / yue,法语西语界面由 `supports` 提前说清原因。
 */
export class SenseVoiceTranscriber implements SpeechTranscriberLike {
  private static readonly TAG: string = 'SenseVoice';
  /// rawfile 里的目录与文件名(与 Android assets/sensevoice/ 同名)
  private static readonly RAW_MODEL: string = 'sensevoice/model.int8.onnx';
  private static readonly RAW_TOKENS: string = 'sensevoice/tokens.txt';
  private static readonly MODEL_NAME: string = 'model.int8.onnx';
  private static readonly TOKENS_NAME: string = 'tokens.txt';
  /// Worker 脚本路径:相对模块根(entry),不是相对本文件。改路径要同时改
  /// `entry/build-profile.json5` 的 sourceOption.workers,否则构造时报 10200007。
  private static readonly WORKER_URL: string = 'entry/ets/playback/asr/AsrWorker.ets';
  /// 本进程内的临时件序号,给 `asr_*` 文件名加唯一性(与 SpeechTranscriber 同一条)
  private static seq: number = 0;

  private ctx: common.UIAbilityContext;
  /// 蜂窝闸门的判据要读它(用户那个开关)。构造时由 `AppContainer` 传进来。
  private settings: SettingsStore | null;
  private cancelled: boolean = false;
  /// 常驻 Worker:模型只加载一次,复用同一线程(理由见 AsrWorker 文件头)
  private wk: worker.ThreadWorker | null = null;
  private jobSeq: number = 0;
  private currentJob: number = -1;
  /// 当前这次调用的收尾函数。取消时直接结算,不让调用方等 worker 跑完这一块
  private settle: ((ok: boolean) => void) | null = null;
  /// 在途的音频下载。取消时顺手断掉 —— 否则切集之后那几十 MB 还会继续下完才停
  /// (数据最终会被 stale 分支清掉,但流量与时间已经花了)
  private req: http.HttpRequest | null = null;

  constructor(ctx: common.UIAbilityContext, settings: SettingsStore | null) {
    this.ctx = ctx;
    this.settings = settings;
  }

  /**
   * 引擎在这台设备上能不能用。两条都要:**native 的 PCM 解码模块在**
   * (ArkTS 层没有解封装/解码 API,只能走 native,见 `PcmReader`),而且 rawfile 里的
   * 模型没有被漏掉。
   *
   * 模型是否存在不在这里读一遍(228 MB):`build-release.sh` 会在出包前检查它,
   * 漏了会在第一次转写时如实失败并打日志,而不是让"能不能用"每次切集都去碰一个大文件。
   */
  available(): boolean {
    return PcmReader.available();
  }

  /// 这个界面语言有没有对应的本机识别。法语 / 西语界面返回 false(界面据此说清原因)
  supports(localeId: string): boolean {
    return SenseVoiceText.supports(localeId);
  }

  cancel(): void {
    this.cancelled = true;
    if (this.settle !== null) {
      const done = this.settle;
      this.settle = null;
      done(false);
    }
    if (this.wk !== null && this.currentJob >= 0) {
      try {
        this.wk.postMessage({ cmd: 'cancel', jobId: this.currentJob } as AsrCommand);
      } catch (e) {
        // 忽略:worker 已经没了,下一次起任务会重建
      }
    }
    this.currentJob = -1;
    if (this.req !== null) {
      try {
        this.req.destroy();
      } catch (e) {
        // 忽略:下载线程已经结束
      }
    }
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
    const lang = SenseVoiceText.engineLanguage(localeId);
    if (lang.length === 0) {
      Log.w(SenseVoiceTranscriber.TAG, `这个界面语言没有可用的本机识别 locale=${localeId}`);
      return false;
    }

    // 1) 音频:已下载的直接用;否则先下到缓存目录(转完就删)
    let audio = localPath;
    let temp = '';
    if (audio.length === 0 || !SenseVoiceTranscriber.exists(audio)) {
      onState(TranscriptState.DownloadingAudio);
      temp = await this.downloadToCache(episode);
      if (temp.length === 0) return false;
      audio = temp;
    }
    if (stale() || this.cancelled) {
      SenseVoiceTranscriber.cleanup(temp);
      return false;
    }

    // 2) 模型:首次把 rawfile 拷到私有目录(之后按大小跳过)
    onState(TranscriptState.Running);
    const files = await this.ensureModelFiles();
    if (files === null) {
      SenseVoiceTranscriber.cleanup(temp);
      return false;
    }
    if (stale() || this.cancelled) {
      SenseVoiceTranscriber.cleanup(temp);
      return false;
    }

    // 3) 起 Worker,流式拿句子
    const w = this.ensureWorker();
    if (w === null) {
      SenseVoiceTranscriber.cleanup(temp);
      return false;
    }
    const jobId = this.jobSeq + 1;
    this.jobSeq = jobId;
    this.currentJob = jobId;

    return await new Promise<boolean>((resolve) => {
      let settled = false;
      const finish = (ok: boolean): void => {
        if (settled) return;
        settled = true;
        if (this.currentJob === jobId) {
          this.currentJob = -1;
          this.settle = null;
        }
        SenseVoiceTranscriber.cleanup(temp);
        resolve(ok);
      };
      this.settle = finish;

      w.onmessage = (e: MessageEvents): void => {
        const m = e.data as AsrMessage;
        // 上一个任务的尾巴(宿主已取消/已切集)一律丢掉 —— 不带 jobId 判断会把
        // 上一集的句子写进这一集(与 `TranscriptStore` 的代次判据同一件事)。
        if (m.jobId !== jobId) return;
        if (m.cmd === 'segment') {
          if (m.seg !== null && !stale() && !this.cancelled) sink.onSegment(m.seg);
        } else if (m.cmd === 'done') {
          finish(m.ok && !stale() && !this.cancelled);
        } else if (m.cmd === 'error') {
          Log.e(SenseVoiceTranscriber.TAG, `识别失败:${m.message}`);
          finish(false);
        }
      };
      w.onerror = (err: ErrorEvent): void => {
        Log.e(SenseVoiceTranscriber.TAG, `Worker 出错:${err.message}`);
        // 线程已经不健康了:丢掉句柄,下一次转写重建(模型会重新加载,但这是失败路径)
        this.dropWorker();
        finish(false);
      };

      try {
        w.postMessage({
          cmd: 'start', jobId: jobId, audio: audio,
          model: files.model, tokens: files.tokens, lang: lang
        } as AsrCommand);
      } catch (e) {
        Log.e(SenseVoiceTranscriber.TAG, `派发转写任务失败:${(e as Error).message}`);
        this.dropWorker();
        finish(false);
      }
    });
  }

  // ── 内部 ──

  private ensureWorker(): worker.ThreadWorker | null {
    if (this.wk !== null) return this.wk;
    try {
      this.wk = new worker.ThreadWorker(SenseVoiceTranscriber.WORKER_URL);
      return this.wk;
    } catch (e) {
      Log.e(SenseVoiceTranscriber.TAG,
        `创建识别线程失败(检查 build-profile 的 sourceOption.workers):${(e as Error).message}`);
      return null;
    }
  }

  private dropWorker(): void {
    const w = this.wk;
    this.wk = null;
    if (w === null) return;
    try {
      w.terminate();
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 把内置的模型与词表拷到私有目录(只做一次)。
   *
   * 模型按**大小**判断是否已就绪:拷贝中途被杀会留下半个文件,大小不对就重拷
   * (与 Android `ensureModelFiles` 同一条)。期望大小从 rawfile 描述符取,不用把
   * 228 MB 读进内存。词表只有 300 KB,直接整读逐字节写。
   *
   * 为什么必须拷:rawfile 在 hap 里没有普通文件路径,而 228 MB 也不该让 native
   * 每次再从压缩包里解一遍 —— 私有目录上的真实路径才是可直接 mmap 的形态。
   */
  private async ensureModelFiles(): Promise<ModelFiles | null> {
    const dir = `${this.ctx.filesDir}/sensevoice`;
    try {
      if (!fs.accessSync(dir)) fs.mkdirSync(dir);
    } catch (e) {
      Log.e(SenseVoiceTranscriber.TAG, `建模型目录失败:${(e as Error).message}`);
      return null;
    }
    const model = `${dir}/${SenseVoiceTranscriber.MODEL_NAME}`;
    const tokens = `${dir}/${SenseVoiceTranscriber.TOKENS_NAME}`;

    let expected = 0;
    try {
      expected = SenseVoiceTranscriber.rawSize(this.ctx.resourceManager, SenseVoiceTranscriber.RAW_MODEL);
    } catch (e) {
      Log.e(SenseVoiceTranscriber.TAG,
        `读不到内置模型(是否漏跑 tools/build-asr.sh?):${(e as Error).message}`);
      return null;
    }

    let need = true;
    try {
      need = fs.statSync(model).size !== expected;
    } catch (e) {
      need = true;
    }
    if (need) {
      Log.i(SenseVoiceTranscriber.TAG, `首次拷贝模型 ${Math.round(expected / 1024 / 1024)} MB`);
      // 流式拷贝;失败时退回整读(rawfile 若被压缩,fd 路径不可用)
      const copied = await this.copyFromFd(this.ctx.resourceManager, SenseVoiceTranscriber.RAW_MODEL, model, expected);
      if (!copied) {
        Log.e(SenseVoiceTranscriber.TAG, '模型拷贝失败');
        return null;
      }
    }

    try {
      const bytes = this.ctx.resourceManager.getRawFileContentSync(SenseVoiceTranscriber.RAW_TOKENS);
      let same = false;
      try {
        same = fs.statSync(tokens).size === bytes.byteLength;
      } catch (e) {
        same = false;
      }
      if (!same) {
        const f = fs.openSync(tokens, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          const exact = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
          fs.writeSync(f.fd, exact);
        } finally {
          fs.closeSync(f);
        }
        Log.i(SenseVoiceTranscriber.TAG, `词表落地 ${bytes.byteLength} 字节`);
      }
    } catch (e) {
      Log.e(SenseVoiceTranscriber.TAG, `词表不可用:${(e as Error).message}`);
      return null;
    }

    return { model: model, tokens: tokens } as ModelFiles;
  }

  /**
   * 从 rawfile 的描述符按 1 MB 一块流式拷贝到私有目录。
   *
   * 不一次 `getRawFileContent`:228 MB 的 ArrayBuffer 在手机上就是一次 OOM 边缘的分配。
   * 每块 `await` 一次也让 UI 线程有机会喘气(这一步跑在宿主线程上)。
   *
   * @returns 拷贝完整(字节数对上)才算成功
   */
  private async copyFromFd(rm: resourceManager.ResourceManager,
    raw: string, dest: string, expected: number): Promise<boolean> {
    let desc: resourceManager.RawFileDescriptor;
    try {
      desc = rm.getRawFdSync(raw);
    } catch (e) {
      Log.w(SenseVoiceTranscriber.TAG, `rawfile 描述符不可用,回退整读:${(e as Error).message}`);
      return await this.copyWhole(rm, raw, dest, expected);
    }
    const out = await fs.open(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    let pos = 0;
    try {
      const buf = new ArrayBuffer(1 << 20);
      while (pos < expected) {
        const len = Math.min(buf.byteLength, expected - pos);
        const n = await fs.read(desc.fd, buf, { offset: desc.offset + pos, length: len });
        if (n <= 0) break;
        await fs.write(out.fd, buf, { offset: pos, length: n });
        pos += n;
      }
      const size = (await fs.stat(dest)).size;
      if (pos === expected && size === expected) return true;
      Log.w(SenseVoiceTranscriber.TAG, `模型拷贝不完整 ${pos}/${expected}(落盘 ${size})`);
      return false;
    } catch (e) {
      Log.w(SenseVoiceTranscriber.TAG, `流式拷贝失败,回退整读:${(e as Error).message}`);
      return await this.copyWhole(rm, raw, dest, expected);
    } finally {
      await fs.close(out);
      try {
        rm.closeRawFdSync(raw);
      } catch (e) {
        // 忽略
      }
    }
  }

  private async copyWhole(rm: resourceManager.ResourceManager,
    raw: string, dest: string, expected: number): Promise<boolean> {
    try {
      const bytes = await rm.getRawFileContent(raw);
      const out = await fs.open(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const exact = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        await fs.write(out.fd, exact);
      } finally {
        await fs.close(out);
      }
      const size = (await fs.stat(dest)).size;
      return size === expected;
    } catch (e) {
      Log.e(SenseVoiceTranscriber.TAG, `整读拷贝失败:${(e as Error).message}`);
      return false;
    }
  }

  /**
   * 转写前把整集音频拉下来。这是本端**第三条**大流量路径,必须过同一道蜂窝闸门
   * (见 REVIEW-2026-10-25 中-3 与 `util/CellularGate.ets`)。拦下来时返回空串,
   * 调用方按既有失败路径走:界面显示失败,不写坏稿、不留半截文件。
   */
  private async downloadToCache(episode: Episode): Promise<string> {
    if (episode.audioUrl.length === 0) return '';
    if (await blockedByCellular(this.settings, SenseVoiceTranscriber.TAG)) {
      Log.w(SenseVoiceTranscriber.TAG, '蜂窝闸门拦下待转写音频的下载(整集几十 MB),本次转换不启动');
      return '';
    }
    // 临时件名带本次调用号:这个文件转完就删、没有调用点按 id 反推路径,
    // 唯一的号还能顺带挡住"同一集并发两次"写同一个文件(与 SpeechTranscriber 同一条)
    SenseVoiceTranscriber.seq += 1;
    const dest = `${this.ctx.cacheDir}/asr-${SenseVoiceTranscriber.hash(episode.id)}-${SenseVoiceTranscriber.seq}.audio`;
    const part = `${dest}.part`;
    const req = http.createHttp();
    this.req = req;
    let file: fs.File | null = null;
    try {
      // **必须走 requestInStream**:`.request()` 的参数只有响应体在内存里这一种形态,
      // 而鸿蒙的 http 栈给内存响应体设了上限 —— 实测一集 70 MB 的音频在 21:53:06 报
      // "response data exceeds the maximum limit"(libcurl CURLcode 23),
      // 整集转写直接夭折。分片写盘是 DownloadManager / AudioCacheManager 早就在用的路,
      // 这里原先抄了最简单的那个写法,踩的正是它们注释里已经写过的坑(H264)。
      file = await fs.open(part, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const fd = file.fd;
      // 分片写要**串行**:`dataReceive` 的到达可能快过写盘,并发写同一个 fd 会错序。
      // 顺序一乱,音频就再也解不出正确的时间轴(与另外两个下载器同一条)。
      let chain: Promise<void> = Promise.resolve();
      let written = 0;
      let writeFailed = '';
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        chain = chain.then((): Promise<void> => {
          if (writeFailed.length > 0) return Promise.resolve();
          return fs.write(fd, chunk).then((n: number) => { written += n; })
            .catch((err: Error) => { writeFailed = err.message; });
        });
      });
      const code = await req.requestInStream(episode.audioUrl, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)' },
        connectTimeout: 15000,
        readTimeout: 180000
      });
      await chain;
      await fs.close(file);
      file = null;
      if (code !== 200 || writeFailed.length > 0 || written === 0) {
        Log.w(SenseVoiceTranscriber.TAG, `音频下载失败 http=${code} 写入=${written}B ${writeFailed}`);
        SenseVoiceTranscriber.cleanup(part);
        return '';
      }
      // 先 rename 再交出去:中途被杀只会留下 `.part`,不会被下一次当成完整音频去解
      SenseVoiceTranscriber.cleanup(dest);
      await fs.rename(part, dest);
      Log.i(SenseVoiceTranscriber.TAG, `待转写音频就绪 ${Math.round(written / 1024 / 1024)} MB`);
      return dest;
    } catch (e) {
      Log.e(SenseVoiceTranscriber.TAG, `音频下载失败:${(e as Error).message}`);
      if (file !== null) {
        try {
          await fs.close(file);
        } catch (e2) {
          // 忽略
        }
      }
      SenseVoiceTranscriber.cleanup(part);
      return '';
    } finally {
      if (this.req === req) this.req = null;
      try {
        req.off('dataReceive');
        req.destroy();
      } catch (e) {
        // 忽略
      }
    }
  }

  /// rawfile 的字节数(只取描述符,不读内容)。描述符用完立刻关,不泄漏 fd
  private static rawSize(rm: resourceManager.ResourceManager, raw: string): number {
    const desc: resourceManager.RawFileDescriptor = rm.getRawFdSync(raw);
    try {
      return desc.length;
    } finally {
      rm.closeRawFdSync(raw);
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
    try {
      fs.unlinkSync(p);
    } catch (e) {
      // 忽略
    }
  }

  /// id → int32 短键。**不是唯一键**,临时件名另外带了序号(见 `downloadToCache`)
  private static hash(s: string): number {
    let h = s.length;
    for (let i = 0; i < s.length; i++) {
      h = (h * 31 + s.charCodeAt(i)) | 0;
    }
    return Math.abs(h);
  }
}
