import { PlaybackClock } from '../playback/PlaybackClock';
import { formatTime } from './Components';

/**
 * 睡眠倒计时的时间文本 —— 播放页那颗 chip 里**唯一每秒变化**的东西,所以它单独是一个组件。
 *
 * 为什么不留在那一整页里:剩余毫秒每秒被 ticker 写一次,而 ArkUI V1 的观察粒度是**对象**
 * (不区分 private)。原先这个数值就是 `PlayerController` 的一个字段、每秒 `notify()`,
 * 结果一开睡眠定时,挂着播放态的那些界面(播放页 / 迷你条 / 底栏组件)在播放中
 * **每秒整页重建一次** —— 与 `positionMs` 当年是同一笔账(见 H64 与 `PlaybackClock` 的注释)。
 *
 * 现在数值在非观察的 `PlaybackClock` 里,读它不建立依赖,于是"每秒刷新"这件事
 * 只能由用它的这一小块自己轮询(与 `SeekBar` 同一手法),并且**只在定时真的开着时起表**:
 * 没开睡眠定时的绝大多数时间里,这里一个定时器都不存在。
 */
@Component
export struct SleepCountdownText {
  @Prop color: string;
  @Prop fontSize: number;
  /// 定时是否在走(来自观察字段 `sleepTimed`)。关掉它就停表,不剩空转的 interval。
  @Prop @Watch('onGate') running: boolean;
  /// 普通成员而不是 @Prop:clock 是稳定对象,且**刻意不参与依赖收集**
  clock: PlaybackClock | null = null;

  @State text: string = '';
  private timer: number = -1;

  aboutToAppear(): void {
    this.sample();
    this.onGate();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private onGate(): void {
    if (this.running && this.timer < 0) {
      this.timer = setInterval(() => this.sample(), 1000);
    } else if (!this.running && this.timer >= 0) {
      this.stopTimer();
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private sample(): void {
    const c = this.clock;
    const ms = c === null ? 0 : c.sleepRemainingMs;
    const v = ms > 0 ? formatTime(ms) : '';
    if (v !== this.text) this.text = v;
  }

  build() {
    Text(this.text)
      .fontSize(this.fontSize)
      .fontColor(this.color)
  }
}
