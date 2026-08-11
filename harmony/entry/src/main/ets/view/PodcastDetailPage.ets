import { Scheme, TypeScale, Metrics } from '../theme/Theme';
import { Podcast, Episode, FeedResult } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { TopBar, EmptyHint, LoadingBox, Artwork } from './Widgets';
import { EpisodeListItem } from './Components';
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
  @State descExpanded: boolean = false;
  @State subscribed: boolean = false;

  private app: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    this.subscribed = this.app.subscriptions.isSubscribed(this.seed.feedUrl);
    this.load();
  }

  private display(): Podcast {
    return this.loaded === null ? this.seed : this.loaded;
  }

  private async load(): Promise<void> {
    if (this.seed.feedUrl.length === 0) {
      this.failed = true;
      return;
    }
    this.loading = true;
    this.failed = false;
    const feed: FeedResult | null = await this.app.repository.feed(this.seed.feedUrl);
    this.loading = false;
    if (feed === null) {
      this.failed = true;
      Log.w('Detail', `解析失败 ${this.seed.feedUrl}`);
      return;
    }
    // 用 RSS 结果补全,但保留列表页已有的封面/标题(RSS 有时缺图)
    const p = feed.podcast;
    if (p.artworkUrl.length === 0) p.artworkUrl = this.seed.artworkUrl;
    if (p.title.length === 0) p.title = this.seed.title;
    if (p.author.length === 0) p.author = this.seed.author;
    p.isPaid = this.seed.isPaid;
    this.loaded = p;
    this.episodes = feed.episodes;
    Log.i('Detail', `"${p.title}" 共 ${feed.episodes.length} 集`);
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
          if (this.failed && this.episodes.length === 0) {
            ListItem() {
              Column({ space: 12 }) {
                Text('加载失败,请检查网络')
                  .fontSize(TypeScale.body * this.fontScale)
                  .fontColor(this.scheme.onSurfaceVariant)
                Button('重试')
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
                played: this.app.history.isPlayed(e.id),
                onPlay: () => this.onPlayEpisode(e, this.episodes)
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
            Text('付费节目')
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
      Button(this.subscribed ? '已订阅' : '订阅')
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.subscribed ? this.scheme.primary : this.scheme.onPrimary)
        .backgroundColor(this.subscribed ? Color.Transparent : this.scheme.primary)
        .borderWidth(this.subscribed ? 1 : 0)
        .borderColor(this.scheme.primary)
        .borderRadius(18)
        .height(36)
        .padding({ left: 22, right: 22 })
        .onClick(() => {
          this.app.subscriptions.toggle(this.display());
          this.subscribed = this.app.subscriptions.isSubscribed(this.display().feedUrl);
        })

      if (this.display().description.length > 0) {
        Column({ space: 4 }) {
          Text(this.display().description)
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .lineHeight(21)
            .maxLines(this.descExpanded ? 100 : 4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.descExpanded ? '收起' : '展开')
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.primary)
            .onClick(() => { this.descExpanded = !this.descExpanded; })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }

      if (this.episodes.length > 0) {
        Text(`共 ${this.episodes.length} 集`)
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
