import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { PlaybackClock } from '../playback/PlaybackClock';
import { formatTime } from './Components';

/**
 * 播放页的进度条 + 两端时间。
 *
 * **为什么单独拆成一个组件**:进度是唯一高频变化的东西,而播放页是全应用最重的一棵子树
 * (轮播三页 + 水墨画布 + shownotes 长文)。进度若挂在播放页自己的状态上,
 * 每次进度更新都要重跑整页 build —— 原先是 `@Observed` 每 100ms 推一次,更糟(见 H64)。
 *
 * 拆出来之后,进度更新只重渲这一小块:自己持有 `@State posMs`,自己按 250ms 轮询
 * `PlaybackClock`(非观察对象)。250ms 对一条进度条足够 —— 时间文本的精度本来就是秒。
 */
@Component
export struct SeekBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 时长是异步到达的,要能跟着更新
  @Prop durationMs: number;
  /// 播放中才需要轮询;暂停后停表,但仍补采一次(seek 后松手要归位)
  @Prop @Watch('onGate') playing: boolean;
  /// 普通成员(不是 @Prop):clock 是稳定对象,且**刻意不参与依赖收集**
  clock: PlaybackClock | null = null;
  onSeek: (ms: number) => void = () => {};

  @State posMs: number = 0;
  /// 拖动期间显示手指位置,不被播放位置回写
  @State dragging: boolean = false;
  @State dragValue: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.sample();
    this.onGate();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private onGate(): void {
    if (this.playing && this.timer < 0) {
      this.timer = setInterval(() => this.sample(), 250);
    } else if (!this.playing && this.timer >= 0) {
      this.stopTimer();
      this.sample();
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private sample(): void {
    if (this.dragging) return;
    const c = this.clock;
    const v = c === null ? 0 : c.positionMs;
    if (v !== this.posMs) this.posMs = v;
  }

  private shown(): number {
    return this.dragging ? this.dragValue : this.posMs;
  }

  build() {
    Column() {
      Slider({
        value: this.shown(),
        min: 0,
        max: Math.max(1, this.durationMs),
        style: SliderStyle.OutSet
      })
        .selectedColor(this.scheme.primary)
        .trackColor(withAlpha(this.scheme.onSurfaceVariant, 0.25))
        .blockColor(this.scheme.primary)
        .width('100%')
        /**
         * Slider 不设 `accessibilityText` 时,ArkUI 直接把 **value 的原始数字**当可读文本 ——
         * 而这里的 value 单位是毫秒,真机 dumpLayout 实测读屏拿到的是 `101300.000000`
         * (界面上同一时刻写的是 `01:41`)。这一串既不是时间也不是比例,等于没有信息。
         *
         * 用「当前 / 总长」两个已格式化的时间拼,和进度条下方那行文本逐字一致。
         * 不新增五条本地化文案的理由同 `DateParse.formatCachedAt`:纯数字时间各语言都读得通。
         *
         * **本端改动无法用工具取证**:`uitest dumpLayout` 整条通道没有无障碍字段
         * (本轮 83 份 dump、13,958 个节点里 `description` 非空 **0 个**,见 H143 补记),所以这条只能实听。
         * Android 侧同样取证不到 ——
         * `uiautomator dump` 里 `android.widget.SeekBar` 节点的 `content-desc` 是空串,
         * 且 XML 里没有 RangeInfo(2026-10-08 实测)。所以不要拿"对端念百分比"当对照结论。
         */
        .accessibilityText(`${formatTime(this.shown())} / ${formatTime(this.durationMs)}`)
        .onChange((v: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.dragging = true;
            this.dragValue = v;
          } else {
            // 松手才真正 seek(拖动期间不被播放位置回写)
            const ms = Math.floor(v);
            this.posMs = ms;
            this.dragging = false;
            this.onSeek(ms);
          }
        })
      Row() {
        Text(formatTime(this.shown()))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
        Blank()
        Text(formatTime(this.durationMs))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
      }
      .width('100%')
    }
    .width('100%')
  }
}
