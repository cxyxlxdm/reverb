import SwiftUI

/// 配色方案:青瓷 / 黛蓝 / 绯红 / 竹青(梁金为强调)。与 Android 版一致。
struct AccentPalette {
    let name: String
    let color: Color
}

enum Theme {
    static let accents: [AccentPalette] = [
        AccentPalette(name: "青瓷", color: Color(red: 0.30, green: 0.56, blue: 0.49)),
        AccentPalette(name: "黛蓝", color: Color(red: 0.18, green: 0.43, blue: 0.60)),
        AccentPalette(name: "绯红", color: Color(red: 0.69, green: 0.32, blue: 0.31)),
        AccentPalette(name: "竹青", color: Color(red: 0.31, green: 0.56, blue: 0.26))
    ]
    static let gold = Color(red: 0.91, green: 0.78, blue: 0.47)

    static func accent(_ index: Int) -> Color {
        accents[min(max(index, 0), accents.count - 1)].color
    }

    /// 主题:0 跟随系统 /1 浅色 /2 深色 /3 纯白。
    static func colorScheme(_ mode: Int) -> ColorScheme? {
        switch mode {
        case 1, 3: return .light
        case 2: return .dark
        default: return nil
        }
    }
}

/// 统一的间距 / 版心尺度。以留白而非分隔线区隔内容。
enum Metrics {
    static let pagePadding: CGFloat = 32      // 页面水平内边距
    static let topPadding: CGFloat = 24        // 页面顶部内边距
    static let sectionSpacing: CGFloat = 28    // 区块之间的间距
    static let gridSpacing: CGFloat = 24       // 网格卡片间距
    static let rowSpacing: CGFloat = 14         // 行内元素间距
    static let contentMaxWidth: CGFloat = 1080  // 宽窗下的最大版心
    static let cardMin: CGFloat = 210           // 网格卡片最小宽度
    static let cardMax: CGFloat = 260           // 网格卡片最大宽度
}

/// 通用格式化。
enum Fmt {
    static func duration(_ sec: Int) -> String {
        guard sec > 0 else { return "" }
        let m = sec / 60
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
    }

    /// 去除 HTML 标签与常见实体,得到干净纯文本(RSS 简介常含 HTML)。
    static func plainText(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&hellip;": "…"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 尽力把 RSS 的 pubDate 解析为中文短日期,失败则原样截断。
    static func pubDate(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        let candidates = ["EEE, dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ",
                          "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        for f in candidates {
            parser.dateFormat = f
            if let d = parser.date(from: s) {
                let out = DateFormatter()
                out.locale = Locale(identifier: "zh_CN")
                out.dateFormat = "yyyy年M月d日"
                return out.string(from: d)
            }
        }
        return String(s.prefix(16))
    }
}

/// 封面图:AsyncImage + 圆角 + 占位。固定尺寸,用于播放条 / 详情头部等。
struct Artwork: View {
    let url: String
    var size: CGFloat = 56
    var corner: CGFloat = 8

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// 自适应方形封面:随容器宽度铺满,保持正方形。用于网格卡片。
struct SquareArtwork: View {
    let url: String
    var corner: CGFloat = 14

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "waveform").font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// 频道网格卡片:大封面 + 单行标题 + 单行作者。无边框无底色,仅封面阴影随悬停微涨。
struct PodcastCard: View {
    let podcast: Podcast
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SquareArtwork(url: podcast.artworkUrl, corner: 14)
                .shadow(color: .black.opacity(hover ? 0.22 : 0.10),
                        radius: hover ? 14 : 7, y: hover ? 6 : 3)
                .scaleEffect(hover ? 1.01 : 1)
            Text(podcast.title)
                .font(.headline).fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !podcast.author.isEmpty {
                Text(podcast.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.18), value: hover)
    }
}

/// 宽松单集行:显眼的圆形播放按钮 + 标题 + 元信息。
/// 播放按钮与可点击的标题区左右分区,互不重叠,触发可靠。
struct RoomyEpisodeRow: View {
    let episode: Episode
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showPodcast: Bool = false
    var accent: Color = .accentColor
    var onPlay: () -> Void = {}

    private var playing: Bool { isCurrent && isPlaying }

    /// 最多两条安静的元信息:节目名(如需) + 时长,或 日期 + 时长。
    private var meta: String {
        let items = showPodcast
            ? [episode.podcastTitle, Fmt.duration(episode.durationSec)]
            : [Fmt.pubDate(episode.pubDate), Fmt.duration(episode.durationSec)]
        return items.filter { !$0.isEmpty }.prefix(2).joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 16) {
            // 封面缩略图:为列表增添色彩,不再单调;当前播放态叠加高亮圈
            Artwork(url: episode.artworkUrl, size: 54, corner: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent, lineWidth: isCurrent ? 2 : 0)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(episode.title)
                    .font(.headline).fontWeight(.medium)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .foregroundStyle(isCurrent ? accent : Color.primary)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            Button(action: onPlay) {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(isCurrent ? accent : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help(playing ? "暂停" : "播放")
        }
        .padding(.vertical, 16)
        .frame(minHeight: 74)
    }
}

/// macOS 13 兼容的空 / 加载态占位,居中。
struct StateView: View {
    var loading: Bool = false
    var symbol: String = "tray"
    var text: String

    var body: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView()
                Text("加载中…").font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
}
