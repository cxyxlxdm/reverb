import { Scheme } from '../theme/Theme';
import { L } from '../util/L';
import { Episode } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { SubscriptionStore, HistoryStore } from '../store/Stores';
import { InboxStore } from '../store/InboxStore';
import { PlayerController } from '../playback/PlayerController';
import { ScreenHeader, EmptyHint, LoadingBox } from './Widgets';
import { EpisodeListItem, PlayModeButton, EpisodeBatchBar, BATCH_BAR_GAP, BATCH_AVOID, batchEnqueueAndToast } from './Components';
import { Log } from '../util/Logger';

/**
 * 「追更」这一列的身份串。**值是从音阁那段原样搬过来的**(2026-10-08 那一列提升成顶层页),
 * 与 Android `InboxScreen.kt` 的 `TAG_INBOX` 同值。
 *
 * 同一个串用在**两处**:标题栏右端那颗模式按钮按它读写自己那一格,
 * 列表里某一行起播时把它随队列传下去(装机日志里 `tag='…'` 读到的就是它)。
 * 两边必须是同一个值 —— 否则「在这一列设的模式」和「这一列起播时用的模式」各走各的,
 * 而且不报错,只表现成"设了没生效"。
 *
 * ⚠️ **不能改值**:播放模式是按这个串存盘的,改了会让用户设备上已设的那一格静默失效。
 */
const TAG_INBOX = 'inbox';

/// 顶层「追更」页 = 标题栏 + 全部订阅的**全部单集**(2026-10-10 起 store 内存侧不再截断)。
/// 对应 Android `InboxScreen.kt` 的 `FeedScreen` + `InboxBody`。
///
/// 为什么从音阁的一个分段提上来:内容是"订阅频道播过的集",是每天打开 App 要看的第一眼,
/// 原先却埋在音阁六个分段里、要靠横滑才够得着。
///
/// ⚠️ 发现页首屏那一节「最新更新」(`DiscoverPage.homeFeed`)读的是**同一个 InboxStore**,
/// 但只铺最新 `HOME_LATEST_MAX` 条 —— 那一节是"打开就看到"的预览(且它下面还挂着导入入口,
/// 全量会把那行顶到够不着的地方),这一页才是这一列自己的管理入口(标题栏那颗按钮按 `TAG_INBOX`
/// 存这一列的播放模式,那一节起播不带 tag、因此读不到这个模式)。
///
/// 渲染规模:这里用的是 `List` + `ForEach` 而不是 `LazyForEach`。看着像 bug,但
/// **H137 那一条已经用真机否掉过"ForEach 会整表实化"** —— 1400 句稿的逐字稿页 `dumpLayout`
/// 只数到 15 个稿行节点,即 `List` 里的 `ForEach` 只建可见行。所以几千行不需要引入工程内
/// 0 先例的 `LazyForEach`;真机若在这页量出与节点数不符的成本,再按那一页重算(判据写进 ROADMAP)。
@Component
export struct FeedPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 底部栏悬浮,列表要让出的空间(与音阁/发现同一口径,Index 算好传入)
  @Prop bottomPad: number = 0;
  /**
   * 双击底部「追更」格回顶的触发器(Index 递增,见那里的 `onTabBarClick`)。
   * 只认"变了":首次挂载时 `@Watch` 不会回调,所以不需要挡第一趟。
   */
  @Prop @Watch('onScrollTopToken') scrollTopToken: number = 0;
  /// 滚动量交给外壳,由它决定播放条收不收进底部栏(见 DiscoverPage 同名注释)
  onScrollDy: (dy: number, st: ScrollState) => void = () => {};
  /**
   * store 一律 `@ObjectLink` 接收,不要退回 `this.app.xxx` 直读 ——
   * 裸对象字段变了界面不重渲(这条坑记在 H26 / H27,音阁那四处交互就是它)。
   */
  @ObjectLink player: PlayerController;
  /**
   * 头条一变就回顶。**必须挂在这层 store 上,不能只写在刷新方法里** ——
   * 鸿蒙的页签内容一旦建好就常驻(`aboutToAppear` 只跑一次),所以在别页改了订阅、
   * 或别处刷新了同一个 InboxStore 时,本页没有任何"重新进来"的时机。
   * Android 用 `LaunchedEffect(episodes.firstOrNull()?.id)`、iOS 用 `onChange(of: items.first?.id)`,
   * 两端都是**对 store 变化反应**;这里原先只在 `refreshInbox` 末尾比对,换成别的入口改数据就不回顶
   * (2026-11-09 装机发现:退订后回追更,列表既没去掉那一档、也没回顶)。
   */
  @ObjectLink @Watch('onInboxChanged') inbox: InboxStore;
  /**
   * 订阅集变了就重聚合(与 Android `LaunchedEffect(subs)` 同一口径)。
   * 没有这一笔,退订/新订后追更会继续摆着"已退订那一档的单集",直到用户手动下拉 ——
   * 装机实测就是这么摆着的(2026-11-09)。`refreshIfStale` 自带签名判断与防重入,重复触发无害。
   */
  @ObjectLink @Watch('onSubscriptionsChanged') subscriptions: SubscriptionStore;
  @ObjectLink history: HistoryStore;
  onPlayEpisode: (e: Episode, queue: Episode[], tag: string) => void = () => {};
  /**
   * 点封面进这一集所属的频道页。外壳(Index 的三个 tab 那一支)传 `openPodcastByFeed`。
   *
   * ⚠️ 与行上的 `showChannelJump` **成对传**:ArkTS 没有 Android 那个 CompositionLocal,
   * 判据只能写成"开关 + 动作"两个 prop,只开不给就是"看着能点、点了没反应"的假封面。
   */
  onOpenChannel: (feedUrl: string) => void = () => {};

  /**
   * 多选(批量加入待播)的已选集合。**放在这一层而不是行里** —— 「全选」要能一次改整列,
   * 作用域本来就是整列(与 Android `InboxBody` 的 `picked` 同位)。
   *
   * ⚠️ **只走整体替换**(`this.picked = new Set(...)`),不许 `this.picked.add(...)`:
   * ArkUI V1 对 `@State` 上的 Set 是否观察其方法调用没有可靠口径,而赋值一定触发重渲。
   * Android 那份本来就是 immutable Set 的整体替换,两边同形。
   */
  @State picked: Set<string> = new Set();

  private app: AppContainer = AppContainer.get();
  /// 这一页列表的滚动控制器。双击回顶([onScrollTopToken])与「更新了就从顶部看起」
  /// ([onInboxChanged])都靠它,所以必须是字段而不是每次 build 新建。
  private scroller: Scroller = new Scroller();
  /**
   * 上一次看到的头条 id。**在 [aboutToAppear] 里先记基线**,首趟比对才不会把"进页"当"更新":
   * 与 Android 的 `prev == null 时只记不跳` 同一条规矩(那边靠 effect 的初始调用,这边靠显式赋值)。
   */
  private lastHeadId: string = '';

  aboutToAppear(): void {
    this.lastHeadId = this.inbox.episodes.length > 0 ? this.inbox.episodes[0].id : '';
    // 进页即按需刷新(订阅集未变则跳过,避免切 tab 反复全量刷)。
    // 原先这笔刷新挂在**音阁**的 aboutToAppear 上,因为那时「最新」是音阁的第 2 段;
    // 段搬成页之后,刷新跟着这一页走 —— 冷启动不建这页就不会发请求。
    this.refreshInbox(false);
  }

  /**
   * 头条 id 变了 = 真的有新集插到头上 → 回顶,不要把用户晾在"上次打开的位置"
   * (用户 2026-11-09 的反馈)。判据取 id 不取条数:换源/排序变化也可能条数不变而内容全换。
   *
   * 挂 `@Watch` 的理由见 [inbox] 字段注释:清理入口不能只认本页自己发起的那次刷新。
   * `refreshing` 翻转也会进来,但那时 id 没变,自然不动。
   */
  onInboxChanged(): void {
    const head: string = this.inbox.episodes.length > 0 ? this.inbox.episodes[0].id : '';
    if (this.lastHeadId.length > 0 && head.length > 0 && head !== this.lastHeadId) {
      this.scroller.scrollEdge(Edge.Top);
    }
    this.lastHeadId = head;
  }

  /// 订阅集变了 → 重聚合(理由见 [subscriptions] 字段注释)。
  onSubscriptionsChanged(): void {
    this.refreshInbox(false);
  }

  /// 刷新。loading 状态由 store 自己持有(inbox.refreshing):
  /// 若用本地标志,被重入拒绝的那次调用会把转圈提前关掉——Android 上踩过这个坑。
  private async refreshInbox(force: boolean): Promise<void> {
    const subs = this.subscriptions.subscriptions;
    if (subs.length === 0) return;
    if (force) await this.inbox.refresh(subs, this.app.repository);
    else await this.inbox.refreshIfStale(subs, this.app.repository);
    Log.i('Feed', `追更:当前 ${this.inbox.episodes.length} 条`);
  }

  /// 双击底部「追更」→ 回顶(见 [scrollTopToken])。
  onScrollTopToken(): void {
    this.scroller.scrollEdge(Edge.Top);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        ScreenHeader({
          scheme: this.scheme,
          fontScale: this.fontScale,
          title: L.s('nav_feed'),
          // 标题栏右端这颗是**本列的播放模式按钮**。它原先挂在音阁分段条的右端,
          // 搬家不能把功能搬丢:三态图标与点击口径与频道主页、收藏、下载共用同一颗
          // (`Components.PlayModeButton`)。
          action: () => { this.modeAction() }
        })

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
              List({ scroller: this.scroller }) {
                ForEach(this.inbox.episodes, (e: Episode) => {
                  ListItem() {
                    EpisodeListItem({
                      scheme: this.scheme, fontScale: this.fontScale, episode: e,
                      showPodcastTitle: true,
                      isCurrent: this.player.current !== null && this.player.current.id === e.id,
                      isPlaying: this.player.isPlaying,
                      played: this.history.isPlayed(e.id),
                      onPlay: () => this.onPlayEpisode(e, this.inbox.episodes, TAG_INBOX),
                      onPlayNext: () => { this.player.playNext(e); },
                      onEnqueue: () => { this.player.enqueue(e); },
                      showChannelJump: true, onOpenChannel: this.onOpenChannel,
                      showBatch: true,
                      onEnterSelection: () => { this.picked = new Set<string>([e.id]); },
                      selectionMode: this.picked.size > 0,
                      selected: this.picked.has(e.id),
                      onToggleSelect: () => this.togglePick(e.id)
                    })
                  }
                }, (e: Episode) => this.rowKey(e.id))
              }
              .scrollBar(BarState.Off)
              // 顶部不再需要 CHIPS_RESERVE_H 占位行:那一层是给悬浮的**分段条**让位的,
              // 这一页没有分段条,页头已经把它压在下面。底部照旧让给玻璃栏。
              .contentEndOffset(this.endOffset())
              .onDidScroll((dy: number, st: ScrollState): void => this.onScrollDy(dy, st))
              .width('100%').height('100%')
            }
          }
          .width('100%').height('100%')
        }
        .onRefreshing(() => { this.refreshInbox(true); })
        .layoutWeight(1)
      }
      .width('100%').height('100%')

      // 多选浮条。只在非选择态**不组合**(与各段"没内容就不摆动作"同一条规矩),
      // 落点与列表让位量的配对见 `BATCH_AVOID` 的注释 —— 两处都要进。
      if (this.picked.size > 0) {
        EpisodeBatchBar({
          scheme: this.scheme, fontScale: this.fontScale,
          picked: this.picked.size, total: this.inbox.episodes.length,
          onSelectAll: () => this.pickAll(),
          onEnqueue: () => this.enqueuePicked(),
          onExit: () => { this.picked = new Set<string>(); }
        })
          .margin({ bottom: this.bottomPad + BATCH_BAR_GAP })
      }
    }
    .width('100%').height('100%')
  }

  /// 勾选 / 取消一条(整体替换,理由见 `picked` 的注释)。
  private togglePick(id: string): void {
    const next = new Set<string>(this.picked);
    if (next.has(id)) next.delete(id); else next.add(id);
    this.picked = next;
  }

  private pickAll(): void {
    const next = new Set<string>();
    this.inbox.episodes.forEach((e: Episode) => next.add(e.id));
    this.picked = next;
  }

  /// 批量入队 → 提示 → 退出选择态。三步收在 `batchEnqueueAndToast` 里,四个列共用一份口径。
  private enqueuePicked(): void {
    batchEnqueueAndToast(this.getUIContext(), this.inbox.episodes, this.picked);
    this.picked = new Set<string>();
  }

  /**
   * ⚠️ **key 必须带上勾选位**。`ForEach` 在 key 不变时**复用行、不重建**,于是
   * `selected` 这个 @Prop 就不会更新 —— 点勾选没反应。这条坑在本仓库踩过一次
   * (H113:音阁「就地标记已播完」不刷新,修法就是往 key 里拼那个渲染位)。
   */
  private rowKey(id: string): string {
    return `${id}|${this.picked.has(id) ? 1 : 0}`;
  }

  private endOffset(): number {
    return this.bottomPad + (this.picked.size > 0 ? BATCH_AVOID : 0);
  }

  @Builder
  modeAction() {
    PlayModeButton({ scheme: this.scheme, player: this.player, tag: TAG_INBOX })
  }
}
