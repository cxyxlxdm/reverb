import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { Episode } from '../model/Models';
import { Station } from '../model/Station';
import { RadioBrowserSource } from '../net/RadioBrowserSource';
import { PlayerController } from '../playback/PlayerController';
import { ScreenHeader, LoadingBox, Glyph, Sym, Artwork } from './Widgets';
import { Log } from '../util/Logger';

/**
 * 「电台」顶层页 —— **鸿蒙提审版只保留搜索**。
 *
 * 口径(2026-11-24 用户拍板):直播电台先隐藏,只允许搜索。所以这一页没有「我的电台」、
 * 没有热门、没有随包精选,也没有添加/编辑/删除;输入关键词、从公开目录取结果、点一条起播,
 * 就是全部。随包 `radio_stations.json` 同时从鸿蒙资源里删掉 —— 只藏界面不删文件,
 * 解包仍能 grep 到台名,过不了「包里到底有没有」这条判据(见硬规矩 1)。
 *
 * 为什么只动鸿蒙:华为以「应用含有 CCTV 电台」等为由拒了 1.0.9;另三端不在这次提审范围。
 * 恢复整页时,从 git 历史取回本文件上一版,并把 `shared/radio/sync.sh` 的鸿蒙目标加回去。
 *
 * 播放走 `PlayerController.play`,现场合成一条 `isLive=true` 的 `Episode`
 * (id = `live:<url>`,与发现页搜索框直接粘地址那条同一 id):同一条流从两处起播,
 * 队列里不会出现两条。
 *
 * ⚠️ ArkUI 的 `@Builder` / `build()` 体内**不能声明局部变量**(H137),所以凡是"先算再传"
 * 的量都写成方法或字段,不在这里写 `const`。
 */
@Component
export struct RadioPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop bottomPad: number = 0;
  @Prop @Watch('onScrollTopToken') scrollTopToken: number = 0;
  onScrollDy: (dy: number, st: ScrollState) => void = () => {};
  @ObjectLink player: PlayerController;

  @State query: string = '';
  @State searching: boolean = false;
  @State searched: boolean = false;
  @State results: Station[] = [];
  @State directoryError: boolean = false;

  private directory: RadioBrowserSource = new RadioBrowserSource();
  private scroller: Scroller = new Scroller();
  private generation: number = 0;

  private runSearch(): void {
    const q = this.query.trim();
    if (q.length === 0) {
      this.searched = false;
      this.results = [];
      this.searching = false;
      this.directoryError = false;
      return;
    }
    const gen = ++this.generation;
    this.searched = true;
    this.searching = true;
    this.directoryError = false;
    this.results = [];
    this.directory.search(q).then((list: Station[]) => {
      if (gen !== this.generation) return;
      this.results = list;
      this.searching = false;
      Log.i('Radio', `搜索完成 count=${list.length}`);
    }).catch((_e: Error) => {
      if (gen !== this.generation) return;
      this.searching = false;
      this.directoryError = true;
      Log.w('Radio', '电台搜索失败');
    });
  }

  private onScrollTopToken(): void {
    this.scroller.scrollEdge(Edge.Top);
  }

  // ── 播放 ────────────────────────────────────────────────────────────────

  private isCurrent(s: Station): boolean {
    return this.player.current !== null && this.player.current.id === 'live:' + s.url;
  }

  private play(s: Station): void {
    const ep: Episode = {
      id: 'live:' + s.url,
      title: s.name,
      description: '',
      audioUrl: s.url,
      artworkUrl: s.logo,
      podcastTitle: L.s('radio_live_name'),
      durationSec: 0,
      pubDate: '',
      feedUrl: '',
      transcriptUrl: '',
      transcriptType: '',
      chaptersUrl: '',
      chaptersType: '',
      isLive: true
    };
    this.player.play(ep);
  }

  // ── 渲染 ────────────────────────────────────────────────────────────────

  private groupLabel(g: string): string {
    return g.length === 0 ? L.s('radio_group_none') : L.s('radio_group_' + g);
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(TypeScale.titleSmall * this.fontScale)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.scheme.onSurfaceVariant)
      .width('100%')
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 16, bottom: 6 })
  }

  @Builder
  searchBar() {
    Column() {
      Row({ space: 12 }) {
        Image($r('sys.media.ohos_ic_public_search_filled'))
          .width(20).height(20)
          .fillColor(this.scheme.onSurfaceVariant)
        TextInput({ placeholder: L.s('radio_search_hint'), text: this.query })
          .placeholderColor(this.scheme.onSurfaceVariant)
          .fontColor(this.scheme.onBackground)
          .fontSize(TypeScale.bodyLarge * this.fontScale)
          .placeholderFont({ size: TypeScale.label * this.fontScale })
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding(0)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.query = v;
            // 清空输入 = 回到搜索前的那一句提示,不把上一次的结果留在屏上
            if (v.trim().length === 0 && this.searched) this.runSearch();
          })
          .onSubmit(() => this.runSearch())
        if (this.query.length > 0) {
          Text(L.s('action_cancel'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.primary)
            .onClick(() => {
              this.query = '';
              this.runSearch();
            })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.10))
      .borderRadius(12)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding })
    .margin({ bottom: 4 })
  }

  @Builder
  stationRow(s: Station) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Artwork({ scheme: this.scheme, url: s.logo, dim: 48, corner: 10 })
        if (this.isCurrent(s)) {
          Column() {
            Glyph({ symbol: Sym.playing, dim: 20, color: '#FFFFFF' })
          }
          .width(48).height(48)
          .backgroundColor(withAlpha('#000000', 0.45))
          .borderRadius(10)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width(48).height(48)
      .onClick(() => this.play(s))

      Column({ space: 2 }) {
        Text(s.name)
          .fontSize(TypeScale.bodyLarge * this.fontScale)
          .fontWeight(this.isCurrent(s) ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.isCurrent(s) ? this.scheme.primary : this.scheme.onBackground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(s.group.length > 0 ? this.groupLabel(s.group) : (s.country.length > 0 ? s.country : L.s('radio_live_name')))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => this.play(s))

      // 起播的提示。这一页没有增删改之后,尾部只留一枚播放键 —— 行本身已可点,
      // 图标只是把"点它会出声"这件事说出来,两者走同一个 play。
      Glyph({ symbol: Sym.playFill, dim: 18, color: this.scheme.onSurfaceVariant })
        .margin({ right: 8 })
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding - 6, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /// 列表内容。只有三态:还没搜 → 一句提示;搜索中/失败/空 → 对应一行;有结果 → 结果行。
  @Builder
  body() {
    List({ scroller: this.scroller }) {
      if (this.searched) {
        ListItem() {
          this.sectionTitle(L.s('radio_search_results'))
        }
        if (this.searching) {
          ListItem() {
            LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
              .height(160)
          }
        } else if (this.directoryError) {
          ListItem() {
            this.errorRow()
          }
        } else if (this.results.length === 0) {
          ListItem() {
            Text(L.s('radio_empty_search'))
              .fontSize(TypeScale.body * this.fontScale)
              .fontColor(this.scheme.onSurfaceVariant)
              .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 4, bottom: 12 })
          }
        } else {
          ForEach(this.results, (s: Station) => {
            ListItem() {
              this.stationRow(s)
            }
          }, (s: Station) => 'dir:' + s.id)
        }
      } else {
        ListItem() {
          Text(L.s('radio_search_prompt'))
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 36, bottom: 12 })
        }
      }
    }
    .scrollBar(BarState.Off)
    .contentEndOffset(this.bottomPad)
    .onDidScroll((dy: number, st: ScrollState): void => this.onScrollDy(dy, st))
    .width('100%').height('100%')
  }

  @Builder
  errorRow() {
    Row({ space: 12 }) {
      Text(L.s('radio_load_failed'))
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
      Text(L.s('radio_retry'))
        .fontSize(TypeScale.label * this.fontScale)
        .fontColor(this.scheme.primary)
        .onClick(() => this.runSearch())
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 12 })
  }

  build() {
    Column() {
      ScreenHeader({
        scheme: this.scheme,
        fontScale: this.fontScale,
        title: L.s('nav_radio'),
        subtitle: L.s('radio_subtitle')
      })
      this.searchBar()
      this.body()
    }
    .width('100%').height('100%')
  }
}
