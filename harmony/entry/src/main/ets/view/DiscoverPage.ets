import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Podcast, Episode, SearchOutcome, HistoryEntry } from '../model/Models';
import { DISCOVER_CATEGORIES, DiscoverCategory, categoryLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { ScreenHeader, EmptyHint, LoadingBox, SquareArtwork } from './Widgets';
import { PodcastListItem, EpisodeListItem, ChipsRow } from './Components';
import { RadioStation, RadioMode } from '../playback/RadioStation';
import { Log } from '../util/Logger';

/// 发现页:分类热门榜(缓存秒开 + 后台刷新 + 下拉刷新)+ 搜索(节目/单集双分段)
/// + RSS 地址直接导入。对应 Android `DiscoverScreen.kt`。
@Component
export struct DiscoverPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onOpenPodcast: (p: Podcast) => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[]) => void = () => {};

  @State catIndex: number = 0;
  @State lists: Podcast[][] = [];          // 每个分类一份榜单
  @State loadingFlags: boolean[] = [];
  @State refreshing: boolean = false;

  // 搜索
  @State query: string = '';
  @State searching: boolean = false;
  @State searchTab: number = 0;            // 0 节目 / 1 单集
  @State searchPodcasts: Podcast[] = [];
  @State searchEpisodes: Episode[] = [];
  @State searchLabel: string = '';
  @State searched: boolean = false;

  private app: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    const n = DISCOVER_CATEGORIES.length;
    const l: Podcast[][] = [];
    const f: boolean[] = [];
    for (let i = 0; i < n; i++) {
      l.push([]);
      f.push(false);
    }
    this.lists = l;
    this.loadingFlags = f;
    this.loadCategory(0, false);
  }

  /// 先取缓存秒显,再后台刷新。force=true 为下拉刷新(跳过缓存直接刷)。
  private async loadCategory(idx: number, force: boolean): Promise<void> {
    const cat: DiscoverCategory = DISCOVER_CATEGORIES[idx];
    const region = this.app.region();
    let hadCache = false;
    if (!force) {
      const cached = this.app.repository.cachedPopular(cat.genreId, region);
      if (cached.length > 0) {
        this.setList(idx, cached);
        hadCache = true;   // 缓存秒显,但**继续往下走后台刷新**(不显转圈)
      }
    }
    if (!hadCache) this.setLoading(idx, true);
    const fresh = await this.app.repository.refreshPopular(cat.genreId, region);
    if (!hadCache) this.setLoading(idx, false);
    if (fresh.length > 0) this.setList(idx, fresh);
    Log.i('Discover', `分类 ${cat.key} 加载 ${fresh.length} 条`);
  }

  private setList(idx: number, list: Podcast[]): void {
    const next = this.lists.slice();
    next[idx] = list;
    this.lists = next;
  }

  private setLoading(idx: number, v: boolean): void {
    const next = this.loadingFlags.slice();
    next[idx] = v;
    this.loadingFlags = next;
  }

  private async runSearch(): Promise<void> {
    const q = this.query.trim();
    if (q.length === 0) {
      this.searched = false;
      this.searchPodcasts = [];
      this.searchEpisodes = [];
      return;
    }
    this.searching = true;
    this.searched = true;
    const region = this.app.region();
    const outcome: SearchOutcome = await this.app.repository.search(q, region);
    this.searchPodcasts = outcome.podcasts;
    this.searchLabel = outcome.sourceLabel;
    // 单集只有 Apple 提供
    this.searchEpisodes = await this.app.repository.searchEpisodes(q, region);
    this.searching = false;
    Log.i('Discover', `搜索 "${q}" 节目=${this.searchPodcasts.length} 单集=${this.searchEpisodes.length} 源=${this.searchLabel}`);
  }

  build() {
    Column() {
      ScreenHeader({
        scheme: this.scheme,
        fontScale: this.fontScale,
        title: L.s('nav_discover'),
        subtitle: L.s('app_slogan'),
        action: () => { this.radioButton() }
      })

      this.searchBar()

      if (this.searched) {
        this.searchResults()
      } else {
        ChipsRow({
          scheme: this.scheme,
          fontScale: this.fontScale,
          labels: DISCOVER_CATEGORIES.map((c: DiscoverCategory) => categoryLabel(c)),
          selected: this.catIndex,
          onSelect: (i: number) => {
            this.catIndex = i;
            if (this.lists[i].length === 0) this.loadCategory(i, false);
          }
        })
        Swiper() {
          ForEach(DISCOVER_CATEGORIES, (cat: DiscoverCategory, idx: number) => {
            this.categoryPage(idx)
          }, (cat: DiscoverCategory) => cat.key)
        }
        .index(this.catIndex)
        .loop(false)
        .indicator(false)
        .cachedCount(1)
        .onChange((i: number) => {
          this.catIndex = i;
          if (this.lists[i].length === 0) this.loadCategory(i, false);
        })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  /// 电台按钮:未开台点击开台;在台时点击换下一首,长按停台。
  /// 情境模式显示当前时段(清晨/白日/日落/深夜),与 Android 的时段图标同义。
  @Builder
  radioButton() {
    Row({ space: 5 }) {
      if (this.app.radio.preparing !== null) {
        LoadingProgress().width(18).height(18).color(this.scheme.primary)
      } else {
        Image($r('sys.media.ohos_ic_public_device_soundx_filled'))
          .width(20).height(20)
          .fillColor(this.app.radio.mode !== null ? this.scheme.primary : this.scheme.onSurfaceVariant)
      }
      if (this.app.settings.contextualRadio) {
        Text(RadioStation.contextualPhase())
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.app.radio.mode !== null ? this.scheme.primary : this.scheme.onSurfaceVariant)
      }
    }
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.app.radio.mode !== null) {
        this.app.radio.skip();
      } else {
        const mode = this.app.settings.contextualRadio ? RadioMode.CONTEXTUAL : RadioMode.RANDOM;
        this.app.radio.start(mode);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (this.app.radio.mode !== null) this.app.radio.stop();
    }))
  }

  @Builder
  searchBar() {
    Row({ space: 8 }) {
      Image($r('sys.media.ohos_ic_public_search_filled'))
        .width(18).height(18)
        .fillColor(this.scheme.onSurfaceVariant)
      TextInput({ placeholder: L.s('search_placeholder'), text: this.query })
        .placeholderColor(this.scheme.onSurfaceVariant)
        .fontColor(this.scheme.onBackground)
        .fontSize(TypeScale.body * this.fontScale)
        .backgroundColor(Color.Transparent)
        .borderRadius(0)
        .padding(0)
        .layoutWeight(1)
        .onChange((v: string) => { this.query = v; })
        .onSubmit(() => { this.runSearch(); })
      if (this.query.length > 0) {
        Text(L.s('action_cancel'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.primary)
          .onClick(() => {
            this.query = '';
            this.searched = false;
            this.searchPodcasts = [];
            this.searchEpisodes = [];
          })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .margin({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 8 })
    .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.10))
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
  }

  /// 分类页:下拉刷新 + **单列列表**(与 Android 一致,非宫格),
  /// 首项为「继续收听」横条(有未播完历史时),其后是「每日热门 · X」小标题与频道行。
  @Builder
  categoryPage(idx: number) {
    Refresh({ refreshing: this.refreshing }) {
      Column() {
        if (this.loadingFlags[idx] && this.lists[idx].length === 0) {
          LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
        } else if (this.lists[idx].length === 0) {
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('discover_empty') })
        } else {
          List() {
            if (this.continueEntries().length > 0) {
              ListItem() {
                this.continueStrip()
              }
            }
            ListItem() {
              Text(L.f('discover_daily_hot', categoryLabel(DISCOVER_CATEGORIES[idx])))
                .fontSize(TypeScale.caption * this.fontScale)
                .fontColor(this.scheme.onSurfaceVariant)
                .padding({ left: Metrics.pagePadding, top: 4, bottom: 4 })
            }
            ForEach(this.lists[idx], (p: Podcast) => {
              ListItem() {
                PodcastListItem({
                  scheme: this.scheme, fontScale: this.fontScale, podcast: p,
                  onTap: () => this.onOpenPodcast(p)
                })
              }
            }, (p: Podcast) => p.id)
          }
          .scrollBar(BarState.Off)
          .width('100%').height('100%')
        }
      }
      .width('100%').height('100%')
    }
    .onRefreshing(() => {
      this.refreshing = true;
      this.loadCategory(idx, true).then(() => { this.refreshing = false; });
    })
    .width('100%')
    .height('100%')
  }

  /// 未播完的历史:进度在 10s ~ 95% 且未标记已播完,最新在前,最多 15 条(与 Android 同口径)。
  private continueEntries(): HistoryEntry[] {
    return this.app.history.history.filter((h: HistoryEntry) => {
      if (h.played) return false;
      if (h.positionMs < 10000 || h.durationMs <= 0) return false;
      return h.positionMs < h.durationMs * 0.95;
    }).slice(0, 15);
  }

  /// 继续收听:横滑卡片,点按续播。
  @Builder
  continueStrip() {
    Column({ space: 6 }) {
      Text(L.s('continue_listening'))
        .fontSize(TypeScale.titleSmall * this.fontScale)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
        .padding({ left: Metrics.pagePadding })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.continueEntries(), (h: HistoryEntry) => {
            Column({ space: 6 }) {
              SquareArtwork({ scheme: this.scheme, url: h.episode.artworkUrl, corner: 12 })
              Text(h.episode.title)
                .fontSize(TypeScale.caption * this.fontScale)
                .fontColor(this.scheme.onBackground)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              // 细进度条
              Stack({ alignContent: Alignment.Start }) {
                Row().width('100%').height(3)
                  .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.2)).borderRadius(2)
                Row().width(`${Math.min(100, h.positionMs / h.durationMs * 100)}%`).height(3)
                  .backgroundColor(this.scheme.primary).borderRadius(2)
              }
              .width('100%').height(3)
            }
            .width(112)
            .onClick(() => this.onPlayEpisode(h.episode, this.continueEntries().map((x: HistoryEntry) => x.episode)))
          }, (h: HistoryEntry) => h.episode.id)
        }
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 4, bottom: 10 })
  }

  @Builder
  searchResults() {
    Column() {
      // 分段:节目 / 单集
      Row({ space: 8 }) {
        this.searchTabChip(L.s('tab_shows'), this.searchPodcasts.length, 0)
        this.searchTabChip(L.s('tab_episodes'), this.searchEpisodes.length, 1)
        Blank()
        if (this.searchLabel.length > 0) {
          Text(L.f('search_from', this.searchLabel))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
        }
      }
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      if (this.searching) {
        LoadingBox({ scheme: this.scheme, fontScale: this.fontScale }).layoutWeight(1)
      } else if (this.searchTab === 0) {
        if (this.searchPodcasts.length === 0) {
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('search_no_shows') }).layoutWeight(1)
        } else {
          List() {
            ForEach(this.searchPodcasts, (p: Podcast) => {
              ListItem() {
                PodcastListItem({
                  scheme: this.scheme, fontScale: this.fontScale, podcast: p,
                  onTap: () => this.onOpenPodcast(p)
                })
              }
            }, (p: Podcast) => p.id)
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
      } else {
        if (this.searchEpisodes.length === 0) {
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('search_no_episodes') }).layoutWeight(1)
        } else {
          List() {
            ForEach(this.searchEpisodes, (e: Episode) => {
              ListItem() {
                EpisodeListItem({
                  scheme: this.scheme, fontScale: this.fontScale, episode: e,
                  showPodcastTitle: true,
                  played: this.app.history.isPlayed(e.id),
                  onPlay: () => this.onPlayEpisode(e, this.searchEpisodes)
                })
              }
            }, (e: Episode) => e.id)
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  searchTabChip(label: string, count: number, idx: number) {
    Text(count > 0 ? `${label} ${count}` : label)
      .fontSize(TypeScale.label * this.fontScale)
      .fontColor(this.searchTab === idx ? this.scheme.onPrimary : this.scheme.onSurfaceVariant)
      .backgroundColor(this.searchTab === idx ? this.scheme.primary : withAlpha(this.scheme.onSurfaceVariant, 0.10))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(14)
      .onClick(() => { this.searchTab = idx; })
  }
}
