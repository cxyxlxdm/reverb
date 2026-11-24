import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import util from '@ohos.util';
import { L } from '../util/L';
import { Episode } from '../model/Models';
import { Station, StationMeta } from '../model/Station';
import { StationStore } from '../store/StationStore';
import { RadioBrowserSource } from '../net/RadioBrowserSource';
import { LiveStream } from '../net/LiveStream';
import { Http } from '../net/Http';
import { PlayerController } from '../playback/PlayerController';
import { ScreenHeader, EmptyHint, LoadingBox, Glyph, Sym, Artwork } from './Widgets';
import { ConfirmDialog, ConfirmSpec } from './Components';
import { Log } from '../util/Logger';

/**
 * 「电台」顶层页:完整形态是我的直播电台 + 在线目录搜索 + 热门 + 随包精选;
 * 鸿蒙提审口径下,`full` **默认 false**,只显示「搜索 + 试听」。完整形态没有删,
 * 由用户在「设置 → 功能 → 完整直播电台」里手动开启(见 SettingsStore.radioFullEnabled)。
 *
 * 一条口径贯穿整页:**目录与精选都是只读来源,只有「加入」那一下才会复制进本账本**。
 * 因此这里没有"删除目录条目"这种动作 —— 用户不要的那条从我的列表删掉即可。
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
  @ObjectLink stations: StationStore;
  /** 鸿蒙完整电台功能。默认 false:只搜索;true:恢复我的/热门/精选与增删改。 */
  @Prop @Watch('onFullChange') full: boolean = false;

  @State query: string = '';
  @State searching: boolean = false;
  @State searched: boolean = false;
  @State results: Station[] = [];
  @State directoryError: boolean = false;
  @State popular: Station[] = [];
  @State popularLoading: boolean = false;
  @State popularError: boolean = false;

  @State editorOpen: boolean = false;
  @State editing: Station | null = null;
  @State formName: string = '';
  @State formUrl: string = '';
  @State formLogo: string = '';
  @State formGroup: string = '';
  @State formError: string = '';
  @State saving: boolean = false;
  /// 编辑前的地址:只有地址改过才重新探测(没改就保存不该因为探测不通而拦住)
  private originalUrl: string = '';

  @State pendingDelete: Station | null = null;

  private directory: RadioBrowserSource = new RadioBrowserSource();
  private scroller: Scroller = new Scroller();
  private generation: number = 0;

  aboutToAppear(): void {
    if (this.full) this.loadPopular();
  }

  /** 开关在页面栈里变化也要即时生效;关时顺手收掉已打开的编辑器与删除确认。 */
  private onFullChange(): void {
    if (this.full) {
      this.loadPopular();
    } else {
      this.editorOpen = false;
      this.editing = null;
      this.pendingDelete = null;
    }
  }

  private loadPopular(): void {
    if (this.popularLoading) return;
    this.popularLoading = true;
    this.popularError = false;
    this.directory.popular().then((list: Station[]) => {
      this.popular = list;
      this.popularLoading = false;
      if (list.length === 0) this.popularError = true;
    }).catch((_e: Error) => {
      this.popularLoading = false;
      this.popularError = true;
      Log.w('Radio', '热门电台加载失败');
    });
  }

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

  // ── 编辑 ────────────────────────────────────────────────────────────────

  private openAdd(): void {
    this.editing = null;
    this.originalUrl = '';
    this.formName = '';
    this.formUrl = '';
    this.formLogo = '';
    this.formGroup = '';
    this.formError = '';
    this.saving = false;
    this.editorOpen = true;
  }

  private openEdit(s: Station): void {
    this.editing = s;
    this.originalUrl = s.url;
    this.formName = s.name;
    this.formUrl = s.url;
    this.formLogo = s.logo;
    this.formGroup = s.group;
    this.formError = '';
    this.saving = false;
    this.editorOpen = true;
  }

  private closeEditor(): void {
    if (this.saving) return;
    this.editorOpen = false;
    this.editing = null;
  }

  /**
   * 保存。校验顺序与 Android 同一条:协议 → 重名 → 探测(仅地址改过/新增)。
   * 名称留空时用探测到的台名(ICY `icy-name`)兜底,再兜底主机名。
   */
  private async save(): Promise<void> {
    if (this.saving) return;
    const url = this.formUrl.trim();
    const editingId = this.editing === null ? '' : this.editing.id;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.formError = L.s('radio_invalid_url');
      return;
    }
    if (this.stations.containsUrl(url, editingId)) {
      this.formError = L.s('radio_duplicate');
      return;
    }
    this.saving = true;
    this.formError = '';
    let probeName = '';
    const needProbe = this.editing === null || url !== this.originalUrl;
    if (needProbe) {
      const ep = await LiveStream.resolve(url);
      if (ep === null) {
        this.saving = false;
        this.formError = L.s('radio_not_stream');
        return;
      }
      probeName = ep.title;
    }
    const typed = this.formName.trim();
    let name = typed;
    if (name.length === 0) name = probeName.length > 0 ? probeName : Http.host(url);
    const s: Station = {
      id: this.editing === null ? 'local:' + util.generateRandomUUID(true) : this.editing.id,
      name: name,
      url: url,
      logo: this.formLogo.trim(),
      group: StationMeta.normalizeGroup(this.formGroup),
      country: this.editing === null ? '' : this.editing.country,
      source: StationMeta.SOURCE_MANUAL
    };
    const ok = this.editing === null ? this.stations.add(s) : this.stations.update(s);
    this.saving = false;
    if (!ok) {
      this.formError = L.s('radio_duplicate');
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: L.s('radio_added') });
    this.editorOpen = false;
    this.editing = null;
  }

  /// 从目录/精选「加入我的电台」。按当前条目复制一条本地记录(id 换成 local)。
  private addCopy(s: Station): void {
    if (this.stations.containsUrl(s.url)) {
      this.getUIContext().getPromptAction().showToast({ message: L.s('radio_already_added') });
      return;
    }
    const copy: Station = {
      id: 'local:' + util.generateRandomUUID(true),
      name: s.name,
      url: s.url,
      logo: s.logo,
      group: s.group,
      country: s.country,
      source: StationMeta.SOURCE_MANUAL
    };
    this.stations.add(copy);
    this.getUIContext().getPromptAction().showToast({ message: L.s('radio_added') });
  }

  private askDelete(s: Station): void {
    this.pendingDelete = s;
  }

  private deleteMessage(): string {
    return this.pendingDelete === null ? '' : L.f('radio_delete_msg', this.pendingDelete.name);
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
  headerAction() {
    if (this.full) {
      Button() {
        Glyph({ symbol: Sym.plus, dim: 20, color: this.scheme.primary })
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(40).height(40)
      .accessibilityText(L.s('radio_add'))
      .onClick(() => this.openAdd())
    }
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
            // 清空输入 = 回到完整模式的热门,或只搜索模式的提示;不把上一次的结果留在屏上
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
  stationRow(s: Station, mine: boolean) {
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
      // 起播区只给封面与文字:整行 onClick 会让尾部的编辑/删除/加入按钮**冒泡**到这里,
      // 点「编辑」顺手把台开起来。ArkUI 的点击是向上传递的,这里用"只挂在内层"隔开。
      .onClick(() => this.play(s))

      if (this.full) {
        if (mine) {
          Button() {
            Glyph({ symbol: Sym.noteDelete, dim: 18, color: this.scheme.onSurfaceVariant })
          }
          .type(ButtonType.Circle)
          .backgroundColor(Color.Transparent)
          .width(36).height(36)
          .accessibilityText(L.s('radio_delete'))
          .onClick(() => this.askDelete(s))

          Button() {
            Glyph({ symbol: Sym.settings, dim: 18, color: this.scheme.onSurfaceVariant })
          }
          .type(ButtonType.Circle)
          .backgroundColor(Color.Transparent)
          .width(36).height(36)
          .accessibilityText(L.s('radio_edit'))
          .onClick(() => this.openEdit(s))
        } else if (this.stations.containsUrl(s.url)) {
          Glyph({ symbol: Sym.played, dim: 20, color: this.scheme.primary })
            .margin({ right: 8 })
        } else {
          Button() {
            Glyph({ symbol: Sym.plus, dim: 18, color: this.scheme.primary })
          }
          .type(ButtonType.Circle)
          .backgroundColor(Color.Transparent)
          .width(36).height(36)
          .accessibilityText(L.s('radio_add'))
          .onClick(() => this.addCopy(s))
        }
      } else {
        Glyph({ symbol: Sym.playFill, dim: 18, color: this.scheme.onSurfaceVariant })
          .margin({ right: 8 })
      }
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding - 6, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  editorOverlay() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(withAlpha('#000000', 0.45))
        .onClick(() => this.closeEditor())
      Column({ space: 10 }) {
        Text(L.s(this.editing === null ? 'radio_add' : 'radio_edit'))
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .fontColor(this.scheme.onBackground)
          .width('100%')

        TextInput({ placeholder: L.s('radio_name'), text: this.formName })
          .placeholderColor(this.scheme.onSurfaceVariant)
          .fontColor(this.scheme.onBackground)
          .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.10))
          .borderRadius(10)
          .onChange((v: string) => { this.formName = v })

        TextInput({ placeholder: L.s('radio_url'), text: this.formUrl })
          .type(InputType.URL)
          .placeholderColor(this.scheme.onSurfaceVariant)
          .fontColor(this.scheme.onBackground)
          .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.10))
          .borderRadius(10)
          .onChange((v: string) => { this.formUrl = v })

        TextInput({ placeholder: L.s('radio_logo_optional'), text: this.formLogo })
          .type(InputType.URL)
          .placeholderColor(this.scheme.onSurfaceVariant)
          .fontColor(this.scheme.onBackground)
          .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.10))
          .borderRadius(10)
          .onChange((v: string) => { this.formLogo = v })

        Text(L.s('radio_group'))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.groupChip('', L.s('radio_group_none'))
          ForEach(StationMeta.GROUPS, (g: string) => {
            this.groupChip(g, this.groupLabel(g))
          }, (g: string) => g)
        }

        if (this.formError.length > 0) {
          Text(this.formError)
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.error)
            .width('100%')
        }
        if (this.saving) {
          Text(L.s('radio_checking'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .width('100%')
        }

        Row({ space: 22 }) {
          Text(L.s('action_cancel'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .onClick(() => this.closeEditor())
          Text(L.s('action_save'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.primary)
            .onClick(() => { this.save(); })
        }
        .margin({ top: 8 })
        .alignSelf(ItemAlign.End)
      }
      .width('84%')
      .padding({ left: 22, right: 22, top: 22, bottom: 16 })
      .backgroundColor(this.scheme.surface)
      .borderRadius(18)
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  groupChip(g: string, label: string) {
    Text(label)
      .fontSize(TypeScale.label * this.fontScale)
      .fontColor(this.formGroup === g ? this.scheme.onPrimary : this.scheme.onSurfaceVariant)
      .backgroundColor(this.formGroup === g ? this.scheme.primary : withAlpha(this.scheme.onSurfaceVariant, 0.10))
      .borderRadius(14)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => { this.formGroup = g })
  }

  /// 列表内容。顺序:我的 → (搜索态:结果) / (常态:热门 → 精选)。
  @Builder
  body() {
    List({ scroller: this.scroller }) {
      if (this.full) {
        ListItem() {
          this.sectionTitle(L.s('radio_my_stations'))
        }
        if (this.stations.stations.length === 0) {
          ListItem() {
            Text(L.s('radio_empty_my'))
              .fontSize(TypeScale.body * this.fontScale)
              .fontColor(this.scheme.onSurfaceVariant)
              .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 4, bottom: 12 })
          }
        } else {
          ForEach(this.stations.stations, (s: Station) => {
            ListItem() {
              this.stationRow(s, true)
            }
          }, (s: Station) => 'my:' + s.id)
        }
      }

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
              this.stationRow(s, false)
            }
          }, (s: Station) => 'dir:' + s.id)
        }
      } else if (this.full) {
        ListItem() {
          this.sectionTitle(L.s('radio_hot_stations'))
        }
        if (this.popularLoading) {
          ListItem() {
            LoadingBox({ scheme: this.scheme, fontScale: this.fontScale })
              .height(160)
          }
        } else if (this.popularError) {
          ListItem() {
            this.errorRow()
          }
        } else {
          ForEach(this.popular, (s: Station) => {
            ListItem() {
              this.stationRow(s, false)
            }
          }, (s: Station) => 'hot:' + s.id)
        }

        ListItem() {
          this.sectionTitle(L.s('radio_seed_stations'))
        }
        ForEach(this.stations.seedStations(), (s: Station) => {
          ListItem() {
            this.stationRow(s, false)
          }
        }, (s: Station) => 'seed:' + s.id)
      } else {
        ListItem() {
          Text(L.s('radio_search_subtitle'))
            .fontSize(TypeScale.body * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 12, bottom: 12 })
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
        .onClick(() => {
          if (this.searched) this.runSearch();
          else if (this.full) this.loadPopular();
        })
    }
    .width('100%')
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 12 })
  }

  build() {
    Stack() {
      Column() {
        ScreenHeader({
          scheme: this.scheme,
          fontScale: this.fontScale,
          title: L.s('nav_radio'),
          subtitle: L.s(this.full ? 'radio_subtitle' : 'radio_search_subtitle'),
          action: () => { this.headerAction() }
        })
        this.searchBar()
        this.body()
      }
      .width('100%').height('100%')

      if (this.full && this.editorOpen) {
        this.editorOverlay()
      }

      if (this.full && this.pendingDelete !== null) {
        ConfirmDialog({
          scheme: this.scheme,
          fontScale: this.fontScale,
          spec: new ConfirmSpec(L.s('radio_delete'),
            this.deleteMessage(), L.s('radio_delete'),
            () => {
              if (this.pendingDelete !== null) this.stations.remove(this.pendingDelete.id);
              this.pendingDelete = null;
            }),
          onDismiss: () => { this.pendingDelete = null; }
        })
      }
    }
    .width('100%').height('100%')
  }
}
