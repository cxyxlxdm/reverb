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
}

/// 封面图:AsyncImage + 圆角 + 占位。
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

/// 频道行。
struct PodcastRow: View {
    let podcast: Podcast
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkUrl, size: 52, corner: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title).font(.body).lineLimit(1)
                Text(podcast.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// 单集行:左侧播放态圆点 + 标题 + 元信息。
struct EpisodeRow: View {
    let episode: Episode
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showPodcast: Bool = false
    var onPlay: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Image(systemName: isCurrent && isPlaying ? "pause.circle.fill" : "play.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).font(.body).lineLimit(2)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                let meta = [showPodcast ? episode.podcastTitle : "", durationText(episode.durationSec)]
                    .filter { !$0.isEmpty }.joined(separator: "  ·  ")
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }

    private func durationText(_ sec: Int) -> String {
        guard sec > 0 else { return "" }
        let m = sec / 60
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
    }
}
