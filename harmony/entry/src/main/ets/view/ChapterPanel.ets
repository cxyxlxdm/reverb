import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Chapter } from '../model/Models';
import { ChapterStore, ChapterState } from '../store/ChapterStore';
import { PlaybackClock } from '../playback/PlaybackClock';
import { Glyph, Sym } from './Widgets';
import { formatTime } from './Components';

/**
 * 播放页的章节入口:一行文字(当前章标题,没有时写「章节」)+ 下拉小三角。
 *
 * **为什么单独拆成组件**:它要显示"当前播到哪一章",而进度是每秒都在变的量。
 * 挂在播放页上会让整页按秒重渲(硬规矩 6/7 那条账,H64)。拆出来之后本组件自己按秒轮询
 * `PlaybackClock`,只重渲这一行文本 —— 与 `SeekBar` / `SleepCountdownText` 同一手法。
 *
 * `clock` 是**普通成员而不是 @Prop**:它就是那个刻意不参与依赖收集的对象,挂成 @Prop
 * 反而会把它登记成依赖。
 */
@Component
export struct ChapterEntry {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink store: ChapterStore;
  /**
   * 当前这一集的 id。切集时 `@Watch` 触发 `prepare`,把上一集的列表与状态清掉 ——
   * 否则自动续播到下一集、而下一集也有章表时,入口会先显示上一集的章名。
   */
  @Prop @Watch('onEpisode') episodeId: string;
  clock: PlaybackClock | null = null;
  onOpen: () => void = () => {};

  @State posMs: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.store.prepare(this.episodeId);
    this.sample();
    // 1 秒一次:章名以"分"为单位变化,比 SeekBar 的 250ms 粗得多;暂停时也照跑,
    // 因为用户可能拖进度条换章(拖动松手后同样要归位)。
    this.timer = setInterval(() => { this.sample(); }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private onEpisode(): void {
    this.store.prepare(this.episodeId);
    this.sample();
  }

  private sample(): void {
    const c = this.clock;
    const v = c === null ? 0 : c.positionMs;
    if (v !== this.posMs) this.posMs = v;
  }

  /**
   * 当前章名。列表还没取回来、或还没到第一章的起点时都写「章节」——
   * 那条 `store.episodeId` 的判断是切集瞬间的护栏(见 `episodeId` 的注释)。
   */
  private title(): string {
    if (this.store.episodeId !== this.episodeId) return L.s('player_chapters');
    const idx = this.store.indexAt(this.posMs);
    if (idx < 0 || idx >= this.store.chapterList.length) return L.s('player_chapters');
    return this.store.chapterList[idx].title;
  }

  build() {
    Row({ space: 3 }) {
      Text(this.title())
        .fontSize(TypeScale.labelLarge * this.fontScale)
        .fontColor(this.scheme.primary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Glyph({ symbol: Sym.down, dim: 14, color: this.scheme.primary })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .padding({ left: 12, right: 10, top: 4, bottom: 4 })
    .onClick(() => { this.onOpen(); })
  }
}

/**
 * 章节列表(半模态内容)。点一章跳到它的起点,由调用方关闭弹层。
 *
 * 与 Android `ChapterSheet` 同内容:标题 → 加载中 / 空 / 失败重试 / 列表。
 * 列表高亮「当前章」,而位置同样不在本组件外暴露 —— 自己按秒轮询 clock。
 */
@Component
export struct ChapterSheetView {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink store: ChapterStore;
  @Prop @Watch('onEpisode') episodeId: string;
  @Prop @Watch('onEpisode') chaptersUrl: string;
  clock: PlaybackClock | null = null;
  onSeek: (ms: number) => void = () => {};

  @State posMs: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.onEpisode();
    this.timer = setInterval(() => { this.sample(); }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /// 点开就取(命中缓存在 store 里,反复开合不会重复下载)。切集时同一入口重新取。
  private onEpisode(): void {
    this.sample();
    this.store.loadFor(this.episodeId, this.chaptersUrl);
  }

  private sample(): void {
    const c = this.clock;
    const v = c === null ? 0 : c.positionMs;
    if (v !== this.posMs) this.posMs = v;
  }

  build() {
    Column() {
      Text(L.s('player_chapters'))
        .fontSize(TypeScale.titleMedium * this.fontScale)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onSurface)
        .width('100%')
        .padding({ left: 24, right: 24, top: 10, bottom: 8 })

      if (this.store.state === ChapterState.Idle || this.store.state === ChapterState.Loading) {
        Row() {
          LoadingProgress().width(32).height(32).color(this.scheme.primary)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height(160)
        .alignItems(VerticalAlign.Center)
      } else if (this.store.state === ChapterState.Empty) {
        Text(L.s('chapters_empty'))
          .fontSize(TypeScale.body * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .width('100%')
          .padding({ left: 24, right: 24, top: 24, bottom: 24 })
      } else if (this.store.state === ChapterState.Failed) {
        // 失败态给的是**再点一次**,不是一个空列表 —— 网络抖一下不该让这一集"没有章节"
        Text(L.s('chapters_failed'))
          .fontSize(TypeScale.body * this.fontScale)
          .fontColor(this.scheme.primary)
          .width('100%')
          .padding({ left: 24, right: 24, top: 24, bottom: 24 })
          .onClick(() => { this.onEpisode(); })
      } else {
        Scroll() {
          Column() {
            ForEach(this.store.chapterList, (c: Chapter, i: number) => {
              Row() {
                Text(formatTime(c.startMs))
                  .fontSize(TypeScale.label * this.fontScale)
                  .fontColor(this.isActive(i) ? this.scheme.primary : this.scheme.onSurfaceVariant)
                  .width(52)
                Text(c.title)
                  .fontSize(TypeScale.body * this.fontScale)
                  .fontWeight(this.isActive(i) ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.isActive(i) ? this.scheme.primary : this.scheme.onSurface)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: 24, right: 24, top: 12, bottom: 12 })
              .backgroundColor(this.isActive(i) ? withAlpha(this.scheme.primary, 0.10) : Color.Transparent)
              .onClick(() => { this.onSeek(c.startMs); })
            }, (c: Chapter, i: number) => `${i}-${c.startMs}`)
            Row().height(24)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.scheme.surface)
  }

  private isActive(index: number): boolean {
    return this.store.indexAt(this.posMs) === index;
  }
}
