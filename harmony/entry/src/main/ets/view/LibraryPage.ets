import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { Podcast, Episode } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { PlayerController } from '../playback/PlayerController';
import { ScreenHeader, EmptyHint, LoadingBox } from './Widgets';
import { PodcastListItem, PodcastGridItem, EpisodeListItem, ChipsRow } from './Components';
import { Log } from '../util/Logger';

/// 音阁:订阅 / 最新 / 收藏 / 历史 四分段(下载段留后续轮次)。
/// 对应 Android `LibraryScreen.kt`。分段用 chips + Swiper 双向联动。
@Component
export struct LibraryPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @ObjectLink player: PlayerController;
  onOpenPodcast: (p: Podcast) => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[]) => void = () => {};
  onOpenSettings: () => void = () => {};
  onOpenListenStats: () => void = () => {};

  @State seg: number = 0;
  @State inboxRefreshing: boolean = false;

  private app: AppContainer = AppContainer.get();
  private segments: string[] = ['订阅', '最新', '收藏', '下载', '历史'];

  aboutToAppear(): void {
    // 进音阁即按需刷新「最新」(订阅集未变则跳过,避免切 tab 反复全量刷)
    this.refreshInbox(false);
  }

  /// 刷新「最新」。loading 状态由 store 自己持有(inbox.refreshing):
  /// 若用本地标志,被重入拒绝的那次调用会把转圈提前关掉——Android 上踩过这个坑。
  private async refreshInbox(force: boolean): Promise<void> {
    const subs = this.app.subscriptions.subscriptions;
    if (subs.length === 0) return;
    if (force) await this.app.inbox.refresh(subs, this.app.repository);
    else await this.app.inbox.refreshIfStale(subs, this.app.repository);
    this.inboxRefreshing = false;
    Log.i('Library', `最新:当前 ${this.app.inbox.episodes.length} 条`);
  }

  build() {
    Column() {
      ScreenHeader({
        scheme: this.scheme,
        fontScale: this.fontScale,
        title: '音阁',
        action: () => { this.headerActions() }
      })

      // 分段 chips(订阅段右侧浮动"行/宫格"切换、历史段浮动"清空")
      Stack({ alignContent: Alignment.End }) {
        ChipsRow({
          scheme: this.scheme,
          fontScale: this.fontScale,
          labels: this.segments,
          selected: this.seg,
          onSelect: (i: number) => { this.seg = i; }
        })
        if (this.seg === 0 && this.app.subscriptions.subscriptions.length > 0) {
          Text(this.app.settings.subsGrid ? '列表' : '宫格')
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.primary)
            .padding({ left: 10, right: Metrics.pagePadding, top: 4, bottom: 4 })
            .backgroundColor(this.scheme.background)
            .onClick(() => { this.app.settings.setSubsGrid(!this.app.settings.subsGrid); })
        }
        if (this.seg === 4 && this.app.history.history.length > 0) {
          Text('清空')
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.primary)
            .padding({ left: 10, right: Metrics.pagePadding, top: 4, bottom: 4 })
            .backgroundColor(this.scheme.background)
            .onClick(() => { this.app.history.clear(); })
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

  @Builder
  headerActions() {
    Row({ space: 14 }) {
      // 收听时长
      Image($r('sys.media.ohos_ic_public_device_sound_filled'))
        .width(21).height(21)
        .fillColor(this.scheme.onSurfaceVariant)
        .onClick(() => this.onOpenListenStats())
      Image($r('sys.media.ohos_ic_public_more'))
        .width(22).height(22)
        .fillColor(this.scheme.onSurfaceVariant)
        .onClick(() => this.onOpenSettings())
    }
  }

  // ── 订阅 ──
  @Builder
  subscriptionsSection() {
    Column() {
      if (this.app.subscriptions.subscriptions.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '还没有订阅任何节目' })
      } else if (this.app.settings.subsGrid) {
        Scroll() {
          Grid() {
            ForEach(this.app.subscriptions.subscriptions, (p: Podcast) => {
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
          .height(Math.ceil(this.app.subscriptions.subscriptions.length / 2) * 230 + 20)
        }
        .scrollBar(BarState.Off)
        .width('100%').height('100%').align(Alignment.Top)
      } else {
        List() {
          ForEach(this.app.subscriptions.subscriptions, (p: Podcast) => {
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
    Refresh({ refreshing: this.app.inbox.refreshing }) {
      Column() {
        if (this.app.subscriptions.subscriptions.length === 0) {
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '订阅节目后,这里汇总最新单集' })
        } else if (this.app.inbox.episodes.length === 0) {
          if (this.app.inbox.refreshing) {
            LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
          } else {
            EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '暂时没有更新,下拉重试' })
          }
        } else {
          List() {
            ForEach(this.app.inbox.episodes, (e: Episode) => {
              ListItem() {
                EpisodeListItem({
                  scheme: this.scheme, fontScale: this.fontScale, episode: e,
                  showPodcastTitle: true,
                  isCurrent: this.player.current !== null && this.player.current.id === e.id,
                  isPlaying: this.player.isPlaying,
                  played: this.app.history.isPlayed(e.id),
                  onPlay: () => this.onPlayEpisode(e, this.app.inbox.episodes)
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
      if (this.app.favorites.favorites.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '还没有收藏的单集' })
      } else {
        List() {
          ForEach(this.app.favorites.favorites, (e: Episode) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: e,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === e.id,
                isPlaying: this.player.isPlaying,
                played: this.app.history.isPlayed(e.id),
                onPlay: () => this.onPlayEpisode(e, this.app.favorites.favorites)
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
      if (this.app.downloads.downloads.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '还没有离线下载的单集' })
      } else {
        List() {
          ForEach(this.app.downloads.downloads, (d: DownloadRow) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme, fontScale: this.fontScale, episode: d.episode,
                showPodcastTitle: true,
                isCurrent: this.player.current !== null && this.player.current.id === d.episode.id,
                isPlaying: this.player.isPlaying,
                played: this.app.history.isPlayed(d.episode.id),
                downloadState: 2,
                onPlay: () => this.onPlayEpisode(d.episode, this.downloadEpisodes()),
                onDeleteDownload: () => { this.app.downloadManager.delete(d.episode.id); }
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
    return this.app.downloads.downloads.map((d: DownloadRow) => d.episode);
  }

  // ── 历史 ──
  @Builder
  historySection() {
    Column() {
      if (this.app.history.history.length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '暂无播放历史' })
      } else {
        List() {
          ForEach(this.app.history.history, (h: HistoryRow) => {
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
    return this.app.history.history.map((h: HistoryRow) => h.episode);
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
