import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { Podcast, Episode } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { SettingsStore } from '../store/SettingsStore';
import { SubscriptionStore, FavoriteStore, HistoryStore } from '../store/Stores';
import { InboxStore } from '../store/InboxStore';
import { DownloadStore } from '../store/DownloadStore';
import { DownloadManager } from '../playback/DownloadManager';
import { PlayerController } from '../playback/PlayerController';
import { ScreenHeader, EmptyHint, LoadingBox, Glyph, Sym } from './Widgets';
import { PodcastListItem, PodcastGridItem, EpisodeListItem, ChipsRow, CHIPS_RESERVE_H, ChipsSwipeSync } from './Components';
import { Log } from '../util/Logger';

/// 音阁:订阅 / 最新 / 收藏 / 历史 四分段(下载段留后续轮次)。
/// 对应 Android `LibraryScreen.kt`。分段用 chips + Swiper 双向联动。
@Component
export struct LibraryPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 玻璃 tab 栏悬浮后,滚动内容需让出的底部空间(手势条+栏+迷你条,Index 算好传入)。
  /// 只用于各 List 的 contentEndOffset / 宫格的尾部占位行。
  @Prop bottomPad: number = 0;
  @ObjectLink player: PlayerController;
  /**
   * 本页渲染用到的 store 一律经 `@ObjectLink` 接收(各 store 均已 `@Observed`,
   * 且都是「复制后整体赋值」,故字段变化能被观察到)。
   *
   * 不要退回 `this.app.xxx` 直读:那是未被观察的裸对象。本页原先四处交互
   * (宫格切换 / 清空历史 / 删除下载 / 「最新」刷新完成)都没有任何本地状态变化,
   * 于是点了界面不动;偶尔看着正常,是切分段或播放状态 tick 顺带刷新的。详见 H27。
   */
  @ObjectLink settings: SettingsStore;
  @ObjectLink subscriptions: SubscriptionStore;
  @ObjectLink inbox: InboxStore;
  @ObjectLink favorites: FavoriteStore;
  @ObjectLink downloads: DownloadStore;
  @ObjectLink history: HistoryStore;
  @ObjectLink downloadManager: DownloadManager;
  onOpenPodcast: (p: Podcast) => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[]) => void = () => {};
  onOpenSettings: () => void = () => {};
  onOpenListenStats: () => void = () => {};

  @State seg: number = 0;
  /**
   * chips 高亮专用索引,**与驱动 Swiper `.index()` 的 seg 分开**。
   *
   * 为什么不共用一个:拖动过程中要让高亮跟着手指走(位移过半就切),但
   * `.index()` 是 Swiper 的受控属性 —— 手势进行中改它有把页面强行跳走的风险。
   * 拆成两个后:seg 只由「点 chip」和 onChange(落位)改;chipSel 由手势/动画开始改,
   * 只影响 chips 的显示。
   */
  @State chipSel: number = 0;
  /// 顶部分类条胶囊与 Swiper 的手势联动总线(每帧只重建胶囊,见 Components 注释)
  private chipSync: ChipsSwipeSync = new ChipsSwipeSync();
  /// Swiper 实测宽度,用来判断拖动是否过半
  @State pageW: number = 0;

  private app: AppContainer = AppContainer.get();
  private segments(): string[] { return [L.s('lib_subscriptions'), L.s('lib_inbox'), L.s('lib_favorites'), L.s('lib_downloads'), L.s('lib_history')]; }

  aboutToAppear(): void {
    // 进音阁即按需刷新「最新」(订阅集未变则跳过,避免切 tab 反复全量刷)
    this.refreshInbox(false);
  }

  /// 刷新「最新」。loading 状态由 store 自己持有(inbox.refreshing):
  /// 若用本地标志,被重入拒绝的那次调用会把转圈提前关掉——Android 上踩过这个坑。
  private async refreshInbox(force: boolean): Promise<void> {
    const subs = this.subscriptions.subscriptions;
    if (subs.length === 0) return;
    if (force) await this.inbox.refresh(subs, this.app.repository);
    else await this.inbox.refreshIfStale(subs, this.app.repository);
    Log.i('Library', `最新:当前 ${this.inbox.episodes.length} 条`);
  }

  build() {
    Column() {
      ScreenHeader({
        scheme: this.scheme,
        fontScale: this.fontScale,
        title: L.s('nav_library'),
        action: () => { this.headerActions() }
      })

      // 玻璃分段条悬浮在内容上,内容从条下滚过(与底部玻璃栏同思路)。
      // 右侧浮动按钮一并收进条内:chips 会从按钮底下经过,按钮自己也上玻璃
      // (玻璃叠玻璃)才有遮蔽力;原先的实色背景在玻璃条上是一块补丁。
      Stack({ alignContent: Alignment.Top }) {
        Swiper() {
          this.subscriptionsSection()
          this.inboxSection()
          this.favoritesSection()
          this.downloadsSection()
          this.historySection()
        }
        .index(this.seg)
        .loop(false)
        .indicator(false)
        .cachedCount(1)
        .onAreaChange((_o: Area, n: Area) => { this.pageW = Number(n.width); })
        // chips 高亮**跟着手指走**:拖动位移过半即切换,与 Compose 的
        // pagerState.currentPage(过半更新)手感一致。只改 chipSel,不碰 seg —— 见 chipSel 注释。
        .onGestureSwipe((index: number, e: SwiperAnimationEvent) => {
          this.chipSel = this.dragTarget(index, e.currentOffset);
          // 胶囊 1:1 联动:插值目标取拖动方向的相邻页(拖 30% 走 30% 路程),
          // 与过半预切的 dragTarget 无关;边缘橡皮筋(相邻页不存在)不报,胶囊原地。
          // currentOffset 实测是**当前页相对其锚点的带符号位移**:向左滑(去下一页,
          // 序号+1)为负、向右滑为正 —— 与 dragTarget 的方向约定一致
          // (offset < 0 ? index+1 : index-1);方向写反会被 to<0 边缘保护吞掉(踩过)。
          if (this.pageW <= 0) return;
          const to = index + (e.currentOffset < 0 ? 1 : -1);
          if (to < 0 || to >= this.segments().length) return;
          this.chipSync.report(index, to,
            Math.min(1, Math.abs(e.currentOffset) / this.pageW));
        })
        // 松手后动画开始就定下目标页(`onChange` 要等动画**结束**才回调,那样 chips 慢一拍)
        .onAnimationStart((_i: number, target: number) => {
          this.chipSel = target;
          // 动画一开始就收束胶囊(提交随落位弹簧、回落原地弹回),不等 onAnimationEnd
          this.chipSync.end(target);
        })
        .onAnimationEnd((_i: number, _e: SwiperAnimationEvent) => {
          // 兜底:回落若不触发 onAnimationStart,靠这里把胶囊从插值位收回来(幂等)
          this.chipSync.end(this.chipSel);
        })
        .onChange((i: number) => { this.seg = i; this.chipSel = i; })
        .width('100%')
        .height('100%')

        ChipsRow({
          scheme: this.scheme,
          fontScale: this.fontScale,
          labels: this.segments(),
          selected: this.chipSel,
          sync: this.chipSync,
          onSelect: (i: number) => { this.seg = i; this.chipSel = i; },
          // 段尾动作交给条自己摆(条内右端 + 垂直居中)。原先这两个按钮是这里另起一个
          // Stack 浮在条外面的:右缘按 pagePadding 16 对齐,而条的留白是 12,两者差几 vp
          // 就对不上条的右圆顶;再各自糊一块 backgroundEffect,玻璃上叠玻璃成了补丁。
          endAction: () => { this.barActions() }
        })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 分段条右端的动作位(由 `ChipsRow.endAction` 摆位,自己不定位)。
   *
   * ⚠️ **不要再给它们加背景**:底就是那条玻璃。原先各带一块 `backgroundEffect`,
   * 玻璃条上再糊一颗玻璃,装机判为「太丑」。
   * `padding` 在 `onClick` **之前** ⇒ 内边距算进命中框,点字的边缘也触发得了一旁。
   * 左右都留 16:左边是与正在横滚的 chips 之间的缝,右边让文字不贴着条的圆顶。
   * **两端同值**:Android 侧那颗 `TextButton` 的 `contentPadding` 是 start 16 / end 8,
   * 外加 `endAction` 容器自己的 8dp end 内边距 ⇒ 文字离条右缘同样是 16。
   */
  @Builder
  barActions() {
    // ⚠️ **不看订阅数**:Android 侧同一颗按钮的条件只有 `section == 0`,没有"非空才显示"。
    // 这里先前多挂了 `subscriptions.length > 0`,装机表现就是用户反馈的「切到订阅 tab
    // 右侧没有排序方式按钮」—— 一台还没订阅的手机两边行为立刻不一样,而排列方式是全局
    // 设置,空列表时切了下次进来看得到,没有任何理由藏起来。
    if (this.seg === 0) {
      // 与 Android 一致:图标按钮,且**图标表示切换后的目标布局**(当前是宫格就显示"列表")
      Glyph({
        symbol: this.settings.subsGrid ? Sym.list : Sym.grid,
        dim: 20, color: this.scheme.onSurfaceVariant
      })
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick(() => { this.settings.setSubsGrid(!this.settings.subsGrid); })
    }
    if (this.seg === 4 && this.history.history.length > 0) {
      Text(L.s('action_clear'))
        // 字号取 labelLarge 与 Android 那颗 TextButton 同档(原先是 caption,比另一端小一号)
        .fontSize(TypeScale.labelLarge * this.fontScale)
        .fontColor(this.scheme.primary)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick(() => { this.history.clear(); })
    }
  }

  /// 拖动位移 → 目标页。位移过半才算切,并夹在合法范围内。
  /// 正负号不写死:不同版本/方向下 currentOffset 的符号可能相反,用绝对值加方向判断。
  private dragTarget(index: number, offset: number): number {
    if (this.pageW <= 0) return index;
    if (Math.abs(offset) < this.pageW / 2) return index;
    const next = offset < 0 ? index + 1 : index - 1;
    return Math.max(0, Math.min(this.segments().length - 1, next));
  }

  /// 与 Android `LibraryScreen.kt` 一致:只有「收听时长」「设置」两个图标按钮。
  /// 「听觉足迹」在 Android 是设置页里的一条(`SettingsScreen.kt` 的 set_footprint),
  /// 不在页头 —— 鸿蒙原先在这儿放了个「印」字按钮,是自创的,已移入设置页对齐。
  @Builder
  headerActions() {
    Row({ space: 18 }) {
      Glyph({ symbol: Sym.listenStats, dim: 22, color: this.scheme.onSurfaceVariant })
        .onClick(() => this.onOpenListenStats())
      Glyph({ symbol: Sym.settings, dim: 22, color: this.scheme.onSurfaceVariant })
        .onClick(() => this.onOpenSettings())
    }
  }

  // ── 订阅 ──
  @Builder
  subscriptionsSection() {
    Column() {
      if (this.subscriptions.subscriptions.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('empty_subscriptions') })
      } else if (this.settings.subsGrid) {
        // **三列**,与 Android 一致。原先写死 `1fr 1fr` 两列 —— 不是密度所致,是硬编码:
        // Android 用的是 `GridCells.Adaptive(minSize = 104.dp)`,在手机上自适应出三列。
        // 两列的封面大得没有必要,一屏只放六个,反而不如列表好用。
        //
        // 另外原先是 `Scroll { Grid }` 外加一句
        // `height(ceil(n / 2) * 230 + 20)` 手算总高 —— Grid 本身就可滚动,套 Scroll 才需要
        // 给死高度,而那个 230 是按两列卡高估的常数:改列数、改字号、改字号倍率都会让它算错
        // (算小了滚不到底,算大了底部拖出一片空白)。直接用 Grid 自己滚,这笔账就不用算。
        Grid() {
          // 顶部占位行:给玻璃分段条让出余量(宫格用不了 List 的 contentStartOffset)
          GridItem() { Row().width('100%').height(CHIPS_RESERVE_H) }
          ForEach(this.subscriptions.subscriptions, (p: Podcast) => {
            GridItem() {
              PodcastGridItem({
                scheme: this.scheme, fontScale: this.fontScale, podcast: p,
                onTap: () => this.onOpenPodcast(p)
              })
            }
          }, (p: Podcast) => p.feedUrl)
          // 尾部占位行:给玻璃栏底下留滚动余量(宫格用不了 List 的 contentEndOffset)。
          // 三列格中单个 GridItem 只占一格,但该行行高由它决定,整行皆空,等效通栏留白。
          if (this.bottomPad > 0) {
            GridItem() { Row().width('100%').height(this.bottomPad) }
          }
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(Metrics.gridSpacing)
        .rowsGap(Metrics.gridSpacing + 4)
        // **top 必须给** —— 原先只写了 left/right/bottom,于是第一行封面紧贴上方的分段 chips。
        // 列表分支之所以没暴露这个问题,是因为它靠每个 PodcastListItem 自带的 `top: 10` 撑开;
        // 宫格里没有那层内边距,不给就是零。10 + chips 行自身下方约 7 的余量 ≈ Android 实测的 16.5dp。
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 20 })
        // Grid 没有 contentEndOffset(List 专属 API):滚动余量靠上面的尾部占位 GridItem
        .scrollBar(BarState.Off)
        .width('100%').height('100%')
      } else {
        List() {
          // 顶部占位:给玻璃分段条让出高度(contentStartOffset 实测是初始滚动位语义,
          // 列表重建后首项会被顶到条背后;占位 ListItem 是纯布局,保证首项停在条下方)
          ListItem() {
            Row().width('100%').height(CHIPS_RESERVE_H)
          }
          ForEach(this.subscriptions.subscriptions, (p: Podcast) => {
            ListItem() {
              PodcastListItem({
                scheme: this.scheme, fontScale: this.fontScale, podcast: p,
                onTap: () => this.onOpenPodcast(p)
              })
            }
          }, (p: Podcast) => p.feedUrl)
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  // ── 最新(收件箱)──
  @Builder
  inboxSection() {
    Refresh({ refreshing: this.inbox.refreshing }) {
      Column() {
        if (this.subscriptions.subscriptions.length === 0) {
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('empty_inbox_nosubs') })
        } else if (this.inbox.episodes.length === 0) {
          if (this.inbox.refreshing) {
            LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
          } else {
            EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('empty_inbox') })
          }
        } else {
          List() {
            // 顶部占位:理由见订阅段同名注释
            ListItem() {
              Row().width('100%').height(CHIPS_RESERVE_H)
            }
            ForEach(this.inbox.episodes, (e: Episode) => {
              ListItem() {
                EpisodeListItem({
                  scheme: this.scheme, fontScale: this.fontScale, episode: e,
                  showPodcastTitle: true,
                  isCurrent: this.player.current !== null && this.player.current.id === e.id,
                  isPlaying: this.player.isPlaying,
                  played: this.history.isPlayed(e.id),
                  onPlay: () => this.onPlayEpisode(e, this.inbox.episodes),
                  onPlayNext: () => { this.player.playNext(e); },
                  onEnqueue: () => { this.player.enqueue(e); }
                })
              }
            }, (e: Episode) => e.id)
          }
          .scrollBar(BarState.Off)
          .contentEndOffset(this.bottomPad)
          .width('100%').height('100%')
        }
      }
      .width('100%').height('100%')
    }
    .onRefreshing(() => { this.refreshInbox(true); })
    .width('100%').height('100%')
  }

  // ── 收藏 ──
  @Builder
  favoritesSection() {
    Column() {
      if (this.favorites.favorites.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('empty_favorites') })
      } else {
        List() {
          // 顶部占位:理由见订阅段同名注释
          ListItem() {
            Row().width('100%').height(CHIPS_RESERVE_H)
          }
          ForEach(this.favorites.favorites, (e: Episode) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: e,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === e.id,
                isPlaying: this.player.isPlaying,
                played: this.history.isPlayed(e.id),
                onPlay: () => this.onPlayEpisode(e, this.favorites.favorites),
                showFavorite: true,
                isFavorite: this.favorites.isFavorite(e.id),
                onToggleFavorite: () => { this.favorites.toggle(e); },
                onPlayNext: () => { this.player.playNext(e); },
                onEnqueue: () => { this.player.enqueue(e); }
              })
            }
          }, (e: Episode) => e.id)
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  // ── 下载 ──
  @Builder
  downloadsSection() {
    Column() {
      if (this.downloads.downloads.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('empty_downloads') })
      } else {
        List() {
          // 顶部占位:理由见订阅段同名注释
          ListItem() {
            Row().width('100%').height(CHIPS_RESERVE_H)
          }
          ForEach(this.downloads.downloads, (d: DownloadRow) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: d.episode,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === d.episode.id,
                isPlaying: this.player.isPlaying,
                played: this.history.isPlayed(d.episode.id),
                downloadState: 2,
                onPlay: () => this.onPlayEpisode(d.episode, this.downloadEpisodes()),
                onDeleteDownload: () => { this.downloadManager.delete(d.episode.id); },
                onPlayNext: () => { this.player.playNext(d.episode); },
                onEnqueue: () => { this.player.enqueue(d.episode); }
              })
            }
          }, (d: DownloadRow) => d.episode.id)
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  private downloadEpisodes(): Episode[] {
    return this.downloads.downloads.map((d: DownloadRow) => d.episode);
  }

  // ── 历史 ──
  @Builder
  historySection() {
    Column() {
      if (this.history.history.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('empty_history') })
      } else {
        List() {
          // 顶部占位:理由见订阅段同名注释
          ListItem() {
            Row().width('100%').height(CHIPS_RESERVE_H)
          }
          ForEach(this.history.history, (h: HistoryRow) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: h.episode,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === h.episode.id,
                isPlaying: this.player.isPlaying,
                played: h.played,
                onPlay: () => this.onPlayEpisode(h.episode, this.historyEpisodes()),
                /**
                 * 历史页**必须**给这个开关。发现页「继续收听」卡上的「标记已播完」
                 * 就是把这里的 `played` 置真 —— 那一横条的数据源正是这份历史列表
                 * (未播完 + 进度在 10s~95%)。不在这儿给「标记未播完」,那个动作
                 * 就成了不可撤销的,而 app 里没有撤销机制。
                 * 进度本身不受影响:恢复后它带着原来的位置重新回到横条。
                 * (macOS 的单集右键菜单是无条件带这一项的,这里向它对齐。)
                 */
                showPlayedToggle: true,
                onTogglePlayed: () => { this.history.markPlayed(h.episode.id, !h.played); },
                onPlayNext: () => { this.player.playNext(h.episode); },
                onEnqueue: () => { this.player.enqueue(h.episode); }
              })
            }
          }, (h: HistoryRow) => h.episode.id)
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  private historyEpisodes(): Episode[] {
    return this.history.history.map((h: HistoryRow) => h.episode);
  }
}

/// ForEach 的项类型别名(便于在 UI 里标注类型)。
interface HistoryRow {
  episode: Episode;
  played: boolean;
}

interface DownloadRow {
  episode: Episode;
  localPath: string;
}
