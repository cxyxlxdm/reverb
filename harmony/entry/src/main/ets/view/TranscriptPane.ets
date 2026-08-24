import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { PlayerController } from '../playback/PlayerController';
import { TranscriptStore, TranscriptState } from '../store/TranscriptStore';
import { TranscribedSegment, TranscribedWord } from '../model/Models';

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
   * 为什么不直接用 `player.positionMs`:那个值 **500ms 才更新一次**,直接拿它找当前句会让
   * 高亮一跳一跳(短句只有一两秒,采样误差就占了一半),逐字高亮更是完全看不出跟读感。
   * 这里记住"上一次采样值 + 采样时刻",两次采样之间按真实流逝时间往前推 ——
   * 与 Android `rememberExtrapolatedPosition`、macOS 的 anchorMs/anchorAt 同一手法。
   */
  @State nowMs: number = 0;

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

  /**
   * 当前是第几句:**从后往前**找第一个起点已过去的。
   *
   * 这个写法只在**句子起点单调不减**时才正确 —— 队尾混进一个异常小的值就会永远命中它,
   * 高亮钉死不动。官方稿由 `TranscriptLines.monotonic` 保证,系统识别那条按喂入量递推,
   * 天然单调(见 `SpeechTranscriber`)。
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
      } else if (this.store.state === TranscriptState.FetchingOfficial) {
        this.progress(L.s('transcript_fetching'))
      } else if (this.store.state === TranscriptState.DownloadingAudio) {
        this.progress(L.s('transcript_preparing_audio'))
      } else if (this.store.state === TranscriptState.Failed) {
        this.hint(L.s('transcript_failed'), L.s('action_retry'), true)
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

  @Builder
  lines() {
    List({ space: 10, scroller: this.scroller }) {
      ForEach(this.store.segments, (seg: TranscribedSegment, index?: number) => {
        ListItem() {
          this.lineText(seg, (index === undefined ? -1 : index) === this.currentIndex())
        }
        // 点一句跳到那儿 —— 逐字稿最实用的一点
        .onClick(() => { this.player.seekTo(seg.startMs); })
      }, (seg: TranscribedSegment, index?: number) => `${index}-${seg.startMs}`)

      // 识别中尚未定稿的尾巴:浅一档,表示"还会变"
      if (this.store.volatileTail.length > 0) {
        ListItem() {
          Text(this.store.volatileTail)
            .fontSize(TypeScale.body * this.fontScale)
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
   */
  @Builder
  lineText(seg: TranscribedSegment, isCurrent: boolean) {
    if (isCurrent && this.wordHighlight && seg.words.length > 0) {
      Text() {
        ForEach(seg.words, (w: TranscribedWord, k?: number) => {
          Span(w.text)
            .fontColor(this.spokenIndex(seg) === (k === undefined ? -1 : k)
              ? this.scheme.primary
              : withAlpha(this.scheme.primary, 0.55))
            .fontWeight(this.spokenIndex(seg) === (k === undefined ? -1 : k)
              ? FontWeight.Medium : FontWeight.Normal)
        }, (w: TranscribedWord, k?: number) => `${k}-${w.startMs}`)
      }
      .fontSize(TypeScale.body * this.fontScale)
      .lineHeight(24)
      .width('100%')
    } else {
      Text(seg.text)
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(isCurrent ? this.scheme.primary : this.scheme.onSurfaceVariant)
        .fontWeight(isCurrent ? FontWeight.Medium : FontWeight.Normal)
        .lineHeight(24)
        .width('100%')
    }
  }

  /// 这一句里读到第几个词了(同样是从后往前找第一个起点已过去的)
  private spokenIndex(seg: TranscribedSegment): number {
    for (let i = seg.words.length - 1; i >= 0; i--) {
      if (seg.words[i].startMs <= this.nowMs) return i;
    }
    return -1;
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
