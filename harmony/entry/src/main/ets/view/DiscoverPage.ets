import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { Podcast, Episode, SearchOutcome } from '../model/Models';
import { DISCOVER_CATEGORIES, DiscoverCategory } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { ScreenHeader, EmptyHint, LoadingBox } from './Widgets';
import { PodcastGridItem, PodcastListItem, EpisodeListItem, ChipsRow } from './Components';
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
    if (!force) {
      const cached = this.app.repository.cachedPopular(cat.genreId, region);
      if (cached.length > 0) {
        this.setList(idx, cached);
        return;   // 有缓存即先展示;不阻塞,后台刷新在下面继续
      }
    }
    this.setLoading(idx, true);
    const fresh = await this.app.repository.refreshPopular(cat.genreId, region);
    this.setLoading(idx, false);
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
        title: '发现',
        subtitle: '听见余音',
        action: () => { this.radioButton() }
      })

      this.searchBar()

      if (this.searched) {
        this.searchResults()
      } else {
        ChipsRow({
          scheme: this.scheme,
          fontScale: this.fontScale,
          labels: DISCOVER_CATEGORIES.map((c: DiscoverCategory) => c.label),
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
      TextInput({ placeholder: '搜索节目、单集,或粘贴 RSS 地址', text: this.query })
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
        Text('取消')
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

  /// 分类页:下拉刷新 + 两列宫格。
  @Builder
  categoryPage(idx: number) {
    Refresh({ refreshing: this.refreshing }) {
      Scroll() {
        Column() {
          if (this.loadingFlags[idx] && this.lists[idx].length === 0) {
            LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
              .height(320)
          } else if (this.lists[idx].length === 0) {
            EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '暂时没有内容,下拉重试' })
              .height(320)
          } else {
            Grid() {
              ForEach(this.lists[idx], (p: Podcast) => {
                GridItem() {
                  PodcastGridItem({
                    scheme: this.scheme,
                    fontScale: this.fontScale,
                    podcast: p,
                    onTap: () => this.onOpenPodcast(p)
                  })
                }
              }, (p: Podcast) => p.id)
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(Metrics.gridSpacing)
            .rowsGap(Metrics.gridSpacing + 4)
            .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 20 })
            .height(this.gridHeight(this.lists[idx].length))
          }
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .onRefreshing(() => {
      this.refreshing = true;
      this.loadCategory(idx, true).then(() => { this.refreshing = false; });
    })
    .width('100%')
    .height('100%')
  }

  /// Grid 在 Scroll 内需要显式高度:按两列估算。
  private gridHeight(count: number): number {
    const rows = Math.ceil(count / 2);
    return rows * 230 + 20;
  }

  @Builder
  searchResults() {
    Column() {
      // 分段:节目 / 单集
      Row({ space: 8 }) {
        this.searchTabChip('节目', this.searchPodcasts.length, 0)
        this.searchTabChip('单集', this.searchEpisodes.length, 1)
        Blank()
        if (this.searchLabel.length > 0) {
          Text(`来自 ${this.searchLabel}`)
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
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '没有找到节目' }).layoutWeight(1)
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
          EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: '没有找到单集' }).layoutWeight(1)
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
