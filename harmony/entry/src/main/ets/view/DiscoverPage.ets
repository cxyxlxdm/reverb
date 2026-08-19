import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { GuideEpisode } from '../store/GuideEpisode';
import { Podcast, Episode, SearchOutcome, HistoryEntry } from '../model/Models';
import { DISCOVER_CATEGORIES, DiscoverCategory, categoryLabel } from '../model/Genres';
import { AppContainer } from '../AppContainer';
import { ScreenHeader, EmptyHint, LoadingBox, SquareArtwork, Glyph, GlyphImage, Sym } from './Widgets';
import { PodcastListItem, EpisodeListItem, ChipsRow } from './Components';
import { RadioStation, RadioMode } from '../playback/RadioStation';
import { SettingsStore } from '../store/SettingsStore';
import { SubscriptionStore, HistoryStore } from '../store/Stores';
import { Log } from '../util/Logger';

/// 发现页:分类热门榜(缓存秒开 + 后台刷新 + 下拉刷新)+ 搜索(节目/单集双分段)
/// + RSS 地址直接导入。对应 Android `DiscoverScreen.kt`。
@Component
export struct DiscoverPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 见 LibraryPage 同名注释:驱动界面的 store 必须被观察,不能 `this.app.xxx` 直读。
  /// 电台按钮(图标/激活态/准备中)与「继续收听」都依赖它们。
  @ObjectLink settings: SettingsStore;
  @ObjectLink history: HistoryStore;
  /// 只用于判断"是不是全新用户"(决定引导卡显不显示)。必须是 @ObjectLink 而非直接读
  /// AppContainer 的裸对象 —— 否则订阅后返回本页,引导卡不会消失(同 H26 的坑)。
  @ObjectLink subscriptions: SubscriptionStore;
  @ObjectLink radio: RadioStation;
  onOpenPodcast: (p: Podcast) => void = () => {};
  onPlayEpisode: (e: Episode, queue: Episode[]) => void = () => {};

  @State catIndex: number = 0;
  /// chips 高亮专用索引,与驱动 Swiper `.index()` 的 catIndex 分开(理由见 LibraryPage 同名注释)
  @State chipSel: number = 0;
  /// Swiper 实测宽度,用于判断拖动是否过半
  @State pageW: number = 0;
  @State lists: Podcast[][] = [];          // 每个分类一份榜单
  @State loadingFlags: boolean[] = [];
  /// 该分类当前展示的是随包内置清单(非联网榜单)。内置清单是打包时的榜单快照,
  /// 标成「每日热门」会误导,故标题改为「内置精选」。
  @State seedFlags: boolean[] = [];
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
    const sd: boolean[] = [];
    for (let i = 0; i < n; i++) {
      l.push([]);
      f.push(false);
      sd.push(false);
    }
    this.lists = l;
    this.loadingFlags = f;
    this.seedFlags = sd;
    this.loadCategory(0, false);
  }

  /// 先取缓存秒显,再后台刷新。force=true 为下拉刷新(跳过缓存直接刷)。
  private async loadCategory(idx: number, force: boolean): Promise<void> {
    const cat: DiscoverCategory = DISCOVER_CATEGORIES[idx];
    const region = this.app.region();
    let hadCache = false;
    if (!force) {
      // 缓存为空时 cachedPopular 给出内置清单,同样能秒显,首屏不空
      const cached = this.app.repository.cachedPopular(cat.genreId, region);
      if (cached.length > 0) {
        this.setList(idx, cached);
        this.setSeed(idx, this.app.repository.isSeedList(cat.genreId, region));
        hadCache = true;   // 秒显后**继续往下走后台刷新**(不显转圈)
      }
    }
    if (!hadCache) this.setLoading(idx, true);
    const fresh = await this.app.repository.refreshPopular(cat.genreId, region);
    if (!hadCache) this.setLoading(idx, false);
    if (fresh.length > 0) {
      this.setList(idx, fresh);
      this.setSeed(idx, false);
    }
    Log.i('Discover', `分类 ${cat.key} 加载 ${fresh.length} 条`);
  }

  private setList(idx: number, list: Podcast[]): void {
    const next = this.lists.slice();
    next[idx] = list;
    this.lists = next;
  }

  private setSeed(idx: number, v: boolean): void {
    if (this.seedFlags[idx] === v) return;
    const next = this.seedFlags.slice();
    next[idx] = v;
    this.seedFlags = next;
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
        // 与 Android 一致:发现页顶部是**应用名 + slogan**,不是「发现」二字
        // (「发现」只作底部 tab 的标签)。
        title: L.s('app_title'),
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
          selected: this.chipSel,
          onSelect: (i: number) => {
            this.catIndex = i;
            this.chipSel = i;
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
        .onAreaChange((_o: Area, n: Area) => { this.pageW = Number(n.width); })
        // chips 高亮跟着手指走(位移过半即切),只改 chipSel、不碰 catIndex —— 详见 LibraryPage 注释
        .onGestureSwipe((index: number, e: SwiperAnimationEvent) => {
          this.chipSel = this.dragTarget(index, e.currentOffset);
        })
        .onAnimationStart((_i: number, target: number) => { this.chipSel = target; })
        // 榜单加载**只在落位后**做:放到 gestureSwipe/animationStart 会让快速连滑时
        // 每划过一页都发一次网络请求。
        .onChange((i: number) => {
          this.catIndex = i;
          this.chipSel = i;
          if (this.lists[i].length === 0) this.loadCategory(i, false);
        })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  /// 拖动位移 → 目标页(过半才切,并夹在合法范围)。符号不写死,用绝对值 + 方向判断。
  private dragTarget(index: number, offset: number): number {
    if (this.pageW <= 0) return index;
    if (Math.abs(offset) < this.pageW / 2) return index;
    const next = offset < 0 ? index + 1 : index - 1;
    return Math.max(0, Math.min(DISCOVER_CATEGORIES.length - 1, next));
  }

  /// 情境电台的时段图标。**分界与 Android `contextualRadioIcon()` 逐段一致**:
  /// 5–10 晨曦 / 11–16 白日 / 17–19 黄昏 / 其余 夜。
  /// 注:`RadioStation.contextualPhase()` 的文字分界(5–8/9–17/18–21)与此不同,
  /// 它只用于长按提示,不参与这里的图标选择 —— 两端图标口径以 Android 为准。
  private radioIcon(): Resource {
    if (!this.settings.contextualRadio) return Sym.shuffle;
    const h = new Date().getHours();
    if (h >= 5 && h <= 10) return Sym.twilight;
    if (h >= 11 && h <= 16) return Sym.sun;
    if (h >= 17 && h <= 19) return Sym.twilight;
    return Sym.moon;
  }

  /// 电台按钮:未开台点击开台;在台时点击换下一首,长按停台。
  /// 与 Android `RadioActionButton` 一致 —— **只有一个图标**,不带时段文字;
  /// 随机模式用 Shuffle,情境模式用时段图标。原先用喇叭图标 + "白日"这类文字,是自创的。
  @Builder
  radioButton() {
    Row({ space: 5 }) {
      if (this.radio.preparing !== null) {
        LoadingProgress().width(18).height(18).color(this.scheme.primary)
      } else {
        Glyph({
          symbol: this.radioIcon(), dim: 21,
          color: this.radio.mode !== null ? this.scheme.primary : this.scheme.onSurfaceVariant
        })
      }
    }
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.radio.mode !== null) {
        this.radio.skip();
      } else {
        const mode = this.settings.contextualRadio ? RadioMode.CONTEXTUAL : RadioMode.RANDOM;
        this.radio.start(mode);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (this.radio.mode !== null) this.radio.stop();
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
            } else if (this.showGuide()) {
              ListItem() {
                this.guideCard()
              }
            }
            ListItem() {
              Text(L.f(this.seedFlags[idx] ? 'discover_seed_list' : 'discover_daily_hot',
                categoryLabel(DISCOVER_CATEGORIES[idx])))
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
    return this.history.history.filter((h: HistoryEntry) => {
      if (h.played) return false;
      if (h.positionMs < 10000 || h.durationMs <= 0) return false;
      return h.positionMs < h.durationMs * 0.95;
    }).slice(0, 15);
  }

  /// 全新用户(既没订阅也没听过任何东西)才展示引导入口。
  /// 一旦有任何使用痕迹就不再出现 —— 它是引导,不是常驻功能。
  private showGuide(): boolean {
    return GuideEpisode.available()
      && this.subscriptions.subscriptions.length === 0
      && this.history.history.length === 0;
  }

  /// 首次使用时的引导卡:点一下播放随包内置的 30 秒音频。
  /// 意义是让「全新安装 + 没网」也能走通完整播放链路,而不是对着空白猜是 App 坏了还是网不通。
  @Builder
  guideCard() {
    Row({ space: 12 }) {
      // 用 sys.media 的标准播放件而非 Symbol 字体:Symbol 名要到真机字体里才解析,
      // 写错不报错、直接空白渲染。这个件播放页已在用,确认可渲。
      GlyphImage({ icon: $r('sys.media.ohos_ic_public_play'), dim: 22, color: this.scheme.primary })
      Column({ space: 2 }) {
        Text(L.s('guide_title'))
          .fontSize(TypeScale.body * this.fontScale)
          .fontColor(this.scheme.onBackground)
        Text(L.s('guide_card_sub'))
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .margin({ left: Metrics.pagePadding, right: Metrics.pagePadding, bottom: 4 })
    .backgroundColor(withAlpha(this.scheme.primary, 0.08))
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.onPlayEpisode(GuideEpisode.make(), [GuideEpisode.make()]))
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
                  played: this.history.isPlayed(e.id),
                  onPlay: () => this.onPlayEpisode(e, this.searchEpisodes),
                  showPlayedToggle: true,
                  onTogglePlayed: () => { this.history.markPlayed(e.id, !this.history.isPlayed(e.id)); },
                  // 这两个只是**写**操作,不参与本页渲染,故可直接用容器里的单例;
                  // H26 说的"必须 @ObjectLink"针对的是**渲染读取**,不是这种纯动作。
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
