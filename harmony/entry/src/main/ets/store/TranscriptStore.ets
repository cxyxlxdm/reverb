import fs from '@ohos.file.fs';
import i18n from '@ohos.i18n';
import taskpool from '@ohos.taskpool';
import { Episode, TranscribedSegment, TranscribedWord } from '../model/Models';
import { TranscriptFetcher } from '../net/TranscriptFetcher';
import { fetchTranscriptConcurrent } from '../net/TranscriptFetchTask';
import { J } from '../net/Http';
import {
  loadTranscriptCacheConcurrent, saveTranscriptCacheConcurrent, TranscriptCacheOut
} from './TranscriptTask';
import { Log } from '../util/Logger';

/**
 * 转写的状态。与 Android `TranscriptStore.State` 对齐,少一个 `NoEngine` ——
 * 本端**有**系统语音识别(Core Speech Kit),不存在"这个版本没有识别能力"这种情况;
 * 但多一个 `Unsupported`:系统的识别服务在某些机型/系统版本上可能不可用,那时要如实说。
 */
export enum TranscriptState {
  Idle = 0,
  /// 正在取发布方的官方稿
  FetchingOfficial = 1,
  /// 流式单集:先把音频下载到临时文件(识别要喂本地文件解出来的 PCM)
  DownloadingAudio = 2,
  /// 正在识别
  Running = 3,
  Done = 4,
  Failed = 5,
  /// 这台设备上没有可用的系统语音识别,且这一集也没有官方稿
  Unsupported = 6,
  /**
   * 正在读本机缓存。
   *
   * 为什么要有这么一个短命状态:读缓存搬到子线程之后不再是"同一帧内出结果",
   * 中间那几十毫秒如果沿用 `Idle`,界面会**闪一下「开始转写」按钮**再跳到全文。
   * 与 `FetchingOfficial` 分开是因为这一步没有联网,文案不能说"正在取官方稿"。
   */
  LoadingCache = 7
}

/**
 * 一次转写的产出接收口。由 `SpeechTranscriber` 回调进来,`TranscriptStore` 负责落到状态与缓存。
 * 抽成接口是为了让识别实现不认识 store,也便于将来换成三方引擎(见 TRANSCRIPT.md 的迁移路径)。
 */
export interface TranscriptSink {
  onSegment(seg: TranscribedSegment): void;
  /// 尚未定稿的实时尾巴(打字机效果),下一句定稿时会被清掉
  onVolatile(text: string): void;
}

/**
 * 「逐字稿」的状态机与缓存。对应 Android `data/local/TranscriptStore.kt`、
 * macOS `Data/TranscriptStore.swift`,**缓存 JSON 格式三端完全一致**。
 *
 * 两条取稿路径,**先官方稿、后系统识别**:
 * 1. 发布方自己给的逐字稿(RSS `podcast:transcript`)—— 准、快、不耗电,还可能带词级时间;
 * 2. 系统离线语音识别(Core Speech Kit)—— 音频不出设备,但只有文本、**没有任何时间戳**,
 *    时间轴要自己按"已喂进去多少音频"推算(见 `playback/SpeechTranscriber`)。
 *
 * 缓存:每单集 × 每语言一份 JSON,放 `filesDir/transcripts/`。命中即秒显,不重转。
 * 不进备份(`BackupManager` 没有它):可重生成、体积大,与另两端一致。
 */
@Observed
export class TranscriptStore implements TranscriptSink {

  /**
   * 缓存格式/时间轴口径的版本。**改了时刻的算法就要 +1**,否则用户设备上已经生成的稿
   * 会继续按旧口径显示,修复等于没生效(Android 端踩过,见 TROUBLESHOOTING H60)。
   *
   * 与 Android `TranscriptStore.CACHE_VERSION` **同一个数**:缓存格式三端互通,
   * 版本号也就必须共用一套编号。
   *   - v1:Android 用 whisper DTW 的时代(本端没有 v1 的稿);
   *   - v2:当前。
   */
  static readonly CACHE_VERSION: number = 2;

  private static readonly DIR: string = 'transcripts';
  private static readonly TAG: string = 'Transcript';

  /// 界面直接观察这三个
  state: TranscriptState = TranscriptState.Idle;
  segments: TranscribedSegment[] = [];
  volatileTail: string = '';

  private filesDir: string = '';
  private episodeId: string = '';
  private localeId: string = '';

  /**
   * 代次。切集/切语言/重新开始都自增,旧任务发现代次变了就悄悄退出 ——
   * 光靠"取消"不够:识别是异步回调,回调可能已经在路上,
   * 不带代次判断就会把上一集的句子写进这一集。
   */
  private generation: number = 0;
  private running: boolean = false;

  /// 实际干识别活的那位。由 AppContainer 注入,store 不认识它的实现细节。
  transcriber: SpeechTranscriberLike | null = null;

  init(filesDir: string): void {
    this.filesDir = filesDir;
    try {
      const d = `${filesDir}/${TranscriptStore.DIR}`;
      if (!fs.accessSync(d)) fs.mkdirSync(d);
    } catch (e) {
      Log.w(TranscriptStore.TAG, `建缓存目录失败:${e}`);
    }
  }

  // ── 对外 ──

  /**
   * 切到某单集/语言时调用。命中缓存直接显示;否则置初始态**等用户手动开始** ——
   * 不自动转写:那是几分钟的满载计算,得由用户点了才做。
   */
  async prepare(episode: Episode, uiLanguage: string): Promise<void> {
    const loc = TranscriptStore.localeFor(uiLanguage);
    if (episode.id === this.episodeId && loc === this.localeId && this.state !== TranscriptState.Idle) return;
    this.cancel();
    this.generation += 1;
    const gen = this.generation;
    this.episodeId = episode.id;
    this.localeId = loc;
    this.volatileTail = '';
    this.segments = [];

    // 读缓存在子线程里,期间用 LoadingCache 占位(否则会闪一下"开始转写")
    this.state = TranscriptState.LoadingCache;
    const cached = await this.loadCacheAsync(episode.id, loc);
    // 读的过程中用户可能已经切集/切语言 —— 那时这份结果作废
    if (gen !== this.generation) return;
    if (cached.length > 0) {
      this.segments = cached;
      this.state = TranscriptState.Done;
      return;
    }
    // 有官方稿就一定能出东西;没有则要看这台设备的系统识别在不在
    const canRecognize = this.transcriber !== null && this.transcriber.available();
    this.state = (episode.transcriptUrl.length > 0 || canRecognize)
      ? TranscriptState.Idle
      : TranscriptState.Unsupported;
  }

  /**
   * 开始取稿/转写。`localPath` 非空表示这一集已下载(纯离线);否则识别前要先下音频。
   */
  async start(episode: Episode, uiLanguage: string, localPath: string): Promise<void> {
    const loc = TranscriptStore.localeFor(uiLanguage);
    /**
     * **同一集正在转就别再起一遍。** Android 端实测一次点击会跑两遍(页面重组时那次点击的
     * 回调有机会再跑),不挡住就是两倍的满载计算、手机烫电掉快,而结果一模一样。
     * 失败后的「重试」不受影响:那时 running 已经是 false。
     */
    if (this.running && episode.id === this.episodeId && loc === this.localeId) {
      Log.i(TranscriptStore.TAG, `已在转写中,忽略重复的开始请求 id=${episode.id}`);
      return;
    }
    this.cancel();
    this.generation += 1;
    const gen = this.generation;
    this.episodeId = episode.id;
    this.localeId = loc;
    this.segments = [];
    this.volatileTail = '';
    this.running = true;
    try {
      await this.run(gen, episode, loc, localPath);
    } finally {
      if (gen === this.generation) this.running = false;
    }
  }

  cancel(): void {
    this.generation += 1;      // 让在途回调失效
    this.running = false;
    const t = this.transcriber;
    if (t !== null) t.cancel();
  }

  // ── 执行 ──

  private async run(gen: number, episode: Episode, loc: string, localPath: string): Promise<void> {
    // 1) 官方稿优先
    if (episode.transcriptUrl.length > 0) {
      this.state = TranscriptState.FetchingOfficial;
      const segs = await this.fetchOfficial(episode.transcriptUrl, episode.transcriptType);
      if (gen !== this.generation) return;
      if (segs.length > 0) {
        this.segments = segs;
        this.state = TranscriptState.Done;
        await this.saveCacheAsync(episode.id, loc, segs);
        Log.i(TranscriptStore.TAG, `用官方稿 ${segs.length} 句 id=${episode.id}`);
        return;
      }
      // 取不到就往下走系统识别 —— 「稿链接坏了」不该让功能整个不可用
      Log.w(TranscriptStore.TAG, `官方稿取不到,回退系统识别 id=${episode.id}`);
    }

    // 2) 本机识别(没装配识别器时这条路不存在,见 Features.LOCAL_ASR)
    const t = this.transcriber;
    if (t === null || !t.available()) {
      if (gen === this.generation) {
        /**
         * 这里要分清两种情况,否则文案会骗人:
         * - **有稿但取失败**(网络问题、链接坏了)⇒ `Failed`,界面给「重试」;
         * - 压根没有稿 ⇒ `Unsupported`,界面说"发布方未提供"。
         * 只走官方稿的版本里,前一种才是常见情形 —— 早先一律置 Unsupported,
         * 于是"下载失败"被说成"发布方没提供",用户还以为这集永远没有稿。
         */
        this.state = episode.transcriptUrl.length > 0
          ? TranscriptState.Failed
          : TranscriptState.Unsupported;
      }
      return;
    }
    const ok = await t.transcribe(episode, localPath, loc, this, (s: TranscriptState) => {
      if (gen === this.generation) this.state = s;
    }, () => gen !== this.generation);
    if (gen !== this.generation) return;
    this.volatileTail = '';
    if (this.segments.length === 0) {
      this.state = TranscriptState.Failed;
    } else {
      this.state = ok ? TranscriptState.Done : TranscriptState.Failed;
      // 半截的稿也存 —— 但标 complete=false,下次不会当成完整稿显示(与另两端一致)
      await this.saveCacheAsync(episode.id, loc, this.segments, ok);
    }
  }

  /// 取官方稿:走子线程(解析上万条词级条目),失败回落本线程。
  private async fetchOfficial(url: string, declaredType: string): Promise<TranscribedSegment[]> {
    try {
      const out: Object = await taskpool.execute(fetchTranscriptConcurrent, url, declaredType);
      return out === null || out === undefined ? [] : out as TranscribedSegment[];
    } catch (e) {
      Log.w(TranscriptStore.TAG, `子线程取官方稿失败,回落本线程:${(e as Error).message}`);
      return TranscriptFetcher.fetch(url, declaredType);
    }
  }

  // ── TranscriptSink ──

  onSegment(seg: TranscribedSegment): void {
    this.segments = this.segments.concat([seg]);
    this.volatileTail = '';
    if (this.state !== TranscriptState.Running) this.state = TranscriptState.Running;
  }

  onVolatile(text: string): void {
    this.volatileTail = text;
  }

  // ── 缓存 ──

  private cacheName(episodeId: string, loc: string): string {
    return `${TranscriptStore.DIR}/${TranscriptStore.sanitize(episodeId)}.${loc.length === 0 ? 'auto' : loc}.json`;
  }

  /**
   * 读缓存:**走子线程**(见 `TranscriptTask`)。这是本应用最大的一份 JSON,
   * 上千句 + 上万条词级条目,解析放在 UI 线程上会让打开逐字稿页顿一下。
   * 子线程不可用时回落本线程(宁可顿一下,不能读不出稿)。
   */
  private async loadCacheAsync(episodeId: string, loc: string): Promise<TranscribedSegment[]> {
    if (this.filesDir.length === 0) return [];
    const p = `${this.filesDir}/${this.cacheName(episodeId, loc)}`;
    try {
      const out: Object = await taskpool.execute(
        loadTranscriptCacheConcurrent, p, TranscriptStore.CACHE_VERSION);
      const r = out as TranscriptCacheOut;
      if (r.stale) Log.i(TranscriptStore.TAG, '缓存是旧口径,已丢弃,需重转');
      return r.segments;
    } catch (e) {
      Log.w(TranscriptStore.TAG, `子线程读缓存失败,回落本线程:${(e as Error).message}`);
      return this.loadCache(episodeId, loc);
    }
  }

  /// 只认 `complete = true` 且**时间轴口径没变**的缓存。(本线程版:子线程不可用时的回落)
  private loadCache(episodeId: string, loc: string): TranscribedSegment[] {
    if (this.filesDir.length === 0) return [];
    const p = `${this.filesDir}/${this.cacheName(episodeId, loc)}`;
    try {
      if (!fs.accessSync(p)) return [];
      const root = JSON.parse(fs.readTextSync(p)) as Record<string, Object>;
      if (J.num(root, 'complete') === 0 && root['complete'] !== true) return [];
      // 缺 version 字段的是更早的口径,一律作废重转
      const ver = J.num(root, 'version');
      if (ver < TranscriptStore.CACHE_VERSION) {
        Log.i(TranscriptStore.TAG, `缓存是旧口径(v${ver}),丢弃重转`);
        try { fs.unlinkSync(p); } catch (e) { /* 删不掉也无妨,下次照样不认 */ }
        return [];
      }
      const arr = J.arr(root, 'segments');
      const out: TranscribedSegment[] = [];
      for (let i = 0; i < arr.length; i++) {
        const o = J.asObj(arr[i]);
        if (o === null) continue;
        const wordsRaw = J.arr(o, 'words');
        const words: TranscribedWord[] = [];
        for (let k = 0; k < wordsRaw.length; k++) {
          const w = J.asObj(wordsRaw[k]);
          if (w === null) continue;
          words.push({
            text: J.str(w, 'text'),
            startMs: J.num(w, 'startMs'),
            endMs: J.num(w, 'endMs')
          } as TranscribedWord);
        }
        out.push({
          text: J.str(o, 'text'),
          startMs: J.num(o, 'startMs'),
          endMs: J.num(o, 'endMs'),
          words: words
        } as TranscribedSegment);
      }
      return out;
    } catch (e) {
      Log.w(TranscriptStore.TAG, `缓存读坏了,当作没有:${e}`);
      return [];
    }
  }

  /**
   * 写缓存:同样走子线程 —— 一万多条词级条目的 `JSON.stringify` 不该占 UI 线程。
   * 失败(含子线程不可用)时回落本线程写:缓存写不成只是下次要重转,但不能因此丢稿。
   */
  private async saveCacheAsync(episodeId: string, loc: string, segs: TranscribedSegment[],
    complete: boolean = true): Promise<void> {
    if (this.filesDir.length === 0) return;
    const p = `${this.filesDir}/${this.cacheName(episodeId, loc)}`;
    try {
      const ok: Object = await taskpool.execute(saveTranscriptCacheConcurrent,
        p, loc, complete, TranscriptStore.CACHE_VERSION, segs);
      if (ok as boolean) return;
    } catch (e) {
      Log.w(TranscriptStore.TAG, `子线程写缓存失败,回落本线程:${(e as Error).message}`);
    }
    this.saveCache(episodeId, loc, segs, complete);
  }

  /// 本线程版(子线程不可用时的回落)。
  private saveCache(episodeId: string, loc: string, segs: TranscribedSegment[], complete: boolean = true): void {
    if (this.filesDir.length === 0) return;
    const arr: Object[] = [];
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      const o: Record<string, Object> = {
        'text': s.text, 'startMs': s.startMs, 'endMs': s.endMs
      };
      if (s.words.length > 0) {
        const wa: Object[] = [];
        for (let k = 0; k < s.words.length; k++) {
          const w = s.words[k];
          wa.push({ 'text': w.text, 'startMs': w.startMs, 'endMs': w.endMs } as Record<string, Object>);
        }
        o['words'] = wa;
      }
      arr.push(o);
    }
    const root: Record<string, Object> = {
      'localeId': loc,
      'complete': complete,
      'version': TranscriptStore.CACHE_VERSION,
      'segments': arr
    };
    const p = `${this.filesDir}/${this.cacheName(episodeId, loc)}`;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(root));
    } catch (e) {
      Log.w(TranscriptStore.TAG, `缓存写失败:${e}`);
    } finally {
      if (file !== null) {
        try { fs.closeSync(file); } catch (e) { /* 忽略 */ }
      }
    }
  }

  /// 设置页「清除缓存」会调。
  clearAll(): void {
    if (this.filesDir.length === 0) return;
    const d = `${this.filesDir}/${TranscriptStore.DIR}`;
    try {
      const names = fs.listFileSync(d);
      for (let i = 0; i < names.length; i++) {
        try { fs.unlinkSync(`${d}/${names[i]}`); } catch (e) { /* 忽略单个失败 */ }
      }
    } catch (e) {
      // 目录不存在等
    }
    this.segments = [];
    this.state = TranscriptState.Idle;
    this.episodeId = '';
  }

  /// 逐字稿目录占用。**异步**:一集一个文件,`listFileSync` + 逐文件 `statSync`
  /// 是 O(N) 同步 IO,原先摊在设置页首帧上(见 H65)。
  async usageBytes(): Promise<number> {
    if (this.filesDir.length === 0) return 0;
    const d = `${this.filesDir}/${TranscriptStore.DIR}`;
    let sum = 0;
    try {
      const names = await fs.listFile(d);
      for (let i = 0; i < names.length; i++) {
        try {
          const st = await fs.stat(`${d}/${names[i]}`);
          sum += st.size;
        } catch (e) { /* 忽略单个失败 */ }
      }
    } catch (e) {
      // 目录不存在
    }
    return sum;
  }

  // ── 静态工具 ──

  /**
   * 界面语言 → 识别/取稿语言。与 Android `localeFor` / macOS `locale(for:)` 同一张表。
   *
   * 「跟随系统」**要解析成真实语言,不能留空**:留空等于让识别引擎自己猜,而且缓存 key
   * 会退化成 "auto",换了系统语言还命中同一份旧稿。
   */
  static localeFor(uiLanguage: string): string {
    if (uiLanguage === 'zh-Hans' || uiLanguage === 'zh-CN') return 'zh-CN';
    if (uiLanguage === 'zh-Hant' || uiLanguage === 'zh-TW') return 'zh-TW';
    if (uiLanguage === 'en') return 'en-US';
    if (uiLanguage === 'fr') return 'fr-FR';
    if (uiLanguage === 'es') return 'es-ES';
    return TranscriptStore.systemLocaleId();
  }

  /// 设备语言 → 与上面同一套写法。中文按地区分简繁(CN/SG 为简,TW/HK/MO 为繁)。
  private static systemLocaleId(): string {
    let tag = 'zh-CN';
    try {
      // `getSystemLocale()` 已弃用,官方替代是返回 `Intl.Locale` 的这个
      tag = i18n.System.getSystemLocaleInstance().toString();
    } catch (e) {
      return 'zh-CN';
    }
    const lower = tag.toLowerCase();
    if (lower.startsWith('zh')) {
      if (lower.indexOf('tw') >= 0 || lower.indexOf('hk') >= 0 || lower.indexOf('mo') >= 0
          || lower.indexOf('hant') >= 0) {
        return 'zh-TW';
      }
      return 'zh-CN';
    }
    const parts = tag.split('-');
    const lang = parts[0].toLowerCase();
    // 只保留 语言-地区 两段(系统可能给出 en-Latn-US 这种带文字的三段)
    if (parts.length >= 2) {
      const last = parts[parts.length - 1];
      if (last.length === 2) return `${lang}-${last.toUpperCase()}`;
    }
    return lang;
  }

  /// 文件名安全化。与另两端同口径:非字母数字换 `_`,截断 120。
  private static sanitize(s: string): string {
    let out = '';
    const n = Math.min(s.length, 120);
    for (let i = 0; i < n; i++) {
      const c = s.charCodeAt(i);
      const ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
      out += ok ? s.charAt(i) : '_';
    }
    return out;
  }
}

/**
 * `TranscriptStore` 对识别实现的最小要求。放在这里而不是引 `SpeechTranscriber` ——
 * store 不该认识具体引擎,将来换三方实现只要满足这个形状(见 TRANSCRIPT.md 的迁移路径)。
 */
export interface SpeechTranscriberLike {
  /// 这台设备上系统识别能不能用
  available(): boolean;
  cancel(): void;
  transcribe(
    episode: Episode,
    localPath: string,
    localeId: string,
    sink: TranscriptSink,
    onState: (s: TranscriptState) => void,
    stale: () => boolean
  ): Promise<boolean>;
}
