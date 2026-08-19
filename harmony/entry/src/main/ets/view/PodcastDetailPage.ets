import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { Podcast, Episode, FeedResult } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { SubscriptionStore, HistoryStore } from '../store/Stores';
import { ListenStatsStore } from '../store/ListenStatsStore';
import { DownloadManager } from '../playback/DownloadManager';
import { TopBar, EmptyHint, LoadingBox, Artwork } from './Widgets';
import { EpisodeListItem, formatListenDuration } from './Components';
import { formatCachedAt } from '../util/DateParse';
import { Log } from '../util/Logger';

/// 频道详情:头部(封面/标题/作者/集数/订阅/可展开简介/付费/赞助)+ 单集列表。
/// 对应 Android `PodcastDetailScreen.kt`。
@Component
export struct PodcastDetailPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop seed: Podcast;                  // 列表点进来时已知的频道信息(先渲染,再用 RSS 补全)
  onBack: () => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[]) => void = () => {};

  @State loaded: Podcast | null = null;
  @State episodes: Episode[] = [];
  @State loading: boolean = false;
  @State failed: boolean = false;
  /// 非 0 表示当前内容来自磁盘缓存、联网刷新还没成功(值为缓存落盘时刻),
  /// 据此显示「离线内容 · 上次更新 X」。刷新成功置 0。
  @State staleAt: number = 0;
  @State descExpanded: boolean = false;
  /**
   * 订阅态与下载态**直接从被观察的 store 读**,不再镜像成本地 @State。
   *
   * 原先用 `@State subscribed` 镜像 + `@State dlTick` 自增来"驱动重渲",其中 dlTick
   * **只写从不读** —— ArkUI 按依赖刷新,没有元素依赖它,自增触发不了任何重渲,
   * 下载态能变纯属被别的重渲蹭上。详见 H27。
   */
  @ObjectLink subscriptions: SubscriptionStore;
  @ObjectLink downloadManager: DownloadManager;
  @ObjectLink history: HistoryStore;
  @ObjectLink listenStats: ListenStatsStore;

  private app: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    this.load();
  }

  private isSubscribed(): boolean {
    return this.subscriptions.isSubscribed(this.display().feedUrl);
  }

  /// 该集下载态:已下载 2 / 进行中 1 / 排队 0 / 未下载 3(用 3 表示"可下载")
  private dlState(id: string): number {
    const s = this.downloadManager.stateOf(id);
    if (s === null) return 3;   // 未下载 → 显示「下载」
    return s.state;
  }

  /// 本频道累计收听时长(频道键:feedUrl 优先,回退频道名)。
  private listenedMs(): number {
    const d = this.display();
    const key = d.feedUrl.length > 0 ? d.feedUrl : d.title;
    return this.listenStats.listenedMsFor(key);
  }

  private display(): Podcast {
    return this.loaded === null ? this.seed : this.loaded;
  }

  private async load(): Promise<void> {
    if (this.seed.feedUrl.length === 0) {
      this.failed = true;
      return;
    }
    // 先出缓存:秒开,且断网时也有内容可看
    const cached = this.app.repository.cachedFeed(this.seed.feedUrl);
    if (cached !== null && cached.episodes.length > 0) {
      this.applyFeed(cached);
      this.staleAt = this.app.repository.feedCachedAt(this.seed.feedUrl);
    }
    this.loading = this.episodes.length === 0;
    this.failed = false;
    const feed: FeedResult | null = await this.app.repository.feed(this.seed.feedUrl);
    this.loading = false;
    if (feed === null) {
      // 有缓存就继续展示缓存(仅标为陈旧),只有连缓存都没有才算失败
      this.failed = this.episodes.length === 0;
      Log.w('Detail', `解析失败 ${this.seed.feedUrl}${this.episodes.length > 0 ? ',沿用缓存' : ''}`);
      return;
    }
    this.staleAt = 0;
    this.applyFeed(feed);
    Log.i('Detail', `"${this.display().title}" 共 ${feed.episodes.length} 集`);
  }

  /// 把解析结果落到页面状态。用 RSS 结果补全,但保留列表页已有的封面/标题(RSS 有时缺图)。
  private applyFeed(feed: FeedResult): void {
    const p = feed.podcast;
    if (p.artworkUrl.length === 0) p.artworkUrl = this.seed.artworkUrl;
    if (p.title.length === 0) p.title = this.seed.title;
    if (p.author.length === 0) p.author = this.seed.author;
    p.isPaid = this.seed.isPaid;
    this.loaded = p;
    this.episodes = feed.episodes;
  }

  build() {
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: this.display().title,
        onBack: () => this.onBack()
      })

      if (this.loading && this.episodes.length === 0) {
        LoadingBox({ scheme: this.scheme, fontScale: this.fontScale }).layoutWeight(1)
      } else {
        List() {
          ListItem() {
            this.header()
          }
          // 展示的是缓存、刷新尚未成功 —— 明确告诉用户内容可能不是最新的
          if (this.staleAt > 0) {
            ListItem() {
              Text(L.f('offline_cached_at', formatCachedAt(this.staleAt)))
                .fontSize(TypeScale.caption * this.fontScale)
                .fontColor(this.scheme.onSurfaceVariant)
                .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 2, bottom: 6 })
            }
          }
          if (this.failed && this.episodes.length === 0) {
            ListItem() {
              Column({ space: 12 }) {
                Text(L.s('detail_load_failed'))
                  .fontSize(TypeScale.body * this.fontScale)
                  .fontColor(this.scheme.onSurfaceVariant)
                Button(L.s('action_retry'))
                  .fontSize(TypeScale.label * this.fontScale)
                  .backgroundColor(this.scheme.primary)
                  .fontColor(this.scheme.onPrimary)
                  .onClick(() => this.load())
              }
              .width('100%')
              .padding(30)
            }
          }
          ForEach(this.episodes, (e: Episode) => {
            ListItem() {
              EpisodeListItem({
                scheme: this.scheme,
                fontScale: this.fontScale,
                episode: e,
                played: this.history.isPlayed(e.id),
                downloadState: this.dlState(e.id),
                onPlay: () => this.onPlayEpisode(e, this.episodes),
                onDownload: () => { this.downloadManager.download(e); },
                onDeleteDownload: () => { this.downloadManager.delete(e.id); },
                // 纯动作,不参与本页渲染,直接用容器单例即可(理由同 DiscoverPage)
                onPlayNext: () => { this.app.player.playNext(e); },
                onEnqueue: () => { this.app.player.enqueue(e); }
              })
            }
          }, (e: Episode) => e.id)
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  header() {
    Column({ space: 14 }) {
      Row({ space: 14 }) {
        Artwork({ scheme: this.scheme, url: this.display().artworkUrl, dim: 96, corner: 16 })
        Column({ space: 5 }) {
          Text(this.display().title)
            .fontSize(TypeScale.titleLarge * this.fontScale)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.scheme.onBackground)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.display().author.length > 0) {
            Text(this.display().author)
              .fontSize(TypeScale.label * this.fontScale)
              .fontColor(this.scheme.onSurfaceVariant)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.display().isPaid) {
            Text(L.s('paid_show'))
              .fontSize(TypeScale.caption * this.fontScale)
              .fontColor(this.scheme.secondary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 订阅 / 已订阅
      Button(this.isSubscribed() ? L.s('action_subscribed') : L.s('action_subscribe'))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.isSubscribed() ? this.scheme.primary : this.scheme.onPrimary)
        .backgroundColor(this.isSubscribed() ? Color.Transparent : this.scheme.primary)
        .borderWidth(this.isSubscribed() ? 1 : 0)
        .borderColor(this.scheme.primary)
        .borderRadius(18)
        .height(36)
        .padding({ left: 22, right: 22 })
        .onClick(() => { this.subscriptions.toggle(this.display()); })

      if (this.display().description.length > 0) {
        Column({ space: 4 }) {
          Text(this.display().description)
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .lineHeight(21)
            .maxLines(this.descExpanded ? 100 : 4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.descExpanded ? L.s('action_collapse') : L.s('action_expand'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.primary)
            .onClick(() => { this.descExpanded = !this.descExpanded; })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }

      if (this.listenedMs() > 0) {
        Text(L.f('listened_prefix', formatListenDuration(Math.floor(this.listenedMs() / 1000))))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
      }
      if (this.episodes.length > 0) {
        Text(L.f('episode_count', this.episodes.length))
          .fontSize(TypeScale.titleSmall * this.fontScale)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.scheme.onBackground)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 8 })
  }
}
