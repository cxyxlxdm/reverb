import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { L } from '../util/L';
import { Podcast, Episode, FeedResult } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { Http } from '../net/Http';
import { SubscriptionStore, HistoryStore } from '../store/Stores';
import { ListenStatsStore } from '../store/ListenStatsStore';
import { DownloadManager, DownloadResult } from '../playback/DownloadManager';
import { PlayerController } from '../playback/PlayerController';
import { TopBar, EmptyHint, LoadingBox, Artwork, Glyph, Sym } from './Widgets';
import { EpisodeListItem, formatListenDuration } from './Components';
import { formatCachedAt } from '../util/DateParse';
import { Log } from '../util/Logger';
import { Files } from '../util/Files';
import { ChannelShareCard, snapshotToPng } from './MomentCard';
import type common from '@ohos.app.ability.common';

const RECENT_FEED_CACHE_MS = 60 * 1000;

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
  @State sharing: boolean = false;
  @State pulling: boolean = false;   // 下拉刷新指示器(Refresh 容器)
  private loadGeneration: number = 0;
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
  /// 单集行的"正在播放"高亮要读播放态。只做渲染 —— playNext/enqueue 那种纯写仍走 app.player。
  @ObjectLink player: PlayerController;

  private app: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.loadGeneration += 1;
  }

  /// 下拉刷新:强制走网络,与 load() 的区别是**不清空已展示内容** ——
  /// 拉刷新时页面先清空再转圈,观感是「内容闪没了」;失败时沿用现状,
  /// 由 staleAt 标出「离线内容」。走同一把 generation 锁,页面退出后结果作废。
  private async refresh(): Promise<void> {
    const feedUrl = this.seed.feedUrl;
    if (feedUrl.length === 0) {
      this.pulling = false;
      return;
    }
    const generation = ++this.loadGeneration;
    let feed: FeedResult | null = null;
    try {
      feed = await this.app.repository.feed(feedUrl);
    } catch (_e) {
      Log.w('Detail', `刷新异常 host=${Http.host(feedUrl)}`);
    } finally {
      if (generation === this.loadGeneration) this.pulling = false;
    }
    if (generation !== this.loadGeneration || feedUrl !== this.seed.feedUrl) return;
    if (feed === null) {
      this.staleAt = this.app.repository.feedCachedAt(feedUrl);
      this.failed = this.episodes.length === 0;
      // 失败必须有反馈,否则用户不知道这次下拉做成了没有;成功不加提示 ——
      // 列表内容更新本身可见(用户明确不要「已刷新」toast)
      this.showToast(L.s('refresh_failed'));
      Log.w('Detail', `刷新失败 host=${Http.host(feedUrl)},沿用现有内容`);
      return;
    }
    this.staleAt = 0;
    this.failed = false;
    this.applyFeed(feed, this.seed);
    Log.i('Detail', `刷新 "${this.display().title}" 共 ${feed.episodes.length} 集`);
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
    const seed = this.seed;
    const feedUrl = seed.feedUrl;
    const generation = ++this.loadGeneration;
    this.loaded = null;
    this.episodes = [];
    this.staleAt = 0;
    this.failed = false;
    this.descExpanded = false;
    if (feedUrl.length === 0) {
      this.loading = false;
      this.failed = true;
      return;
    }
    // 先出缓存:秒开,且断网时也有内容可看。搜索预检刚完整解析过的结果一分钟内无需再下载一遍。
    const cached = this.app.repository.cachedFeed(feedUrl);
    const cachedAt = this.app.repository.feedCachedAt(feedUrl);
    if (cached !== null && cached.episodes.length > 0) {
      this.applyFeed(cached, seed);
      if (Date.now() - cachedAt < RECENT_FEED_CACHE_MS) {
        this.loading = false;
        this.staleAt = 0;
        return;
      }
      this.staleAt = cachedAt;
    }
    this.loading = this.episodes.length === 0;
    let feed: FeedResult | null = null;
    try {
      feed = await this.app.repository.feed(feedUrl);
    } catch (_e) {
      Log.w('Detail', `加载异常 host=${Http.host(feedUrl)}`);
    } finally {
      // 页面已退出或 seed 已切换时,旧请求绝不能清掉新页面的 loading。
      if (generation === this.loadGeneration && feedUrl === this.seed.feedUrl) this.loading = false;
    }
    if (generation !== this.loadGeneration || feedUrl !== this.seed.feedUrl) return;
    if (feed === null) {
      // 有缓存就继续展示缓存(仅标为陈旧),只有连缓存都没有才算失败
      this.failed = this.episodes.length === 0;
      Log.w('Detail', `解析失败 host=${Http.host(feedUrl)}${this.episodes.length > 0 ? ',沿用缓存' : ''}`);
      return;
    }
    this.staleAt = 0;
    this.applyFeed(feed, seed);
    Log.i('Detail', `"${this.display().title}" 共 ${feed.episodes.length} 集`);
  }

  /// 把解析结果落到页面状态。用 RSS 结果补全,但保留列表页已有的封面/标题(RSS 有时缺图)。
  private applyFeed(feed: FeedResult, seed: Podcast): void {
    const p = feed.podcast;
    if (p.artworkUrl.length === 0) p.artworkUrl = seed.artworkUrl;
    if (p.title.length === 0) p.title = seed.title;
    if (p.author.length === 0) p.author = seed.author;
    p.isPaid = seed.isPaid;
    this.loaded = p;
    this.episodes = feed.episodes;
  }

  private async downloadEpisode(e: Episode): Promise<void> {
    const result = await this.downloadManager.download(e);
    if (result === DownloadResult.WIFI_REQUIRED) {
      this.showToast(L.s('download_wifi_required'));
    } else if (result === DownloadResult.NO_NETWORK) {
      this.showToast(L.s('download_no_network'));
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      Log.w('Detail', `提示失败 ${(e as Error).message}`);
    }
  }

  private async shareChannel(): Promise<void> {
    if (this.sharing) return;
    this.sharing = true;
    try {
      // 卡片常驻离屏;让出两帧,确保刚刷新的频道标题与封面已落到组件树再截图。
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 48));
      const ui = this.getUIContext();
      const ctx = ui.getHostContext() as common.UIAbilityContext;
      const png = await snapshotToPng(ui, ctx, 'reverb-channel-card', 'reverb-channel.png');
      if (png === null || !await Files.shareImage(ctx, L.s('channel_share'), png)) {
        this.showToast(L.s('share_failed'));
      }
    } finally {
      this.sharing = false;
    }
  }

  build() {
    Stack() {
      Column() {
        Row() {
          TopBar({
            scheme: this.scheme, fontScale: this.fontScale,
            title: this.display().title,
            onBack: () => this.onBack()
          })
            .layoutWeight(1)
          Row() {
            Glyph({ symbol: Sym.share, dim: 21,
              color: this.sharing ? this.scheme.outline : this.scheme.primary })
          }
          .width(40).height(40).justifyContent(FlexAlign.Center)
          .onClick(() => { this.shareChannel(); })
        }
        .width('100%')
        .padding({ right: 8 })
        .alignItems(VerticalAlign.Center)

      if (this.loading && this.episodes.length === 0) {
        LoadingBox({ scheme: this.scheme, fontScale: this.fontScale }).layoutWeight(1)
      } else {
        // 下拉刷新:Refresh 容器包住列表。onRefreshing 走强制网络刷新(refresh),
        // 与 load() 的「先清空再加载」不同:不清空现有内容,失败沿用现状只标离线。
        // refreshing 必须 $$ 双向绑定:用户松手触发刷新时框架要把内部状态**写回**
        // pulling,单向下拉后 pulling 一直是 false,finally 里的置 false 是无效赋值,
        // 指示器就永远收不回 —— 曾因此转圈不消失。
        Refresh({ refreshing: $$this.pulling }) {
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
                  Text(L.s('detail_network_unreachable'))
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
                  // 正在播的那一集要高亮。此前漏传,于是在详情页点播后列表毫无反应,
                  // 只能靠底部迷你条判断播的是哪条 —— Android 一直是传的。
                  isCurrent: this.player.current !== null && this.player.current.id === e.id,
                  isPlaying: this.player.isPlaying,
                  played: this.history.isPlayed(e.id),
                  downloadState: this.dlState(e.id),
                  // 详情页以浏览选集为主,给行内「加入播放列表」按钮:长按菜单的
                  // 系统触发时长改不了,浏览场景一步入队更顺手(其余列表仍走长按菜单)
                  showQueueAdd: true,
                  onPlay: () => this.onPlayEpisode(e, this.episodes),
                  onDownload: () => { this.downloadEpisode(e); },
                  onDeleteDownload: () => { this.downloadManager.delete(e.id); },
                  // 纯动作,不参与本页渲染,直接用容器单例即可(理由同 DiscoverPage)
                  onPlayNext: () => { this.app.player.playNext(e); },
                  onEnqueue: () => { this.app.player.enqueue(e); }
                })
              }
            }, (e: Episode) => e.id)
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
        }
        .layoutWeight(1)
        .onRefreshing(() => { this.refresh(); })
      }
      }
      .width('100%')
      .height('100%')

      // 与播放页剪藏相同:组件必须实际参与渲染才能被 componentSnapshot 捕获。
      ChannelShareCard({
        scheme: this.scheme, fontScale: this.fontScale, podcast: this.display()
      })
        .id('reverb-channel-card')
        .position({ x: -2000, y: 0 })
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
