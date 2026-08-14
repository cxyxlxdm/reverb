import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
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
import { PodcastListItem, PodcastGridItem, EpisodeListItem, ChipsRow } from './Components';
import { Log } from '../util/Logger';

/// 音阁:订阅 / 最新 / 收藏 / 历史 四分段(下载段留后续轮次)。
/// 对应 Android `LibraryScreen.kt`。分段用 chips + Swiper 双向联动。
@Component
export struct LibraryPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
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

      // 分段 chips(订阅段右侧浮动"行/宫格"切换、历史段浮动"清空")
      Stack({ alignContent: Alignment.End }) {
        ChipsRow({
          scheme: this.scheme,
          fontScale: this.fontScale,
          labels: this.segments(),
          selected: this.seg,
          onSelect: (i: number) => { this.seg = i; }
        })
        if (this.seg === 0 && this.subscriptions.subscriptions.length > 0) {
          // 与 Android 一致:图标按钮,且**图标表示切换后的目标布局**(当前是宫格就显示"列表")
          Glyph({
            symbol: this.settings.subsGrid ? Sym.list : Sym.grid,
            dim: 20, color: this.scheme.onSurfaceVariant
          })
            .padding({ left: 10, right: Metrics.pagePadding, top: 4, bottom: 4 })
            .backgroundColor(this.scheme.background)
            .onClick(() => { this.settings.setSubsGrid(!this.settings.subsGrid); })
        }
        if (this.seg === 4 && this.history.history.length > 0) {
          Text(L.s('action_clear'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.primary)
            .padding({ left: 10, right: Metrics.pagePadding, top: 4, bottom: 4 })
            .backgroundColor(this.scheme.background)
            .onClick(() => { this.history.clear(); })
        }
      }
      .width('100%')

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
      .onChange((i: number) => { this.seg = i; })
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
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
        Scroll() {
          Grid() {
            ForEach(this.subscriptions.subscriptions, (p: Podcast) => {
              GridItem() {
                PodcastGridItem({
                  scheme: this.scheme, fontScale: this.fontScale, podcast: p,
                  onTap: () => this.onOpenPodcast(p)
                })
              }
            }, (p: Podcast) => p.feedUrl)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(Metrics.gridSpacing)
          .rowsGap(Metrics.gridSpacing + 4)
          .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 20 })
          .height(Math.ceil(this.subscriptions.subscriptions.length / 2) * 230 + 20)
        }
        .scrollBar(BarState.Off)
        .width('100%').height('100%').align(Alignment.Top)
      } else {
        List() {
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
            ForEach(this.inbox.episodes, (e: Episode) => {
              ListItem() {
                EpisodeListItem({
                  scheme: this.scheme, fontScale: this.fontScale, episode: e,
                  showPodcastTitle: true,
                  isCurrent: this.player.current !== null && this.player.current.id === e.id,
                  isPlaying: this.player.isPlaying,
                  played: this.history.isPlayed(e.id),
                  onPlay: () => this.onPlayEpisode(e, this.inbox.episodes)
                })
              }
            }, (e: Episode) => e.id)
          }
          .scrollBar(BarState.Off)
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
          ForEach(this.favorites.favorites, (e: Episode) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: e,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === e.id,
                isPlaying: this.player.isPlaying,
                played: this.history.isPlayed(e.id),
                onPlay: () => this.onPlayEpisode(e, this.favorites.favorites)
              })
            }
          }, (e: Episode) => e.id)
        }
        .scrollBar(BarState.Off)
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
                onDeleteDownload: () => { this.downloadManager.delete(d.episode.id); }
              })
            }
          }, (d: DownloadRow) => d.episode.id)
        }
        .scrollBar(BarState.Off)
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
          ForEach(this.history.history, (h: HistoryRow) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: h.episode,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === h.episode.id,
                isPlaying: this.player.isPlaying,
                played: h.played,
                onPlay: () => this.onPlayEpisode(h.episode, this.historyEpisodes())
              })
            }
          }, (h: HistoryRow) => h.episode.id)
        }
        .scrollBar(BarState.Off)
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
