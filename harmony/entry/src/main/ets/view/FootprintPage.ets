import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { appVersionName } from '../util/AppInfo';
import { Stamp, StampStore } from '../store/StampStore';
import { AppContainer } from '../AppContainer';
import { TopBar, EmptyHint, Glyph, GlyphImage, Sym } from './Widgets';
import { builderToPng, saveToGallery } from './MomentCard';
import { Files } from '../util/Files';
import { Log } from '../util/Logger';
import type common from '@ohos.app.ability.common';

/// 听觉足迹:把所有听觉印记以水墨印章网格呈现。
/// 对应 Android `StampsScreen.kt` / macOS `FootprintView.swift`。
@Component
export struct FootprintPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 印记会在播放页被增删,须被观察(同 H27)
  @ObjectLink stamps: StampStore;
  onBack: () => void = () => {};

  @State hint: string = '';
  private app: AppContainer = AppContainer.get();

  build() {
    Column() {
      // 页头右侧两个动作,与 Android StampsScreen 一致:保存到相册(Download)、分享(Share)。
      // 仅有印记时才出现。原先鸿蒙这页没有任何导出入口 —— 海报功能等于没有出口。
      Row() {
        TopBar({
          scheme: this.scheme, fontScale: this.fontScale,
          title: L.s('footprint_title'), onBack: () => this.onBack()
        })
          .layoutWeight(1)
        if (this.stamps.stamps.length > 0) {
          Row() {
            Glyph({ symbol: Sym.download, dim: 21, color: this.scheme.onSurfaceVariant })
          }
          .width(40).height(40).justifyContent(FlexAlign.Center)
          .onClick(() => { this.savePoster(); })
          Row() {
            Glyph({ symbol: Sym.share, dim: 21, color: this.scheme.primary })
          }
          .width(40).height(40).justifyContent(FlexAlign.Center)
          .onClick(() => { this.sharePoster(); })
        }
      }
      .width('100%')
      .padding({ right: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(TypeScale.caption * this.fontScale)
          .fontColor(this.scheme.primary)
          .padding({ left: Metrics.pagePadding, bottom: 6 })
      }
      if (this.stamps.stamps.length === 0) {
        EmptyHint({
          scheme: this.scheme, fontScale: this.fontScale,
          text: L.s('footprint_empty')
        })
          .layoutWeight(1)
      } else {
        Scroll() {
          Grid() {
            ForEach(this.stamps.stamps, (s: Stamp) => {
              GridItem() {
                this.chip(s)
              }
            }, (s: Stamp) => s.episodeId)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(12)
          .rowsGap(12)
          .padding(Metrics.pagePadding)
          .height(Math.ceil(this.stamps.stamps.length / 3) * 180 + 20)
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
  }

  /// 海报:标题 + 全部印章三列网格。**离屏**渲染成整张图(网格可滚动,按 id 截屏只能拿到一屏)。
  @Builder
  poster() {
    Column({ space: 14 }) {
      Text(L.s('footprint_title'))
        .fontSize(TypeScale.titleLarge)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.scheme.onBackground)
      Grid() {
        ForEach(this.stamps.stamps, (s: Stamp) => {
          GridItem() {
            this.chip(s)
          }
        }, (s: Stamp) => s.episodeId)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
      .width(340)
      .height(Math.ceil(this.stamps.stamps.length / 3) * 150)
      Text(L.f('about_line', appVersionName()))
        .fontSize(TypeScale.caption)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .padding(20)
    .width(380)
    .backgroundColor(this.scheme.background)
    .alignItems(HorizontalAlign.Center)
  }

  private async makePoster(): Promise<string | null> {
    const ui = this.getUIContext();
    const ctx = ui.getHostContext() as common.UIAbilityContext;
    return await builderToPng(ui, ctx, () => { this.poster() }, 'reverb-footprint.png');
  }

  private async savePoster(): Promise<void> {
    const png = await this.makePoster();
    if (png === null) {
      this.hint = L.s('moment_failed');
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ok = await saveToGallery(ctx, png);
    this.hint = ok ? L.s('moment_saved') : L.s('moment_saved_partial');
    Log.i('Footprint', this.hint);
  }

  private async sharePoster(): Promise<void> {
    const png = await this.makePoster();
    if (png === null) {
      this.hint = L.s('moment_failed');
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await Files.shareImage(ctx, L.s('footprint_share'), png);
  }

  @Builder
  chip(s: Stamp) {
    Column({ space: 6 }) {
      // 水墨印章:圆角方块 + 大号印字
      Stack() {
        Row()
          .width('100%').aspectRatio(1)
          .backgroundColor(withAlpha(this.scheme.primary, 0.14))
          .borderRadius(14)
        Text(s.seal)
          .fontSize(TypeScale.displaySmall * this.fontScale)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.scheme.primary)
      }
      .width('100%').aspectRatio(1)

      Text(s.title)
        .fontSize(TypeScale.caption * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
  }
}
