import SwiftUI
import AppKit

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

extension View {
    /// 去掉键盘焦点环(首次启动时某控件被自动聚焦出现的蓝框)。macOS 14+ 生效。
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, *) { self.focusEffectDisabled() } else { self }
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
        return m >= 60
            ? String(format: NSLocalizedString("%lld 小时 %lld 分", comment: ""), Int64(m / 60), Int64(m % 60))
            : String(format: NSLocalizedString("%lld 分钟", comment: ""), Int64(m))
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
        if let d = parseDate(s) {
            let out = DateFormatter()
            out.locale = Locale.autoupdatingCurrent
            out.dateFormat = NSLocalizedString("yyyy年M月d日", comment: "date format")
            return out.string(from: d)
        }
        return String(s.prefix(16))
    }

    /// RFC822 / ISO8601 pubDate 解析为 Date(用于「最新」排序),失败返回 nil。
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

/// 带重试 + URLCache 缓存的远程图片加载。修复冷启动时 AsyncImage 偶发失败(不重试)导致封面空白。
/// URLSession.shared 默认走内存/磁盘缓存,重开即命中;失败按 0.4s 退避重试至多 3 次。
struct RemoteImage<Placeholder: View>: View {
    let url: String
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        // id 绑定 url:换集时重跑;先清空旧图,避免残留上一集封面(URLCache 使重载很快)
        .task(id: url) {
            image = nil
            await load()
        }
    }

    private func load() async {
        guard !url.isEmpty, let u = URL(string: url) else { return }
        for attempt in 0..<3 {
            if Task.isCancelled { return }
            if let data = try? await URLSession.shared.data(from: u).0,
               let img = NSImage(data: data) {
                if Task.isCancelled { return } // 换集后旧任务已取消,勿写回旧图
                image = img
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = attempt
        }
    }
}

/// 封面图:圆角 + 占位。固定尺寸,用于播放条 / 详情头部 / 单集行。
struct Artwork: View {
    let url: String
    var size: CGFloat = 56
    var corner: CGFloat = 8

    var body: some View {
        RemoteImage(url: url) { Rectangle().fill(.quaternary) }
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
                Rectangle().fill(.quaternary)
                Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(.tertiary)
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
    var showDate: Bool = false      // 「最新」等场景在频道名之外再显示发布日期
    var played: Bool = false
    var accent: Color = .accentColor
    var onPlay: () -> Void = {}

    private var playing: Bool { isCurrent && isPlaying }
    /// 已播完且非当前:标题以次要色淡化。
    private var titleColor: Color { isCurrent ? accent : (played ? .secondary : .primary) }

    /// 安静的元信息:频道名(如需)· 发布日期(如需/非频道场景默认显示)· 时长。
    private var meta: String {
        var parts: [String] = []
        if showPodcast { parts.append(episode.podcastTitle) }
        if showDate || !showPodcast { parts.append(Fmt.pubDate(episode.pubDate)) }
        parts.append(Fmt.duration(episode.durationSec))
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
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
                HStack(alignment: .top, spacing: 6) {
                    if played {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                            .help("已播完")
                    }
                    Text(episode.title)
                        .font(.headline).fontWeight(.medium)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .foregroundStyle(titleColor)
                }
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

/// 单集行通用右键菜单:下一个播放 / 加入队列 / 标记已播完切换。
/// 依赖注入的 env(历史)与 player(队列)。
struct EpisodeContextMenu: ViewModifier {
    let episode: Episode
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                player.playNext(episode)
            } label: { Label("下一个播放", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button {
                player.enqueue(episode)
            } label: { Label("加入队列", systemImage: "text.append") }
            Divider()
            let played = env.history.isPlayed(episode.id)
            Button {
                env.history.markPlayed(episode.id, !played)
            } label: {
                Label(played ? "标记为未播完" : "标记为已播完",
                      systemImage: played ? "circle" : "checkmark.circle")
            }
        }
    }
}

extension View {
    /// 为单集行附加通用右键菜单(队列 / 已播完)。
    func episodeContextMenu(_ episode: Episode) -> some View {
        modifier(EpisodeContextMenu(episode: episode))
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
