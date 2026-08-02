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

/// 通用格式化。
enum Fmt {
    static func duration(_ sec: Int) -> String {
        guard sec > 0 else { return "" }
        let m = sec / 60
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
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

/// 频道网格卡片:大封面 + 标题 + 作者,悬停高亮。
struct PodcastCard: View {
    let podcast: Podcast
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SquareArtwork(url: podcast.artworkUrl, corner: 14)
                .shadow(color: .black.opacity(hover ? 0.28 : 0.14),
                        radius: hover ? 12 : 6, y: 4)
            Text(podcast.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !podcast.author.isEmpty {
                Text(podcast.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(hover ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
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

    private var meta: String {
        [showPodcast ? episode.podcastTitle : "",
         Fmt.pubDate(episode.pubDate),
         Fmt.duration(episode.durationSec)]
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onPlay) {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(isCurrent ? accent : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help(playing ? "暂停" : "播放")

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundStyle(isCurrent ? accent : Color.primary)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
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
