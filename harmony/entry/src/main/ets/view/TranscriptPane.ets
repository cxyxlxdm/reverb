import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { PlayerController } from '../playback/PlayerController';
import { TranscriptStore, TranscriptState } from '../store/TranscriptStore';
import { TranscribedSegment, TranscribedWord } from '../model/Models';
import { TranscriptSearch, SearchResult, SearchRange } from '../util/TranscriptSearch';
import { TranscriptExport, TranscriptFormat } from '../util/TranscriptExport';
import { Files } from '../util/Files';
import { Log } from '../util/Logger';
import common from '@ohos.app.ability.common';
import { Glyph, Sym } from './Widgets';

/**
 * 一段要画的文字。`hit` = 落在搜索命中的区间里(贴底色);
 * `spoken` = 落在"正在读的那个词"里(强调色 + 半粗)。两者可以同时为 true ——
 * 底色与逐字高亮是两个维度,搜索时不该把跟读位置抹掉。
 */
class TextSlice {
  text: string;
  hit: boolean;
  spoken: boolean;

  constructor(text: string, hit: boolean, spoken: boolean) {
    this.text = text;
    this.hit = hit;
    this.spoken = spoken;
  }
}

/**
 * 段落 = 连续 3 句(≈3 行),段与段之间空出 `PARA_GAP_VP`,段内行距只有 `LINE_GAP_VP`。
 *
 * **为什么段落是"排"出来的,不是"量"出来的**:本机识别出的句子之间**没有停顿可测** ——
 * 2026-11-13 拿一集 1.5 小时的稿子量过,1753 个间隔里中位数 0ms、最大 840ms,
 * ≥500ms 的只有 5 个;按停顿分段等于整篇一段。所以段落只能是一条**确定的排版规则**,
 * 三端必须用同一个数,否则同一份稿子在两端的段落位置不一样。
 *
 * 3 行是"一眼看得出是段"与"段不至于太碎"的折中:1.5 小时 / 1753 句 ≈ 585 段,
 * 每段 3 行、行高 24vp ⇒ 一段约 72vp,段间留 16vp 时行距与段距的比例是 1.6 倍。
 */
const PARA_LINES: number = 3;
/** 段内行距。与 `List({ space })` 同一个数,别只改一边。 */
const LINE_GAP_VP: number = 4;
/** 段间**额外**留白;与段内行距相加才是段距。 */
const PARA_GAP_VP: number = 16;


/**
 * 播放页第三页:逐字稿。对应 Android `ui/screens/TranscriptPane.kt`、macOS `UI/TranscriptPage.swift`。
 *
 * 两种来源在界面上**不作区分** —— 用户要的是"这一集的文字",不关心是发布方给的还是本机转的。
 * 差别只体现在等待时长上(官方稿一两秒,系统识别几分钟)。
 */
@Component
export struct TranscriptPane {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink store: TranscriptStore;
  @ObjectLink player: PlayerController;
  /**
   * 这一页是否真的滑到眼前;以及是否在播放。外推与自动滚动**只在"可见且在播"时跑** ——
   * 看不见的页上逐帧算纯属白烧电,暂停时位置压根不变。
   *
   * 用 `@Watch` 而不是在 `build()` 里判断:在 build 里改状态会触发再一次重渲(本仓库
   * 踩过,见 PlayerPage.noteText 的注释)。`playing` 单独作 `@Prop` 传进来,是因为
   * `@ObjectLink` 的嵌套属性变化没法直接 watch。
   */
  @Prop @Watch('onGate') active: boolean;
  @Prop @Watch('onGate') playing: boolean;
  @Prop wordHighlight: boolean;
  /**
   * 换集/换语言时要让 store 重新判断:命中缓存就秒显,否则回到"等用户点生成"。
   * 同样用 `@Watch` 而不是在 build 里比对 —— build 里改状态会再触发一次重渲。
   */
  @Prop @Watch('onEpisode') episodeId: string;
  @Prop @Watch('onEpisode') uiLanguage: string;
  onStart: () => void = () => {};

  /**
   * 外推出来的"现在播到哪儿了",毫秒。
   *
   * 为什么不直接用 `player.positionMs`:那个值来自 AVPlayer 的 `timeUpdate`,
   * **约 100ms 一档且间隔不匀**,直接拿它找当前句会让高亮一跳一跳
   * (短句只有一两秒,采样误差就占了一半),逐字高亮更是完全看不出跟读感。
   * 这里记住"上一次采样值 + 采样时刻",两次采样之间按真实流逝时间往前推 ——
   * 与 Android `rememberExtrapolatedPosition`、macOS 的 anchorMs/anchorAt 同一手法。
   *
   * 另外注意:进度**不会**推动本组件重渲(它存在非观察的 `PlaybackClock` 里,见 H64),
   * 所以下面那个 80ms 心跳不是"锦上添花",而是这一页唯一的刷新来源。
   */
  @State nowMs: number = 0;

  // ---- 搜索与导出(与 Android `TranscriptPane` / Apple `TranscriptPage` 同一套行为) ----

  /// 搜索条是否展开
  @State searchOpen: boolean = false;
  /// 原始输入;`trim` 之后的空串不触发匹配,免得整篇被涂亮
  @State query: string = '';
  /// 当前停在第几处命中(0 基)
  @State cursor: number = 0;
  @State result: SearchResult = new SearchResult();
  /**
   * 每个命中句的切片结果,**在搜索状态变化时算一次**。
   *
   * 不在渲染路径里切:当前句每 80ms 重渲一次,若每次都拿整句去切命中区间,
   * 长稿 + 多命中会退化成"每档 × 每行 × 每区间"(硬规矩 6 那条乘法)。
   */
  @State slicesByIndex: Map<number, TextSlice[]> = new Map<number, TextSlice[]>();
  @State exporting: boolean = false;
  /// 上次计算命中时稿子的句数:流式识别会一直追加,句数变了得重算一次
  private searchedCount: number = -1;

  /// 用户手指碰过列表的时刻:碰过就先别自动滚,免得往上翻看前文时被一次次拽回来
  @State private touchedAt: number = 0;

  private timer: number = -1;
  private anchorMs: number = 0;
  private anchorAt: number = 0;
  private scroller: Scroller = new Scroller();
  /// 上次自动滚到的行,避免同一行反复下滚动指令
  private scrolledTo: number = -1;

  aboutToAppear(): void {
    this.resync();
    this.onEpisode();
    this.onGate();
  }

  private onEpisode(): void {
    const e = this.player.current;
    if (e === null) return;
    this.scrolledTo = -1;
    this.closeSearch();
    this.store.prepare(e, this.uiLanguage);
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  /**
   * 外推的心跳。**只在这一页可见且在播放时**才跑。
   *
   * 80ms 一档:逐字高亮要跟上说话的节奏(一个字两三百毫秒),再慢就看得出滞后;
   * 再快也没意义,屏幕刷新与人眼都分辨不出。
   */
  private onGate(): void {
    const want = this.active && this.playing;
    if (want && this.timer < 0) {
      this.timer = setInterval(() => {
        // 采样值一变就重新对锚 —— 否则拖动进度条/自动续播之后外推会一直偏
        if (this.player.positionMs !== this.anchorMs) this.resync();
        this.nowMs = this.anchorMs + (Date.now() - this.anchorAt);
        this.autoScroll();
        // 流式识别会一直追加句子:句数变了就重算一次命中(不滚屏,理由见 recompute)
        if (this.searchOpen && this.store.segments.length !== this.searchedCount) this.recompute(false);
      }, 80);
    } else if (!want && this.timer >= 0) {
      this.stopTimer();
      this.resync();
      // 暂停时也把当前句滚进视线一次:用户可能是拖了进度条才停下来看文字的
      this.autoScroll();
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private resync(): void {
    this.anchorMs = this.player.positionMs;
    this.anchorAt = Date.now();
    this.nowMs = this.anchorMs;
  }

  // MARK: - 搜索

  /**
   * 重算命中。`query` 或稿子变了才调 —— 不在 80ms 渲染心跳里做。
   *
   * @param scrollToFirst 输入关键词时把第一处滚进视线;流式追加引起的重算则为 false,
   *                      否则每出一句都会把用户从正在看的位置拽走。
   */
  private recompute(scrollToFirst: boolean): void {
    const q = this.query.trim();
    const r = TranscriptSearch.find(this.store.segments, q);
    const slices = new Map<number, TextSlice[]>();
    for (const hit of r.hits) {
      const seg = this.store.segments[hit.index];
      if (seg !== undefined) slices.set(hit.index, this.slicesFrom(seg.text, hit.ranges));
    }
    this.searchedCount = this.store.segments.length;
    this.result = r;
    this.slicesByIndex = slices;
    this.cursor = 0;
    if (scrollToFirst && r.hits.length > 0) this.scrollToLine(r.hits[0].index);
  }

  private closeSearch(): void {
    this.searchOpen = false;
    this.query = '';
    this.cursor = 0;
    this.result = new SearchResult();
    this.slicesByIndex = new Map<number, TextSlice[]>();
    this.searchedCount = -1;
  }

  /// 上一处(-1) / 下一处(+1),循环;点一下就跳到那句开头(与另两端一致)
  private step(delta: number): void {
    const hits = this.result.hits;
    if (hits.length === 0) return;
    this.cursor = ((this.cursor + delta) % hits.length + hits.length) % hits.length;
    const hit = hits[this.cursor];
    const segs = this.store.segments;
    if (hit.index < segs.length) this.player.seekTo(segs[hit.index].startMs);
    this.scrollToLine(hit.index);
  }

  private scrollToLine(index: number): void {
    try {
      this.scroller.scrollToIndex(Math.max(index - 2, 0), true);
    } catch (e) {
      // 列表还没布局好等情况,忽略
    }
  }

  /// 整句切成"命中/不命中"两种片段。命中区间由 `TranscriptSearch` 保证升序且不重叠。
  private slicesFrom(text: string, ranges: SearchRange[]): TextSlice[] {
    const out: TextSlice[] = [];
    let at = 0;
    for (const r of ranges) {
      const start = Math.max(at, Math.min(r.start, text.length));
      const end = Math.max(start, Math.min(r.end, text.length));
      if (start > at) out.push(new TextSlice(text.substring(at, start), false, false));
      if (end > start) out.push(new TextSlice(text.substring(start, end), true, false));
      at = end;
    }
    if (at < text.length) out.push(new TextSlice(text.substring(at), false, false));
    return out;
  }

  /**
   * 当前句的切片:在**词边界**与**命中边界**上同时切。
   *
   * 只有当前句要这一层 —— 它既要贴搜索底色,又要保留"读到哪个词"的强调。
   * 每 80ms 只算这一行(几十个字符),不构成硬规矩 6 说的那条乘法;
   * 其余命中行用 `slicesByIndex` 的预算结果。
   */
  private piecesForCurrent(seg: TranscribedSegment, index: number): TextSlice[] {
    const ranges = this.result.rangesByIndex.get(index);
    const marks: SearchRange[] = ranges === undefined ? [] : ranges;
    const pieces: TextSlice[] = [];
    let offset = 0;
    let ri = 0;
    for (let k = 0; k < seg.words.length; k++) {
      const w = seg.words[k];
      const spoken = this.isSpokenWord(seg, k);
      let left = w.text;
      let local = 0;
      while (left.length > 0) {
        const abs = offset + local;
        while (ri < marks.length && marks[ri].end <= abs) ri++;
        if (ri >= marks.length) {
          pieces.push(new TextSlice(left, false, spoken));
          break;
        }
        const r = marks[ri];
        const take = r.start > abs
          ? Math.min(r.start - abs, left.length)
          : Math.min(r.end - abs, left.length);
        if (take <= 0) {
          ri++;
          continue;
        }
        pieces.push(new TextSlice(left.substring(0, take), r.start <= abs, spoken));
        left = left.substring(take);
        local += take;
      }
      offset += w.text.length;
    }
    return pieces;
  }

  private hasMarks(index: number): boolean {
    return this.result.rangesByIndex.has(index);
  }

  private slicesOf(index: number): TextSlice[] {
    const s = this.slicesByIndex.get(index);
    return s === undefined ? [] : s;
  }

  // MARK: - 导出

  private async exportAs(format: TranscriptFormat): Promise<void> {
    if (this.exporting) return;
    const e = this.player.current;
    if (e === null || this.store.segments.length === 0) return;
    this.exporting = true;
    try {
      const ui = this.getUIContext();
      const ctx = ui.getHostContext() as common.UIAbilityContext;
      const text = TranscriptExport.build(e, this.store.segments, format);
      const name = TranscriptExport.fileName(e, format);
      // `title` 传**集名**而不是「导出逐字稿」:ShareKit 拿它当分享卡与「另存为」的默认文件名
      // (真机实测:传按钮文案时,存下来的文件就叫「导出逐字稿.txt」),而 Android 那边
      // `EXTRA_SUBJECT` 与落盘文件名都是集名 —— 两端同一个文件不该有两个名字(见 H263)。
      if (!await Files.shareText(ctx, e.title, name, text, '')) {
        this.showToast(L.s('share_failed'));
      }
    } catch (err) {
      Log.e('Transcript', `导出失败 ${(err as Error).message}`);
      this.showToast(L.s('share_failed'));
    } finally {
      this.exporting = false;
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      Log.w('Transcript', `提示失败 ${(e as Error).message}`);
    }
  }

  /**
   * 当前是第几句:**从后往前**找第一个起点已过去的。
   *
   * 这个写法只在**句子起点单调不减**时才正确 —— 队尾混进一个异常小的值就会永远命中它,
   * 高亮钉死不动。官方稿由 `TranscriptLines.monotonic` 保证,系统识别那条按喂入量递推,
   * 天然单调(见 `SpeechTranscriber`)。
   *
   * **只有 `autoScroll` 用它** —— 滚动要的是"第几行"这个下标(`scrollToIndex` 的入参),
   * 每档一次整表扫描是必要成本。渲染侧不在这儿拿下标,而是逐行问 `isCurrentLine`,
   * 原因见那里的注释(H137)。
   */
  private currentIndex(): number {
    const segs = this.store.segments;
    for (let i = segs.length - 1; i >= 0; i--) {
      if (segs[i].startMs <= this.nowMs) return i;
    }
    return -1;
  }

  build() {
    Column() {
      if (this.store.segments.length > 0) {
        this.headBar()
      }
      if (this.store.state === TranscriptState.Done || this.store.state === TranscriptState.Running) {
        // 已经有句子就显示列表(识别中也边出边看)。**还没有第一句时要给进度** ——
        // 否则这里渲染的是一个空列表,用户看见一整片空白,不知道是在算还是坏了
        if (this.store.segments.length === 0 && this.store.volatileTail.length === 0) {
          this.progress(L.s('transcript_running'))
        } else {
          this.lines()
        }
      } else if (this.store.state === TranscriptState.Idle) {
        // 有官方稿与没有官方稿,**要说不同的话**:前者只是下载一个文件(一两秒),
        // 后者是本机满载算几分钟。都写成"离线转成文字"是不诚实的
        this.hint(
          this.hasOfficial() ? L.s('transcript_prompt_official') : L.s('transcript_prompt'),
          this.hasOfficial() ? L.s('transcript_show') : L.s('transcript_start'),
          false
        )
      } else if (this.store.state === TranscriptState.LoadingCache) {
        // 读本机缓存(在子线程里,通常几十毫秒)。用通用的「加载中」而不是「正在取官方稿」——
        // 这一步不联网,说取稿是不实的。有这个分支是为了不闪出「开始转写」按钮
        this.progress(L.s('loading'))
      } else if (this.store.state === TranscriptState.FetchingOfficial) {
        this.progress(L.s('transcript_fetching'))
      } else if (this.store.state === TranscriptState.DownloadingAudio) {
        this.progress(L.s('transcript_preparing_audio'))
      } else if (this.store.state === TranscriptState.Failed) {
        this.hint(L.s('transcript_failed'), L.s('action_retry'), true)
      } else if (this.store.state === TranscriptState.UnsupportedLocale) {
        // 引擎在,但不认这种语言(法语 / 西语界面),这一集也没有官方稿 —— 如实说,
        // 不摆一个点了必然失败的重试按钮(与 Android 同一句)
        this.hint(L.s('transcript_lang_unsupported'), '', false)
      } else {
        // Unsupported:这台设备没有可用的系统识别,这一集也没有官方稿 —— 如实说,不给没用的按钮
        this.hint(L.s('transcript_none'), '', false)
      }
    }
    .width('100%')
    .height('100%')
  }

  private hasOfficial(): boolean {
    const e = this.player.current;
    return e !== null && e.transcriptUrl.length > 0;
  }

  /// 顶部工具条:搜索中是一条输入框,平时是「搜索 + 导出」两个图标。
  /// 文案与 Android / Apple 同一组键(硬规矩 5)。
  @Builder
  headBar() {
    if (this.searchOpen) {
      Row({ space: 8 }) {
        TextInput({ text: this.query, placeholder: L.s('transcript_search') })
          .layoutWeight(1)
          .height(36)
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurface)
          .placeholderColor(withAlpha(this.scheme.onSurfaceVariant, 0.6))
          .backgroundColor(withAlpha(this.scheme.onSurface, 0.08))
          .borderRadius(16)
          .padding({ left: 12, right: 12 })
          .onChange((v: string) => {
            this.query = v;
            this.recompute(true);
          })
        Text(this.result.hits.length === 0
          ? L.s('transcript_search_none')
          : `${this.cursor + 1} / ${this.result.hits.length}`)
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
        Glyph({ symbol: Sym.up, dim: 18, color: this.result.hits.length === 0
          ? withAlpha(this.scheme.onSurfaceVariant, 0.35) : this.scheme.onSurfaceVariant })
          .accessibilityText(L.s('transcript_search_prev'))
          .onClick(() => { this.step(-1); })
        Glyph({ symbol: Sym.down, dim: 18, color: this.result.hits.length === 0
          ? withAlpha(this.scheme.onSurfaceVariant, 0.35) : this.scheme.onSurfaceVariant })
          .accessibilityText(L.s('transcript_search_next'))
          .onClick(() => { this.step(1); })
        Glyph({ symbol: Sym.close, dim: 18, color: this.scheme.onSurfaceVariant })
          .accessibilityText(L.s('action_cancel'))
          .onClick(() => { this.closeSearch(); })
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 10 })
    } else {
      Row({ space: 14 }) {
        Blank()
        Glyph({ symbol: Sym.search, dim: 19, color: this.scheme.onSurfaceVariant })
          .accessibilityText(L.s('transcript_search'))
          .onClick(() => {
            this.searchOpen = true;
            this.recompute(false);
          })
        Glyph({ symbol: Sym.share, dim: 19, color: this.scheme.onSurfaceVariant })
          .accessibilityText(L.s('transcript_export'))
          .bindMenu(this.exportMenu())
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 10 })
    }
  }

  @Builder
  exportMenu() {
    Menu() {
      MenuItem({ content: L.s('transcript_export_text') })
        .onClick(() => { this.exportAs(TranscriptFormat.Text); })
      MenuItem({ content: L.s('transcript_export_markdown') })
        .onClick(() => { this.exportAs(TranscriptFormat.Markdown); })
    }
  }

  @Builder
  lines() {
    List({ space: LINE_GAP_VP, scroller: this.scroller }) {
      ForEach(this.store.segments, (seg: TranscribedSegment, index?: number) => {
        ListItem() {
          this.lineText(seg, index === undefined ? -1 : index,
            this.isCurrentLine(index === undefined ? -1 : index))
        }
        // 段首多留一块(见文件头 PARA_LINES 那条注释);段内只留 LINE_GAP_VP
        .padding({ top: this.paraTop(index === undefined ? -1 : index) })
        // 点一句跳到那儿 —— 逐字稿最实用的一点
        .onClick(() => { this.player.seekTo(seg.startMs); })
      }, (seg: TranscribedSegment, index?: number) => `${index}-${seg.startMs}`)

      // 识别中尚未定稿的尾巴:浅一档,表示"还会变"
      if (this.store.volatileTail.length > 0) {
        ListItem() {
          Text(this.store.volatileTail)
            .fontSize(TypeScale.bodyLarge * this.fontScale)
            .fontColor(withAlpha(this.scheme.onSurfaceVariant, 0.55))
            .lineHeight(24)
            .width('100%')
        }
      }
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    /**
     * **只认真正的手指触摸**来判断"用户在滚"。
     *
     * 不能用 `onScrollStart`/`onScrollStop`:`scrollToIndex` 自己也会触发它们 ——
     * 于是自动滚动把自己判成"用户在滚",接着几秒内不再跟随,再滚一次又把自己禁言……
     * 净效果是每几秒才跳一下,看上去就是高亮压根不跟着念。这是 Android 端踩过的坑(H60)。
     */
    .onTouch(() => { this.touchedAt = Date.now(); })
  }

  /**
   * 当前句滚进视线。往上留两行:当前句落在偏上的位置,下面还没读到的文字能多看见几行。
   * 手指碰过之后 4 秒内不自动滚。
   */
  private autoScroll(): void {
    if (!this.active) return;
    // 搜索期间不跟读:用户正停在某一处命中上,播放每两句就把他拽走等于搜不了
    if (this.searchOpen && this.query.trim().length > 0) return;
    const i = this.currentIndex();
    if (i < 0 || i === this.scrolledTo) return;
    if (Date.now() - this.touchedAt < 4000) return;
    this.scrolledTo = i;
    try {
      this.scroller.scrollToIndex(Math.max(i - 2, 0), true);
    } catch (e) {
      // 列表还没布局好等情况,忽略
    }
  }

  /**
   * 一句的渲染。
   *
   * - 不是当前句:整句暗色;
   * - 是当前句但没有词级时间:整句强调色 + 半粗(与另两端一致);
   * - 是当前句且有词级时间:**已读到的那个词**用强调色 + 半粗,同句其余用强调色的 55% ——
   *   这样"这一句在读"和"读到这儿了"两层信息同时看得见。
   *
   * 文本**由 words 原样拼**而不是拿整句去找子串:`TranscribedWord` 立了不变式 ——
   * 各条 text 直接拼起来就等于整句(该带的空格已折在 text 里)。所以既不用补空格
   * (补了会把英文子词 "prog"+"rammatic" 拼成两个词),也不用按子串定位(重复词上会错位)。
   *
   * 搜索命中时改走**预切好的片段**(`TextSlice`):底色是 `textBackgroundStyle`,
   * 与上面的前景色/字重是两个维度,同一条 Span 上可以共存。
   */
  @Builder
  lineText(seg: TranscribedSegment, index: number, isCurrent: boolean) {
    if (isCurrent && this.wordHighlight && seg.words.length > 0) {
      if (this.hasMarks(index)) {
        Text() {
          ForEach(this.piecesForCurrent(seg, index), (p: TextSlice, k?: number) => {
            Span(p.text)
              .fontColor(p.spoken ? this.scheme.primary : withAlpha(this.scheme.primary, 0.55))
              .fontWeight(p.spoken ? FontWeight.Medium : FontWeight.Normal)
              .textBackgroundStyle({
                color: p.hit ? withAlpha(this.scheme.onBackground, 0.20) : Color.Transparent,
                radius: 2
              })
          }, (p: TextSlice, k?: number) => `${k}-${p.text}`)
        }
        .fontSize(TypeScale.bodyLarge * this.fontScale)
        .lineHeight(24)
        .width('100%')
      } else {
        Text() {
          ForEach(seg.words, (w: TranscribedWord, k?: number) => {
            Span(w.text)
              .fontColor(this.isSpokenWord(seg, k === undefined ? -1 : k)
                ? this.scheme.primary
                : withAlpha(this.scheme.primary, 0.55))
              .fontWeight(this.isSpokenWord(seg, k === undefined ? -1 : k)
                ? FontWeight.Medium : FontWeight.Normal)
          }, (w: TranscribedWord, k?: number) => `${k}-${w.startMs}`)
        }
        .fontSize(TypeScale.bodyLarge * this.fontScale)
        .lineHeight(24)
        .width('100%')
      }
    } else if (this.hasMarks(index)) {
      Text() {
        ForEach(this.slicesOf(index), (p: TextSlice, k?: number) => {
          Span(p.text)
            .fontColor(isCurrent ? this.scheme.primary : this.scheme.onSurfaceVariant)
            .fontWeight(isCurrent ? FontWeight.Medium : FontWeight.Normal)
            .textBackgroundStyle({
              color: p.hit ? withAlpha(this.scheme.onBackground, 0.20) : Color.Transparent,
              radius: 2
            })
        }, (p: TextSlice, k?: number) => `${k}-${p.text}`)
      }
      .fontSize(TypeScale.bodyLarge * this.fontScale)
      .lineHeight(24)
      .width('100%')
    } else {
      Text(seg.text)
        .fontSize(TypeScale.bodyLarge * this.fontScale)
        .fontColor(isCurrent ? this.scheme.primary : this.scheme.onSurfaceVariant)
        .fontWeight(isCurrent ? FontWeight.Medium : FontWeight.Normal)
        .lineHeight(24)
        .width('100%')
    }
  }

  /**
   * 第 `i` 句是不是当前句 —— **O(1) 判据**,不是"先算出当前句下标再逐行比"。
   *
   * 为什么不用 `currentIndex()` 去比:那个函数是**整张表从后往前**扫的,而渲染侧要给每一行
   * 都判一次,于是每档重渲变成"每行 O(句)"。改成只看"本句起点已过去、且下一句还没到",
   * 一次比较就够(表尾没有下一句,所以最后那句一旦起点过去就是当前句)。
   *
   * Android 端没有这一层:它把 `currentIndex` 放在顶层一次 `remember(segments, nowMs / 100)`
   * 算好再往下传,整档只有 O(句)。本端原本想照抄那个形状,但 ArkUI 的 `@Builder` 里
   * **不能声明局部变量** —— 实测 `const cur = this.currentIndex();` 直接编译失败
   * (`10905209 Only UI component syntax can be written here`,见 H137),没有"算一次存进变量"
   * 这条路;而存成字段又变成"每个改 nowMs 与改稿子的地方都要记得去更新/失效它"的缓存问题。
   * 所以这里换的是**等价的判据**:同样只看当前位置,不需要任何缓存,也不依赖谁记得失效它。
   *
   * 依赖的不变式与 `currentIndex()` 完全同一个(起点单调不减),见上面那条注释与硬规矩 10。
   */
  private isCurrentLine(i: number): boolean {
    if (i < 0) return false;
    const segs = this.store.segments;
    if (segs[i].startMs > this.nowMs) return false;
    return i + 1 >= segs.length || segs[i + 1].startMs > this.nowMs;
  }

  /**
   * 段首要不要多留一块。**纯算术判据**(按句号下标取模),不做任何扫描 ——
   * 渲染侧每句都要问一次,按"先算出段落边界数组"那种形状就变成每档重渲 O(句)(硬规矩 6)。
   * 三端同一条规则:Android `TranscriptPane.kt` / Apple `TranscriptPage.swift` 里的 `PARA_LINES`。
   */
  private paraTop(i: number): number {
    return i > 0 && i % PARA_LINES === 0 ? PARA_GAP_VP : 0;
  }

  /// 这一句的第 `k` 个词是不是正在读的那个 —— 同样 O(1),理由见 `isCurrentLine`
  private isSpokenWord(seg: TranscribedSegment, k: number): boolean {
    if (k < 0) return false;
    const words = seg.words;
    if (words[k].startMs > this.nowMs) return false;
    return k + 1 >= words.length || words[k + 1].startMs > this.nowMs;
  }

  @Builder
  progress(text: string) {
    Column({ space: 12 }) {
      LoadingProgress().width(34).height(34).color(this.scheme.primary)
      Text(text)
        .fontSize(TypeScale.caption * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
        .textAlign(TextAlign.Center)
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  hint(text: string, action: string, isError: boolean) {
    Column({ space: 14 }) {
      Text(text)
        .fontSize(TypeScale.caption * this.fontScale)
        .fontColor(isError ? this.scheme.error : this.scheme.onSurfaceVariant)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      if (action.length > 0) {
        Button(action)
          .fontSize(TypeScale.body * this.fontScale)
          .backgroundColor(this.scheme.primary)
          .fontColor(this.scheme.onPrimary)
          .onClick(() => { this.onStart(); })
      }
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
