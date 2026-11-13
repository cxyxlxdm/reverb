import worker from '@ohos.worker';
import type { ThreadWorkerGlobalScope, MessageEvents } from '@ohos.worker';
import {
  OfflineRecognizer,
  OfflineRecognizerConfig,
  OfflineRecognizerResult
} from 'sherpa_onnx';
import { TranscribedSegment, TranscribedWord } from '../../model/Models';
import { TranscriptLines } from '../../util/TranscriptLines';
import { Log } from '../../util/Logger';
import { PcmReader } from '../PcmReader';
import { SenseVoiceText } from './SenseVoiceText';

/**
 * **Worker 子线程**里的离线识别循环。
 *
 * 为什么必须是子线程:sherpa 的 `decode()` 是**同步阻塞**的 native 调用 ——
 * 一块 26 秒的音频在真机上要跑两三秒,放在 UI 线程上界面就冻住两三秒,
 * 而整集有上百块。ArkTS 又没有协程,`await` 只让出"等待",不让出 CPU。
 * 这与把 RSS 解析搬进 TaskPool(见 net/FeedTask)是同一条账。
 *
 * 为什么用 Worker 而不是 TaskPool:
 *  - **模型只加载一次**。recognizer 建起来要读 228 MB 模型,几秒级;TaskPool 的任务
 *    是一次性的,每块都重建等于每块都等一次模型加载;
 *  - **取消是即刻的**。`terminate()` 能把整条 native 循环连同线程一起停掉;
 *  - 两条路径都必须把 native 句柄留在同一个线程里,Worker 的"一条长驻线程"天然满足。
 *
 * 与宿主的消息协议(见 `SenseVoiceTranscriber`):
 *   宿主 → 此: { cmd:'start', jobId, audio, model, tokens, lang }
 *             { cmd:'cancel', jobId }
 *   此 → 宿主: { cmd:'segment', jobId, seg }  一条定稿的行
 *             { cmd:'done', jobId, ok }       整集结束(ok=false 表示取消/无产出/出错)
 *             { cmd:'error', jobId, message } 建引擎或读音频失败
 *
 * 参数里**只放路径与数字**,不放 ctx / 对象:跨线程消息要可序列化(与 FeedTask 同式)。
 */

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

const port: ThreadWorkerGlobalScope = worker.workerPort;
const TAG: string = 'SenseVoice';

/// 模型按语言建一次,之后同语言的任务复用(见文件头)
let recognizer: OfflineRecognizer | null = null;
let recognizerLang: string = '';
/// 正在跑的任务号;-1 = 空闲
let running: number = -1;
/// 被要求取消的任务号:-1 = 没有
let canceled: number = -1;
/// 排队等上一个取消/结束的 start 命令(宿主先 cancel 再 start,两条消息可能同时到)
const pending: AsrCommand[] = [];

port.onmessage = (e: MessageEvents): void => {
  const msg = e.data as AsrCommand;
  if (msg.cmd === 'cancel') {
    canceled = msg.jobId;
    return;
  }
  if (msg.cmd !== 'start') return;
  pending.push(msg);
  pump();
};

/**
 * 串行执行排队的任务。
 *
 * 为什么排而不是并行:recognizer 是共享的,而 `decode()` 虽然阻塞,两次调用之间
 * JS 仍是交错的 —— 并行跑两个任务只会让两块音频抢同一份 encoder 资源、日志也分不清。
 * 宿主侧本来就是"先取消旧的、再起新的",所以这里的等待通常只有一块音频的时间。
 */
async function pump(): Promise<void> {
  if (running >= 0) return;
  while (pending.length > 0) {
    const msg = pending.shift() as AsrCommand;
    running = msg.jobId;
    try {
      await runJob(msg);
    } catch (err) {
      Log.e(TAG, `任务 ${msg.jobId} 失败:${(err as Error).message}`);
      post(msg.jobId, 'done', false, '', null);
    }
    running = -1;
  }
}

async function runJob(msg: AsrCommand): Promise<void> {
  const t0 = Date.now();
  const rec = ensureRecognizer(msg);
  if (rec === null) {
    post(msg.jobId, 'error', false, '模型加载失败', null);
    return;
  }
  const reader = PcmReader.open(msg.audio, SenseVoiceText.SAMPLE_RATE);
  if (reader === null) {
    post(msg.jobId, 'error', false, '打不开待转写音频', null);
    return;
  }

  let chunk = 0;
  let lastText = '';
  let emitted = 0;
  const chunkSamples = SenseVoiceText.CHUNK_SEC * SenseVoiceText.SAMPLE_RATE;
  try {
    Log.i(TAG, `开始转写 lang='${msg.lang}' audio=${msg.audio}`);
    while (true) {
      if (canceled === msg.jobId) break;
      const pcm = reader.read(chunkSamples);
      if (pcm === null || pcm.byteLength === 0) break;

      const startMs = Math.round(chunk * SenseVoiceText.CHUNK_SEC * 1000);
      // 末块通常不足一整块,时长按**实际样本数**算,不能按块长算 —— 否则末块的时间轴被拉长
      const endMs = startMs + Math.round(pcm.byteLength / 2 * 1000 / SenseVoiceText.SAMPLE_RATE);
      chunk += 1;

      const tChunk = Date.now();
      let text = '';
      let words: TranscribedWord[] = [];
      try {
        const samples = SenseVoiceText.pcm16ToFloat(pcm);
        const stream = rec.createStream();
        stream.acceptWaveform({ samples: samples, sampleRate: SenseVoiceText.SAMPLE_RATE });
        rec.decode(stream);
        const result: OfflineRecognizerResult = rec.getResult(stream);
        text = result.text.trim();
        words = SenseVoiceText.wordsFrom(result.tokens, result.timestamps, startMs, endMs);
      } catch (err) {
        // 单块失败不该让整集作废:块边界坏掉、某段纯噪声都可能让 native 侧抛异常。
        // 记下来,继续下一块 —— 少一句比整份稿没了强(与 Android 同一条)。
        Log.w(TAG, `块识别异常 startMs=${startMs}:${(err as Error).message}`);
      }
      Log.i(TAG, `块 startMs=${startMs} 样本=${pcm.byteLength / 2} 字=${text.length} 用时=${Date.now() - tChunk}ms`);

      if (SenseVoiceText.keep(text, lastText)) {
        lastText = text;
        // 用 token 时刻组行:行边界比按字数插值准,还顺带拿到逐字高亮要的词级时间。
        // **词级时间一律留下**(不像 Android 按开关裁剪):本端缓存只在本机用,
        // 多存一份 words 换来"事后打开逐字高亮不用重转一遍"。
        const lines: TranscribedSegment[] = words.length > 1
          ? TranscriptLines.mergeWords(words, false)
          : TranscriptLines.split(text, startMs, endMs);
        for (let i = 0; i < lines.length; i++) {
          post(msg.jobId, 'segment', true, '', lines[i]);
          emitted += 1;
        }
      }

      // 让出事件循环:否则 cancel 消息要等整集跑完才被处理。native 的 decode 停不了,
      // 但块与块之间能停 —— 用户切集后最多多等一块音频。
      await yieldOnce();
    }
    const ok = emitted > 0 && canceled !== msg.jobId;
    Log.i(TAG, `转写结束 ok=${ok} 已出 ${emitted} 句 用时=${Date.now() - t0}ms`);
    post(msg.jobId, 'done', ok, '', null);
  } finally {
    reader.close();
  }
}

/**
 * 模型的语言是**建 recognizer 时定的**。同一份 App 里换界面语言之后,旧 recognizer
 * 会把英语音频当中文解,所以按语言缓存一份,变了就重建(与 Android `ensureRecognizer` 同一条)。
 *
 * 模型与词表是宿主拷到私有目录之后的**真实文件路径**(rawfile 在包内没有路径,
 * 228 MB 也不该让 native 再从压缩包里解一遍)。
 */
function ensureRecognizer(msg: AsrCommand): OfflineRecognizer | null {
  if (recognizer !== null && recognizerLang === msg.lang) return recognizer;
  recognizer = null;
  recognizerLang = '';
  try {
    const config = new OfflineRecognizerConfig();
    config.featConfig.sampleRate = SenseVoiceText.SAMPLE_RATE;
    config.featConfig.featureDim = 80;
    config.modelConfig.tokens = msg.tokens;
    config.modelConfig.senseVoice.model = msg.model;
    config.modelConfig.senseVoice.language = msg.lang;
    // 标点与文本正则化(数字、日期)。关掉的话输出是一串没有断句的汉字,组行只能按字数硬切。
    config.modelConfig.senseVoice.useItn = true;
    config.modelConfig.numThreads = SenseVoiceText.THREADS;
    config.modelConfig.provider = 'cpu';
    config.modelConfig.debug = false;
    config.decodingMethod = 'greedy_search';
    const t0 = Date.now();
    const created = new OfflineRecognizer(config);
    recognizer = created;
    recognizerLang = msg.lang;
    Log.i(TAG, `模型已加载 lang=${msg.lang} threads=${SenseVoiceText.THREADS} 用时=${Date.now() - t0}ms`);
    return created;
  } catch (err) {
    Log.e(TAG, `模型加载失败(是否漏跑 tools/build-asr.sh?):${(err as Error).message}`);
    return null;
  }
}

function post(jobId: number, cmd: string, ok: boolean, message: string, seg: TranscribedSegment | null): void {
  const msg: AsrMessage = { cmd: cmd, jobId: jobId, ok: ok, message: message, seg: seg };
  port.postMessage(msg);
}

function yieldOnce(): Promise<void> {
  return new Promise<void>((resolve) => { setTimeout(() => { resolve(); }, 0); });
}
