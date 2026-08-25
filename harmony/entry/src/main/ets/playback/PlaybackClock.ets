/**
 * 播放进度的存放处 —— **刻意不加 `@Observed`**。
 *
 * 为什么单独开一个类:`PlayerController` 是 `@Observed`,而 ArkUI V1 的观察粒度是
 * **整个对象** —— 只要它的任何一个字段被赋值,所有 `@ObjectLink` 持有者都会重跑 build。
 * 而 AVPlayer 的 `timeUpdate` 事件**约每 100ms 一次**,进度字段若挂在控制器自身上,
 * 就等于「播放中把发现页 / 音阁页 / 迷你条每秒整页重建 10 次」。
 *
 * 真机实测(H64):静置在发现页、仅后台播放,10 秒内 45 次整页重建、62 帧 jank;
 * 暂停后同一窗口 0 次 0 帧。下拉刷新时最明显 —— 转圈动画和刷新手势要的正是那条被占满的
 * UI 线程,于是用户看到的是「loading 非常卡」。
 *
 * 所以进度写进这个**普通对象**(嵌套的非观察对象不参与依赖收集),
 * 需要进度的界面各自按**自己需要的频率**去读:
 *   - 进度条 `SeekBar`:250ms(拖动时用本地值,不被回写)
 *   - 迷你条那条 2px 细线:1s,且按整数百分比去重,值没变就不重建
 *   - 逐字稿 `TranscriptPane`:80ms(它本来就有自己的外推心跳)
 *
 * 教训写在 `AGENTS.md` 硬规矩里:**高频状态不要挂在被整体观察的对象上。**
 */
/**
 * 补一句**同样重要**的:播放期间"每秒都在变"的量**一律放这里**,不只是位置。
 *
 * 踩过的具体一脚:把 positionMs 挪走之后,整页重建从 10Hz 降到了 2Hz —— 剩下的
 * 正是 500ms ticker 里那两行不起眼的记账(`tickCount += 1`、`lastCountedPosMs = …`)。
 * ArkUI V1 **不区分 private**:哪怕是私有字段,赋值一样触发通知。
 * 所以判断标准不是"这个字段界面用不用",而是"**它多久变一次**"。
 */
export class PlaybackClock {
  /// 当前播放位置(毫秒)。由 PlayerController 在 timeUpdate / seek / 换集时写。
  positionMs: number = 0;
  /// 500ms ticker 的跳数(用于"每 10 跳落一次盘")
  ticks: number = 0;
  /// 收听时长计数的基线:上次计入的位置与单集 id
  countedPosMs: number = 0;
  countedEpId: string = '';
}
