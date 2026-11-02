import SwiftUI
import UIKit

/// 配色方案:青瓷 / 黛蓝 / 绯红 / 竹青(梁金为强调)。与 Android / macOS 一致。
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
    /// 纯白在手机上仍按浅色处理 —— 触屏没有桌面那种"窗口底色"要压成纯白。
    static func colorScheme(_ mode: Int) -> ColorScheme? {
        switch mode {
        case 1, 3: return .light
        case 2: return .dark
        default: return nil
        }
    }
}

/// 统一的间距尺度。手机版比桌面窄:页面内边距 16,网格两列。
enum Metrics {
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let gridSpacing: CGFloat = 12
    static let cardMin: CGFloat = 150
    static let contentMaxWidth: CGFloat = 720
}

/// 通用格式化。与 macOS `Fmt` 同一口径(日期键、时长键都走同一份 .strings)。
enum Fmt {
    static func duration(_ sec: Int) -> String {
        guard sec > 0 else { return "" }
        let m = sec / 60
        return m >= 60
            ? String(format: NSLocalizedString("%lld 小时 %lld 分", comment: ""), Int64(m / 60), Int64(m % 60))
            : String(format: NSLocalizedString("%lld 分钟", comment: ""), Int64(m))
    }

    static func clock(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 播放页的大时间戳:时:分:秒,超过一小时也不缩成分钟。
    static func playClock(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func plainText(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</?(p|div|li|ul|ol|h[1-6]|tr|blockquote|section)[^>]*>",
                                   with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&hellip;": "…"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pubDate(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if let d = parseDate(s) {
            let out = DateFormatter()
            out.locale = Locale.autoupdatingCurrent
            out.dateFormat = NSLocalizedString("yyyy年M月d日", comment: "date format")
            return out.string(from: d)
        }
        return String(s.prefix(16))
    }

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let candidates = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z",
                          "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        for f in candidates {
            parser.dateFormat = f
            if let d = parser.date(from: s) { return d }
        }
        return nil
    }
}

/// 远程图片:先查封面磁盘缓存,没有再联网取一份顺手落盘。
/// 与 macOS 版同一条缓存(同一套文件格式),失败按 0.4s 退避重试至多 3 次。
struct RemoteImage<Placeholder: View>: View {
    let url: String
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard !url.isEmpty, URL(string: url) != nil else { return }
            var attempt = 0
            while attempt < 3 {
                if let data = await ArtworkCache.shared.data(for: url),
                   let img = UIImage(data: data) {
                    if Task.isCancelled { return }
                    image = img
                    return
                }
                attempt += 1
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}

/// 封面图:圆角 + 占位。固定尺寸,用于播放条 / 详情头部 / 单集行。
struct Artwork: View {
    let url: String
    var size: CGFloat = 56
    var corner: CGFloat = 8

    var body: some View {
        RemoteImage(url: url) {
            ZStack {
                Rectangle().fill(Color(.tertiarySystemFill))
                Image(systemName: "waveform").foregroundStyle(.tertiary)
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
        RemoteImage(url: url) {
            ZStack {
                Rectangle().fill(Color(.tertiarySystemFill))
                Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// 频道网格卡片:大封面 + 标题 + 作者。
struct PodcastCard: View {
    let podcast: Podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SquareArtwork(url: podcast.artworkUrl, corner: 12)
                .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
            Text(podcast.title)
                .font(.subheadline).fontWeight(.medium)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !podcast.author.isEmpty {
                Text(podcast.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}

extension Episode {
    /// 这一集所属频道的最小描述,用于「点封面直达频道页」。`feedUrl` 为空时返回 nil
    /// —— 老数据可能缺这一格,不判就会把空串塞进导航栈(H187 同一条门)。
    var channelRef: Podcast? {
        guard !feedUrl.isEmpty else { return nil }
        return Podcast(id: feedUrl, title: podcastTitle,
                       author: "", artworkUrl: artworkUrl, feedUrl: feedUrl)
    }
}

/// 单集封面:点一下进这一集所属的频道页。
struct EpisodeArtworkLink: View {
    let episode: Episode
    var size: CGFloat = 54
    var corner: CGFloat = 10
    var enabled: Bool = true

    private var channel: Podcast? { enabled ? episode.channelRef : nil }

    var body: some View {
        if let channel {
            NavigationLink(value: channel) {
                Artwork(url: episode.artworkUrl, size: size, corner: corner)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("进入频道页"))
        } else {
            Artwork(url: episode.artworkUrl, size: size, corner: corner)
        }
    }
}

/// 宽松单集行:圆形播放键 + 标题 + 元信息;长按给出收藏 / 待播 / 已播等动作。
struct RoomyEpisodeRow: View {
    let episode: Episode
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showPodcast: Bool = false
    var showDate: Bool = false
    var played: Bool = false
    var accent: Color = .accentColor
    var sourceTag: String? = nil
    var coverOpensChannel: Bool = true
    var onPlay: () -> Void = {}
    var onLongPress: (() -> Void)? = nil

    private var playing: Bool { isCurrent && isPlaying }
    private var titleColor: Color { isCurrent ? accent : (played ? .secondary : .primary) }

    private var meta: String {
        var parts: [String] = []
        if showPodcast { parts.append(episode.podcastTitle) }
        if showDate || !showPodcast { parts.append(Fmt.pubDate(episode.pubDate)) }
        parts.append(Fmt.duration(episode.durationSec))
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            EpisodeArtworkLink(episode: episode, size: 54, corner: 10, enabled: coverOpensChannel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent, lineWidth: isCurrent ? 2 : 0)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 5) {
                    if played && !episode.isLive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    Text(episode.title)
                        .font(.headline).fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundStyle(titleColor)
                }
                HStack(spacing: 5) {
                    if let tag = sourceTag {
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    if episode.isLive {
                        Text("直播")
                            .font(.caption2)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(accent.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4))
                    } else if !meta.isEmpty {
                        Text(meta)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
            .accessibilityLabel(playing ? Text("暂停") : Text("播放"))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            EpisodeActionMenu(episode: episode, onLongPress: onLongPress)
        }
    }
}

/// 单集的长按菜单。视频集(伪地址)在别处承诺不了「下载」,这里也不出现;
/// 直播流不产生收藏/历史/待播,只留「关闭」语义的那条都不给。
struct EpisodeActionMenu: View {
    let episode: Episode
    var onLongPress: (() -> Void)? = nil
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        if !episode.isLive {
            Button {
                env.favorites.toggle(episode)
            } label: {
                Label(env.favorites.isFavorite(episode.id) ? "取消收藏" : "收藏",
                      systemImage: env.favorites.isFavorite(episode.id) ? "heart.slash" : "heart")
            }
            Button {
                player.enqueue(episode)
            } label: {
                Label("加入待播", systemImage: "text.badge.plus")
            }
            Button {
                player.playNext(episode)
            } label: {
                Label("下一集播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            if env.history.history.contains(where: { $0.episode.id == episode.id }) {
                Button {
                    env.history.markPlayed(episode.id, !env.history.isPlayed(episode.id))
                } label: {
                    Label(env.history.isPlayed(episode.id) ? "标记为未播完" : "标记为已播完",
                          systemImage: env.history.isPlayed(episode.id) ? "arrow.uturn.backward" : "checkmark.circle")
                }
            }
            if !BilibiliSource.isPseudo(episode.audioUrl) {
                if downloads.contains(episode.id) {
                    Button(role: .destructive) {
                        downloadManager.delete(episode.id)
                    } label: {
                        Label("删除离线文件", systemImage: "trash")
                    }
                } else if !downloadManager.isDownloading(episode.id) {
                    Button {
                        downloadManager.download(episode)
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        if let onLongPress {
            Button(action: onLongPress) {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// 播放模式按钮:点一下在顺序 / 单曲循环 / 随机之间循环切换**这一列**的走法。
struct PlayModeButton: View {
    let tag: String
    @EnvironmentObject var player: PlayerController

    var body: some View {
        let mode = player.mode(for: tag)
        Button { player.cyclePlayMode(tag) } label: {
            Image(systemName: Self.symbol(for: mode))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(Text(Self.name(for: mode)))
    }

    private static func symbol(for mode: PlayMode) -> String {
        switch mode {
        case .sequential: return "list.bullet"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    private static func name(for mode: PlayMode) -> LocalizedStringKey {
        switch mode {
        case .sequential: return "顺序播放"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }
}

/// 单集下载控制:未下载(下载图标)→ 下载中(进度环)→ 已下载(勾选,点击删除需确认)。
struct EpisodeDownloadButton: View {
    let episode: Episode
    var accent: Color = .accentColor

    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if BilibiliSource.isPseudo(episode.audioUrl) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .opacity(0.4)
                    .accessibilityLabel(Text("下载不可用"))
            } else if downloads.contains(episode.id) {
                Button { confirmDelete = true } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("已下载"))
                .confirmationDialog("删除此单集的离线文件?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除", role: .destructive) { downloadManager.delete(episode.id) }
                    Button("取消", role: .cancel) {}
                }
            } else if downloadManager.isDownloading(episode.id) {
                ProgressView(value: downloadManager.progress[episode.id] ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Button { downloadManager.download(episode) } label: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("下载"))
                .disabled(episode.audioUrl.isEmpty)
            }
        }
        .font(.system(size: 20))
        .frame(width: 30, height: 30)
    }
}

/// 「离线内容」提示条:当前展示的是磁盘缓存、联网刷新还没成功时显示。
struct OfflineNotice: View {
    let cachedAt: Date

    var body: some View {
        Text(String(format: NSLocalizedString("离线内容 · 上次更新 %@", comment: ""),
                    Self.formatter.string(from: cachedAt)))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// 空 / 加载态占位,居中。
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
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }
}

/// 顶部一次性提示(iOS 用轻量胶囊,不抢导航栏)。
struct TopToast: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}