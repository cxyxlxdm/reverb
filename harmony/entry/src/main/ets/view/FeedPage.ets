import { Scheme } from '../theme/Theme';
import { L } from '../util/L';
import { Episode } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { SubscriptionStore, HistoryStore } from '../store/Stores';
import { InboxStore } from '../store/InboxStore';
import { PlayerController } from '../playback/PlayerController';
import { ScreenHeader, EmptyHint, LoadingBox } from './Widgets';
import { EpisodeListItem, PlayModeButton } from './Components';
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
  /// 滚动量交给外壳,由它决定播放条收不收进底部栏(见 DiscoverPage 同名注释)
  onScrollDy: (dy: number) => void = () => {};
  /**
   * store 一律 `@ObjectLink` 接收,不要退回 `this.app.xxx` 直读 ——
   * 裸对象字段变了界面不重渲(这条坑记在 H26 / H27,音阁那四处交互就是它)。
   */
  @ObjectLink player: PlayerController;
  @ObjectLink inbox: InboxStore;
  @ObjectLink subscriptions: SubscriptionStore;
  @ObjectLink history: HistoryStore;
  onPlayEpisode: (e: Episode, queue: Episode[], tag: string) => void = () => {};

  private app: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    // 进页即按需刷新(订阅集未变则跳过,避免切 tab 反复全量刷)。
    // 原先这笔刷新挂在**音阁**的 aboutToAppear 上,因为那时「最新」是音阁的第 2 段;
    // 段搬成页之后,刷新跟着这一页走 —— 冷启动不建这页就不会发请求。
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

  build() {
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
            List() {
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
                    onEnqueue: () => { this.player.enqueue(e); }
                  })
                }
              }, (e: Episode) => e.id)
            }
            .scrollBar(BarState.Off)
            // 顶部不再需要 CHIPS_RESERVE_H 占位行:那一层是给悬浮的**分段条**让位的,
            // 这一页没有分段条,页头已经把它压在下面。底部照旧让给玻璃栏。
            .contentEndOffset(this.bottomPad)
            .onDidScroll((dy: number, _st: ScrollState): void => this.onScrollDy(dy))
            .width('100%').height('100%')
          }
        }
        .width('100%').height('100%')
      }
      .onRefreshing(() => { this.refreshInbox(true); })
      .layoutWeight(1)
    }
    .width('100%').height('100%')
  }

  @Builder
  modeAction() {
    PlayModeButton({ scheme: this.scheme, player: this.player, tag: TAG_INBOX })
  }
}
