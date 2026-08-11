import { Scheme, TypeScale, Metrics, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { ChannelListen, listenedMsOf } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { TopBar, EmptyHint, Artwork } from './Widgets';
import { formatListenDuration } from './Components';

/// 收听时长:按频道累计时长从多到少排序,横条可视化(越长越长,最长者满宽)。
/// 对应 Android `ListenStatsScreen.kt` / macOS `ListenStatsView.swift`。
@Component
export struct ListenStatsPage {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  onBack: () => void = () => {};

  private app: AppContainer = AppContainer.get();

  private rows(): ChannelListen[] {
    return this.app.listenStats.stats.filter((c: ChannelListen) => listenedMsOf(c) > 0);
  }

  private maxMs(): number {
    const r = this.rows();
    return r.length === 0 ? 1 : Math.max(1, listenedMsOf(r[0]));
  }

  build() {
    Column() {
      TopBar({
        scheme: this.scheme, fontScale: this.fontScale,
        title: L.s('listen_stats_title'), onBack: () => this.onBack()
      })
      if (this.rows().length === 0) {
        EmptyHint({ scheme: this.scheme, fontScale: this.fontScale, text: L.s('listen_stats_empty') })
          .layoutWeight(1)
      } else {
        List({ space: 18 }) {
          ForEach(this.rows(), (c: ChannelListen) => {
            ListItem() {
              this.row(c)
            }
          }, (c: ChannelListen) => c.key)
        }
        .scrollBar(BarState.Off)
        .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 8, bottom: 20 })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  row(c: ChannelListen) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Artwork({ scheme: this.scheme, url: c.artworkUrl, dim: 40, corner: 8 })
        Text(c.title.length > 0 ? c.title : L.s('unknown_channel'))
          .fontSize(TypeScale.titleSmall * this.fontScale)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.scheme.onBackground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(formatListenDuration(Math.floor(listenedMsOf(c) / 1000)))
          .fontSize(TypeScale.label * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 横条:底槽 + 按比例填充的强调色
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%').height(10)
          .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.15))
          .borderRadius(5)
        Row()
          .width(`${Math.max(2, listenedMsOf(c) / this.maxMs() * 100)}%`)
          .height(10)
          .backgroundColor(this.scheme.primary)
          .borderRadius(5)
      }
      .width('100%').height(10)
    }
    .width('100%')
  }
}
