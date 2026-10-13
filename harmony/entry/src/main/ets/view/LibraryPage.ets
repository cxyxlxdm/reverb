import { Scheme, TypeScale, Metrics, Tracking, LineHeight, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Podcast, Episode } from '../model/Models';
import { SettingsStore } from '../store/SettingsStore';
import { SubscriptionStore, FavoriteStore, HistoryStore } from '../store/Stores';
import { DownloadStore } from '../store/DownloadStore';
import { DownloadManager } from '../playback/DownloadManager';
import { NoteStore, EpisodeNote } from '../store/NoteStore';
import { PlayerController } from '../playback/PlayerController';
import { ScreenHeader, EmptyHint, Glyph, Sym, Artwork } from './Widgets';
import { PodcastListItem, PodcastGridItem, EpisodeListItem, ChipsRow, CHIPS_RESERVE_H, ChipsSwipeSync, PlayModeButton, ConfirmDialog, ConfirmSpec, formatTime } from './Components';
import { QueueBody } from './QueuePage';

/**
 * 音阁两段的「列身份」。与 Android `LibraryScreen.kt` 的 `TAG_FAV/TAG_DL` 同值。
 * 同一个串用在**两处**:段条右端那颗模式按钮按它读写自己那一格,
 * 段内某一行起播时把它随 `playQueue` 传下去(装机日志里 `tag='…'` 读到的就是它)。
 * 两边必须是同一个值 —— 否则「在这一列设的模式」和「这一列起播时用的模式」各走各的,
 * 而且不会报错,只会表现成"设了没生效"。
 *
 * 频道主页用的是 `"podcast:" + (feedUrl 或频道名)`,那个前缀保证它撞不上这些。
 *
 * 「最新」那一列的 `TAG_INBOX` 不在这里了:2026-10-08 它提升成顶层「追更」页,
 * 串跟着搬到 `FeedPage.ets`。**值一个字母没改** —— 模式是按这个串存盘的,
 * 改值会让用户设备上已设的那一格静默失效。
 *
 * 「待播」段也**没有列身份串**:这一列就是 `PlayerController.userQueue` 本体,
 * 起播走 `playFromQueue`,模式在播放器身上那一层已经生效。给它挂一颗模式按钮,
 * 它改的会是"另一列的设置"而那一列就是它自己 —— 只是多一个能设错的地方。
 */
const TAG_FAV = 'fav';
const TAG_DL = 'dl';

/**
 * 音阁六段的**序号**。与 Android `LibraryScreen.kt` 的 `SEG_*` 同一组数,段的顺序两端一致。
 *
 * 为什么不写裸数字(见 H164 / H165):分段条右端那颗动作是**按序号**挂的,而序号会随增删段变化 ——
 * 「最新」提升成顶层页那次,若只改 `segments()` 不改判断,历史段就会挂上待播的动作。
 * 具名常量把契约写在名字上:**加一段时改的是这一组数,漏改会立刻在名字对不上的地方露出来**。
 */
const SEG_SUBS: number = 0;
const SEG_FAV: number = 1;
const SEG_DL: number = 2;
const SEG_QUEUE: number = 3;
const SEG_HISTORY: number = 4;
const SEG_NOTES: number = 5;

/// 音阁:订阅 / 收藏 / 下载 / 待播 / 历史 / 批注 六分段。
/// 对应 Android `LibraryScreen.kt`。分段用 chips + Swiper 双向联动。
@Component
export struct LibraryPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 底部栏悬浮后,滚动内容需让出的底部空间(栏 + 手势区 + 播放条,Index 算好传入)。
  /// 只用于各 List 的 contentEndOffset / 宫格的尾部占位行。
  @Prop bottomPad: number = 0;
  /// 滚动量交给外壳,由它决定播放条收不收进底部栏(见 DiscoverPage 同名注释)
  onScrollDy: (dy: number) => void = () => {};
  @ObjectLink player: PlayerController;
  /**
   * 本页渲染用到的 store 一律经 `@ObjectLink` 接收(各 store 均已 `@Observed`,
   * 且都是「复制后整体赋值」,故字段变化能被观察到)。
   *
   * 不要退回 `AppContainer.get().xxx` 直读:那是未被观察的裸对象。本页原先四处交互
   * (宫格切换 / 清空历史 / 删除下载 / 「最新」刷新完成)都没有任何本地状态变化,
   * 于是点了界面不动;偶尔看着正常,是切分段或播放状态 tick 顺带刷新的。详见 H27。
   *
   * `inbox` 已经不在这儿了:2026-10-08「最新」提升成顶层「追更」页(`FeedPage.ets`),
   * 音阁换进的是「待播」—— 那份数据在 `player.userQueue` 上,player 本来就是 @ObjectLink。
   */
  @ObjectLink settings: SettingsStore;
  @ObjectLink subscriptions: SubscriptionStore;
  @ObjectLink favorites: FavoriteStore;
  @ObjectLink downloads: DownloadStore;
  @ObjectLink history: HistoryStore;
  @ObjectLink notes: NoteStore;
  @ObjectLink downloadManager: DownloadManager;
  onOpenPodcast: (p: Podcast) => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[], tag: string) => void = () => {};
  /// 批注行:从**那一秒**起播(由 Index 走 `player.playAt`,与 `onPlayEpisode` 不是一条路)
  onPlayNote: (n: EpisodeNote) => void = () => {};
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
  /// 待确认的「删除某集下载」(非 null 即弹框)。null 表示没在确认。
  @State pendingDelete: ConfirmSpec | null = null;
  /// 待确认的「清空某一段」(历史 / 待播)。与 pendingDelete 分开两颗,是因为两者的
  /// 确认文案与动作不同,而 ConfirmSpec 已经把差异装在自己的四个字段里。
  @State pendingClear: ConfirmSpec | null = null;

  /**
   * 六个分段。与 Android `LibraryScreen` 同序(订阅 / 收藏 / 下载 / 待播 / 历史 / 批注)。
   *
   * 顺序在两端必须一致:`docs/FEATURES.md` 的分栏叙述、分段条右端那颗动作按 `this.seg === N`
   * 判断、以及用户的肌肉记忆都挂在这些序号上。
   *
   * 2026-10-08 这一轮是**净不移位**改的:删掉「最新」把后面全往前顶一位,再把「待播」插在
   * 历史之前把它们顶回来 —— 所以 4=历史、5=批注 和改之前一样,挂在序号上的那两处判断不用动。
   */
  private segments(): string[] {
    return [L.s('lib_subscriptions'), L.s('lib_favorites'), L.s('lib_downloads'),
      L.s('lib_queue'), L.s('lib_history'), L.s('lib_notes')];
  }

  // ── 「最新」的进页刷新已经跟着那一列搬到 `FeedPage.aboutToAppear()` ──
  // (原先挂在音阁,因为那时它是音阁的第 2 段。挂在这儿会让冷启动多建一页、多发一轮请求。)

  build() {
    // 弹确认框时要连页头一起遮住(与 Android 的 AlertDialog 同范围),所以确认框挂在
    // 整页的 Stack 上,而不是挂在分段条那个 Stack 里 —— 后者只覆盖内容区。
    Stack() {
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
            this.favoritesSection()
            this.downloadsSection()
            // 待播段:与独立队列页**同一个组件**(见 `QueuePage.QueueBody`)
            this.queueSection()
            this.historySection()
            this.notesSection()
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

      // 删单集下载的二次确认(见 askDeleteDownload)。null → 非 null 才新建组件,
      // 故 ConfirmDialog 里的 spec 一定拿的是最新值。
      if (this.pendingDelete !== null) {
        ConfirmDialog({
          scheme: this.scheme,
          fontScale: this.fontScale,
          spec: this.pendingDelete,
          onDismiss: () => { this.pendingDelete = null; }
        })
      }

      // 清空历史 / 待播的二次确认(理由见 barActions 里那两颗按钮的注释)
      if (this.pendingClear !== null) {
        ConfirmDialog({
          scheme: this.scheme,
          fontScale: this.fontScale,
          spec: this.pendingClear,
          onDismiss: () => { this.pendingClear = null; }
        })
      }
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
   * 规则与 Android 同:**这一段没内容就不摆动作**(空列表上的"清空 / 排列"点了什么都
   * 不会发生,是个假按钮)。**唯一的例外是播放模式那颗** —— 它改的是这一列的模式设置,
   * 列空着照样能设,下次有内容时起播就按它走。
   * **两端同值**:Android 侧那颗 `TextButton` 的 `contentPadding` 是 start 16 / end 8,
   * 外加 `endAction` 容器自己的 8dp end 内边距 ⇒ 文字离条右缘同样是 16。
   */
  @Builder
  barActions() {
    // ⚠️ **不看订阅数**:Android 侧同一颗按钮的条件只有 `section == 0`,没有"非空才显示"。
    // 这里先前多挂了 `subscriptions.length > 0`,装机表现就是用户反馈的「切到订阅 tab
    // 右侧没有排序方式按钮」—— 一台还没订阅的手机两边行为立刻不一样,而排列方式是全局
    // 设置,空列表时切了下次进来看得到,没有任何理由藏起来。
    if (this.seg === SEG_SUBS) {
      // 与 Android 一致:图标按钮,且**图标表示切换后的目标布局**(当前是宫格就显示"列表")
      Glyph({
        symbol: this.settings.subsGrid ? Sym.list : Sym.grid,
        dim: 20, color: this.scheme.onSurfaceVariant
      })
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .accessibilityText(L.s('subs_layout_toggle'))
        .onClick(() => { this.settings.setSubsGrid(!this.settings.subsGrid); })
    }
    if (this.seg === SEG_QUEUE && this.player.userQueue.length > 0) {
      // 待播段的动作只有「清空」,**没有播放模式那颗**:这一列就是 `player.userQueue` 本体,
      // 起播走 `playFromQueue`,模式(顺序 / 单曲循环 / 随机)在播放器身上那一层已经生效。
      // 给它挂一颗,它改的是"另一列的设置"而那一列就是它自己 —— 只是多一个能设错的地方。
      // 独立队列页(`QueuePage`)标题栏里那颗是同一个动作,两处同源,不会各清各的。
      //
      // 两颗「清空」都**不直接动手**:一刀切且没有找回办法,与设置页里「清空播放历史」
      // 同待遇(那边一直是先确认再清)。两端同口径,Android 侧见 `LibraryScreen.kt` 的 pendingClear。
      Text(L.s('action_clear'))
        .fontSize(TypeScale.labelLarge * this.fontScale)
        .fontColor(this.scheme.primary)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick(() => {
          this.pendingClear = new ConfirmSpec(L.s('queue_title'), L.s('confirm_clear_queue'),
            L.s('action_clear_confirm'), () => this.player.clearQueue());
        })
    }
    if (this.seg === SEG_HISTORY && this.history.history.length > 0) {
      Text(L.s('action_clear'))
        // 字号取 labelLarge 与 Android 那颗 TextButton 同档(原先是 caption,比另一端小一号)
        .fontSize(TypeScale.labelLarge * this.fontScale)
        .fontColor(this.scheme.primary)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick(() => {
          this.pendingClear = new ConfirmSpec(L.s('set_clear_history'), L.s('confirm_clear_history'),
            L.s('action_clear_confirm'), () => this.history.clear());
        })
    }
    /**
     * 两段单集列表(收藏 / 下载):一颗**本列的播放模式按钮**。
     * 三态图标与点击口径收在 `Components.PlayModeButton`
     * (频道主页「全 N 集」那一行右端与顶层「追更」页用的是同一颗)。
     * 两段**各有一份**模式,所以这里传的是**这一段自己的** tag ⇒ 两段看到两个值。
     *
     * 原先这里有三段(最新 / 收藏 / 下载):「最新」那段 2026-10-08 提升成顶层页,
     * 它的模式按钮跟着搬到 `FeedPage` 的标题栏右端,功能没有因为搬家丢掉。
     */
    if (this.seg === SEG_FAV) {
      PlayModeButton({ scheme: this.scheme, player: this.player, tag: TAG_FAV })
    }
    if (this.seg === SEG_DL) {
      PlayModeButton({ scheme: this.scheme, player: this.player, tag: TAG_DL })
    }
    /**
     * 第 6 段(批注)**刻意没有动作**,不是漏做:
     *  · 不放播放模式那颗 —— 批注是跨集的时间线,点一行只把**那一集**放进队列
     *    (`playAt`),没有"这一列接下来播什么"可言,模式按钮在这里没有作用对象;
     *  · 不放「清空」—— 那是用户自己写的字,批量删除一刀切下去没有任何找回办法。
     *    `NoteStore` 也刻意没有 `clear()`(与 HistoryStore 有 clear 相对)。
     * 装机时别把它当成缺的一项补回来。
     */
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
        .accessibilityText(L.s('listen_stats_title'))
        .onClick(() => this.onOpenListenStats())
      Glyph({ symbol: Sym.settings, dim: 22, color: this.scheme.onSurfaceVariant })
        .accessibilityText(L.s('action_settings'))
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
          // 顶部占位**一整行**:给玻璃分段条让出余量(宫格用不了 List 的 contentStartOffset)。
          // 个数取 SUBS_GRID_COLS —— 单个 GridItem 只占一格,不占满一行就等于没让位(见该常量注释)。
          ForEach(subsGridSpacers(), (_p: number, i: number) => {
            GridItem() {
              Row().width('100%').height(CHIPS_RESERVE_H)
            }
          }, (_p: number, i: number) => `head${i}`)
          ForEach(this.subscriptions.subscriptions, (p: Podcast) => {
            GridItem() {
              PodcastGridItem({
                scheme: this.scheme, fontScale: this.fontScale, podcast: p,
                onTap: () => this.onOpenPodcast(p)
              })
            }
          }, (p: Podcast) => p.feedUrl)
          // 尾部占位**一整行**:给玻璃栏底下留滚动余量(宫格用不了 List 的 contentEndOffset)。
          // 同理,只占一格时它和最后一行封面挤在同一行,那一行的行高被撑成 bottomPad,
          // 末行下方拖出一大块空白。
          if (this.bottomPad > 0) {
            ForEach(subsGridSpacers(), (_p: number, i: number) => {
              GridItem() {
                Row().width('100%').height(this.bottomPad)
              }
            }, (_p: number, i: number) => `tail${i}`)
          }
        }
        .columnsTemplate(subsGridTemplate())
        .columnsGap(Metrics.gridSpacing)
        .rowsGap(Metrics.gridSpacing + 4)
        // **top 必须给** —— 原先只写了 left/right/bottom,于是第一行封面紧贴上方的分段 chips。
        // 列表分支之所以没暴露这个问题,是因为它靠每个 PodcastListItem 自带的 `top: 10` 撑开;
        // 宫格里没有那层内边距,不给就是零。10 + chips 行自身下方约 7 的余量 ≈ Android 实测的 16.5dp。
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 20 })
        // Grid 没有 contentEndOffset(List 专属 API):滚动余量靠上面的尾部占位 GridItem
        .scrollBar(BarState.Off)
        .onDidScroll((dy: number, _st: ScrollState): void => this.onScrollDy(dy))
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
        .onDidScroll((dy: number, _st: ScrollState): void => this.onScrollDy(dy))
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  // ── 待播(手动排的接下来播放列表)──
  @Builder
  queueSection() {
    // 与独立队列页共用 `QueuePage.QueueBody`,所以这里只补两件事:
    // 顶出一行给悬浮分段条让位(chipReserve),底部让出玻璃 tab 栏的空间(bottomPad)。
    Column() {
      QueueBody({
        scheme: this.scheme, fontScale: this.fontScale, player: this.player,
        bottomPad: this.bottomPad, chipReserve: true
      })
    }
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
                onPlay: () => this.onPlayEpisode(e, this.favorites.favorites, TAG_FAV),
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
        .onDidScroll((dy: number, _st: ScrollState): void => this.onScrollDy(dy))
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
                onPlay: () => this.onPlayEpisode(d.episode, this.downloadEpisodes(), TAG_DL),
                onDeleteDownload: () => { this.askDeleteDownload(d.episode); },
                onPlayNext: () => { this.player.playNext(d.episode); },
                onEnqueue: () => { this.player.enqueue(d.episode); }
              })
            }
          }, (d: DownloadRow) => d.episode.id)
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .onDidScroll((dy: number, _st: ScrollState): void => this.onScrollDy(dy))
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  private downloadEpisodes(): Episode[] {
    return this.downloads.downloads.map((d: DownloadRow) => d.episode);
  }

  /**
   * 删掉一集已下载的单集之前先确认。
   *
   * 这一删是**不可逆**的:文件是用户花流量、有时还要等一会儿才拿到的,删了只能重下,
   * 而 app 里没有撤销。原先点一下图标当场就删了(装机反馈「删除下载前没有确认提示」)。
   * Android 侧「音阁 · 下载」早有这个确认框(`LibraryScreen.kt` 的 pendingDelete),
   * `docs/FEATURES.md` 也一直写着「删除有二次确认 · 两端一致」—— 鸿蒙这边是漏的那一端。
   * 文案与 Android 同源:`download_delete_title` / `download_delete_message(集名)`。
   */
  private askDeleteDownload(ep: Episode): void {
    this.pendingDelete = new ConfirmSpec(
      L.s('download_delete_title'),
      L.f('download_delete_message', ep.title),
      L.s('action_delete'),
      () => { this.downloadManager.delete(ep.id); }
    );
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
                onPlay: () => this.onPlayEpisode(h.episode, this.historyEpisodes(), ''),
                /**
                 * 历史页**必须**给这个开关。发现页「继续收听」卡上的「标记已播完」
                 * 就是把这里的 `played` 置真 —— 那一横条的数据源正是这份历史列表
                 * (未播完 + 进度在 10s~95%)。不在这儿给「标记未播完」,那个动作
                 * 就成了不可撤销的,而 app 里没有撤销机制。
                 * 进度本身不受影响:恢复后它带着原来的位置重新回到横条。
                 * (macOS 的单集右键菜单是无条件带这一项的,这里向它对齐。)
                 */
                showPlayedToggle: true,
                // 读 store 而不是 `!h.played`:闭包里的 `h` 是**生成这一行那一刻**的快照,
                // 而快照会过期(见下面键值的注释)。动作要拿当前值,只能回 store 问一次。
                // 这里是**一次点击**问一次,不在渲染路径上,`isPlayed` 的整表扫描可以接受。
                onTogglePlayed: () => { this.history.markPlayed(h.episode.id, !this.history.isPlayed(h.episode.id)); },
                onPlayNext: () => { this.player.playNext(h.episode); },
                onEnqueue: () => { this.player.enqueue(h.episode); }
              })
            }
          }, (h: HistoryRow) => `${h.episode.id}|${h.played ? 1 : 0}`)
          /**
           * 键值里必须带 `played`,否则长按菜单点「标记已播完」之后**这一行原地不动**:
           * store 那边数组整个换了新的(每项都是新建对象),`@ObjectLink` 也确实通知了本页,
           * 但 ForEach 按**键值**决定要不要重跑 itemGenerator —— 键没变就不重跑,
           * 于是从迭代项身上取的那些参数(`h.played`、`h.episode`)一律停在创建那一刻。
           *
           * ⚠️ 同一行里 `isPlaying` 却是会变的,别被这个误导成"个别字段坏了":
           * 它读的是**另一个** @Observed 对象(`this.player`),走的是属性级订阅那条路,
           * 不经过 ForEach 的键值判断。规律是「**从被迭代的那个数组里取的字段,
           * 改了不会就地刷新;从别的被观察对象取的会**」。真机两侧都量过,见 H154。
           *
           * 代价只有"点一下标记,这一行重建一次",而重建正是我们要的效果。
           * 不改成"从 store 读 `played`"来绕:那个值仍然来自同一个数组,同样不刷新,
           * 还额外给每一行加一次整表扫描(≤100 行 × O(n),渲染路径上不做解析——硬规矩 6)。
           */
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .onDidScroll((dy: number, _st: ScrollState): void => this.onScrollDy(dy))
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  private historyEpisodes(): Episode[] {
    return this.history.history.map((h: HistoryRow) => h.episode);
  }

  // ── 批注 ──
  /**
   * 全局批注时间线:所有集的批注按**书写时间**倒排,新写的置顶。
   *
   * 为什么不是按单集分组、也不是按 `positionMs` 排:这个列表要回答的是
   * "我都在哪些时刻停下来写过话",那正是书写时刻的顺序;分组会把刚写的那条埋进某一集里。
   */
  @Builder
  notesSection() {
    Column() {
      if (this.notes.notes.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('note_empty') })
      } else {
        List() {
          // 顶部占位:理由见订阅段同名注释
          ListItem() {
            Row().width('100%').height(CHIPS_RESERVE_H)
          }
          ForEach(this.notes.notes, (n: EpisodeNote) => {
            ListItem() {
              this.noteRowItem(n)
            }
          }, (n: EpisodeNote) => n.noteId)
        }
        .scrollBar(BarState.Off)
        .contentEndOffset(this.bottomPad)
        .onDidScroll((dy: number, _st: ScrollState): void => this.onScrollDy(dy))
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  /**
   * 一行批注:封面(叠播放态)+ 自己写的那句话 + 那一秒的徽标 + 所属单集名 + 行末删除。
   *
   * 字号取本端的 `TypeScale.body`(14vp)而不是数值上的 16 —— 与其余各段的**主行**同档
   * (见 `EpisodeListItem` 那条"正文号对齐 Android bodyLarge"的注释:1vp ≈ 1.18 标准 dp,
   * 14vp 占屏与 16sp 相等)。照数值抄会让这一段的行比另五段大一圈。
   */
  @Builder
  noteRowItem(n: EpisodeNote) {
    Row({ space: 12 }) {
      Stack() {
        Artwork({ scheme: this.scheme, url: n.episode.artworkUrl, dim: 52, corner: 10 })
        Row()
          .width(52).height(52)
          .borderRadius(10)
          .backgroundColor(withAlpha('#000000', this.isNoteCurrent(n) ? 0.42 : 0.28))
        Glyph({
          symbol: this.isNoteCurrent(n) && this.player.isPlaying ? Sym.pauseFill : Sym.playFill,
          dim: 24, color: Color.White
        })
          .accessibilityText(this.isNoteCurrent(n) && this.player.isPlaying
            ? L.s('a11y_pause') : L.s('a11y_play'))
      }
      .width(52).height(52)

      Column({ space: 4 }) {
        Text(n.text)
          .fontSize(TypeScale.body * this.fontScale)
          .letterSpacing(Tracking.body)
          .lineHeight(TypeScale.body * this.fontScale * LineHeight.body)
          .fontColor(this.scheme.onBackground)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          // 那一秒:primary 低饱和底 + primary 字,与时间徽标在 Android 同一形态。
          // 它是这一行的**语义核心**(功能就叫"写下这一秒"),所以不能用灰字。
          Text(formatTime(n.positionMs))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.primary)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(withAlpha(this.scheme.primary, 0.12))
            .borderRadius(6)
          Text(n.episode.title)
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 行末删除。图标名取自 SDK 系统资源表(见 Widgets.Sym.noteDelete),
      // 命中区外扩到 36 见方、并截断冒泡 —— 否则这点触摸会被"点行播放"吃掉。
      Glyph({ symbol: Sym.noteDelete, dim: 20, color: this.scheme.onSurfaceVariant })
        .accessibilityText(L.s('a11y_note_delete'))
        .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
        .onTouch((event: TouchEvent) => event.stopPropagation())
        .onClick(() => { this.askDeleteNote(n); })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Top)
    .onClick(() => this.onPlayNote(n))
  }

  private isNoteCurrent(n: EpisodeNote): boolean {
    return this.player.current !== null && this.player.current.id === n.episode.id;
  }

  /**
   * 删一条批注前先确认,**并把被删的那句话写进正文**。
   *
   * 与「删除下载」同一口径(那边装机反馈过"没有确认提示")。这里更进一步:
   * 批注是用户自己写的字,删掉没有任何东西能补回来,而列表里同时躺着好几条形似的短句 ——
   * 只问"确定删除这条批注吗"不够,框里必须看得见要消失的是哪句话。
   */
  private askDeleteNote(n: EpisodeNote): void {
    this.pendingDelete = new ConfirmSpec(
      L.s('note_delete_title'),
      L.f('note_delete_message', n.text),
      L.s('action_delete'),
      () => { this.notes.remove(n.noteId); }
    );
  }
}

/// 音阁 · 订阅宫格的列数。
///
/// **它同时决定了占位项的个数** —— ArkUI 的 `GridItem` 没有 span(Compose 有
/// `GridItemSpan(maxLineSpan)`),一个占位项只吃掉**一格**。只放一格占位时,真实封面
/// 会从第二格开始排,装机实测两个后果:①首行少一张封面、整排右移一格;
/// ②首行顶在 Grid 的 `padding.top`(10vp)处,被上方 44vp 高的玻璃分段条盖掉半张封面
/// (就是用户报的「宫格第一行上半部分被盖住」——占位项在它左边那一格,并没有把它顶下去)。
/// 所以头/尾的占位必须凑满一整行:改列数就在这里改,别只改 `columnsTemplate`。
const SUBS_GRID_COLS = 3;

/// `'1fr 1fr 1fr'` —— 由 SUBS_GRID_COLS 生成,免得模板与占位个数两处各写一份。
function subsGridTemplate(): string {
  const parts: string[] = [];
  for (let i = 0; i < SUBS_GRID_COLS; i++) {
    parts.push('1fr');
  }
  return parts.join(' ');
}

/// 一整行的占位项(下标只用来当 ForEach 的 key)。
function subsGridSpacers(): number[] {
  const out: number[] = [];
  for (let i = 0; i < SUBS_GRID_COLS; i++) {
    out.push(i);
  }
  return out;
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
