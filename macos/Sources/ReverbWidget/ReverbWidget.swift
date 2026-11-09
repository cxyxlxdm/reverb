import SwiftUI
import WidgetKit
import AppKit
import WidgetContract

/// 「继续收听」桌面卡片(WidgetKit,macOS 端)。
///
/// 与 iOS 那份(`ios/ReverbWidget/ReverbWidget.swift`)是**同一套内容与三档排法**,
/// 差别只在两端各自能拿到什么:
///  - 封面:`NSImage` 而不是 `UIImage`;
///  - 背景:`containerBackground` 是 macOS 14 起的 API,本包最低 13 —— 低版本退回 `.background`;
///  - 数据目录:macOS 没有 App Group(ad-hoc 签名没有 Team ID),改读
///    `~/Library/Application Support/Reverb/widget`,见 `WidgetContract.WidgetShared.containerURL`。
///
/// 卡片正文不在这里本地化:`label` / 空态文案 / `直播` 都由 App 按当前界面语言写进
/// `widget_state.json`。扩展自己的 `.lproj` 只负责画廊里那两行(简中是基础语言,键名即简中文案)。
///
/// 时间线策略是 `.never`:每次更新都由 App 主动 `WidgetCenter.reloadAllTimelines()` 触发
/// (见 `WidgetBridge.swift`),与另三端「App 推、卡片不排期」同口径。
@main
struct ReverbWidgetBundle: WidgetBundle {
    var body: some Widget {
        ReverbWidget()
    }
}

struct ReverbEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
    let art: NSImage?
}

struct ReverbProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReverbEntry {
        ReverbEntry(date: Date(), state: ReverbProvider.sample, art: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReverbEntry) -> Void) {
        completion(ReverbProvider.load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReverbEntry>) -> Void) {
        completion(Timeline(entries: [ReverbProvider.load()], policy: .never))
    }

    /// 读 App 写的那一份。**任何一步失败都退回空态**,不抛错、不留半张卡。
    static func load() -> ReverbEntry {
        guard let container = WidgetShared.containerURL else {
            return ReverbEntry(date: Date(), state: WidgetProviderDefaults.emptyState, art: nil)
        }
        let stateData = try? Data(contentsOf: WidgetShared.stateURL(container))
        var state = stateData.flatMap { try? JSONDecoder().decode(WidgetState.self, from: $0) }
            ?? WidgetProviderDefaults.emptyState
        var art: NSImage? = nil
        if !state.art.isEmpty {
            art = NSImage(contentsOf: WidgetShared.artURL(container))
        }
        // 文案与图片必须成对:JSON 说"有集"但封面文件被清过,就当没封面,不显示破图
        state.art = art == nil ? "" : state.art
        return ReverbEntry(date: Date(), state: state, art: art)
    }

    /// 画廊预览用。**故意给一条假数据**:用户第一次看到卡片应该知道"这里会显示什么"。
    static var sample: WidgetState {
        var s = WidgetState()
        s.label = NSLocalizedString("继续收听", comment: "卡片顶部小字")
        s.title = NSLocalizedString("余音 · 继续收听", comment: "卡片预览标题")
        s.podcast = NSLocalizedString("上次听到哪一集，会出现在这里", comment: "卡片预览副标题")
        s.time = "12:34 / 45:00"
        s.percent = 28
        s.hasProgress = true
        s.empty = false
        return s
    }
}

/// 空态默认值。App 还没写过数据(刚装、还没听过)时用。
enum WidgetProviderDefaults {
    static var emptyState: WidgetState {
        var s = WidgetState()
        s.label = NSLocalizedString("继续收听", comment: "卡片顶部小字")
        s.title = NSLocalizedString("挑一集开始听", comment: "卡片空态标题")
        s.podcast = NSLocalizedString("上次听到哪一集，会出现在这里", comment: "卡片空态副标题")
        s.empty = true
        return s
    }
}

struct ReverbWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReverbContinueListening", provider: ReverbProvider()) { entry in
            ReverbWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("余音 · 继续收听"))
        .description(Text("显示上次听到的节目与进度，点一下接着听"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - 视图

private struct Palette {
    let bg: Color
    let text: Color
    let sub: Color
    let accent: Color
    let track: Color

    static func of(dark: Bool) -> Palette {
        dark
            ? Palette(bg: Color(hex: 0x161D20), text: Color(hex: 0xF2F2ED),
                      sub: Color(hex: 0x9AA8A6), accent: Color(hex: 0x7FD1C0),
                      track: Color(hex: 0x1F2A2E))
            : Palette(bg: Color(hex: 0xFCFAF4), text: Color(hex: 0x1B2426),
                      sub: Color(hex: 0x66716F), accent: Color(hex: 0x3F8A7C),
                      track: Color(hex: 0xE7E0D1))
    }
}

private extension Color {
    /// 与另三端逐字对齐的十六进制色。不走 assets:卡片只需要这五个值,
    /// 放进目录反而多一处要跟着主题改的地方。
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// 卡片底色。macOS 14 起必须走 `containerBackground`,否则系统按自己的材料画底;
/// 13 上没有这个 API,直接铺一层背景(卡片的圆角与内缩由系统负责)。
private struct WidgetBackground: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.containerBackground(for: .widget) { color }
        } else {
            content.background(color)
        }
    }
}

struct ReverbWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReverbEntry

    private var palette: Palette { Palette.of(dark: entry.state.dark) }

    var body: some View {
        Group {
            switch family {
            case .systemLarge: largeLayout
            case .systemMedium: mediumLayout
            default: smallLayout
            }
        }
        .modifier(WidgetBackground(color: palette.bg))
        .widgetURL(WidgetShared.playerURL(id: entry.state.id))
    }

    // MARK: 三档排法

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            artView(corner: 10)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
            labelText(size: 9)
                .padding(.top, 7)
            titleText(size: 12, lines: 2)
                .padding(.top, 2)
            Spacer(minLength: 0)
            if entry.state.hasProgress { progressBar }
            if !entry.state.time.isEmpty {
                Text(entry.state.time)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.sub)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
        }
        .padding(12)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                artView(corner: 8).frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 2) {
                    labelText(size: 9)
                    titleText(size: 15, lines: 2)
                        .padding(.top, 2)
                    Text(entry.state.podcast)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.sub)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if entry.state.hasProgress { progressBar }
            if !entry.state.time.isEmpty {
                Text(entry.state.time)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.sub)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
        }
        .padding(13)
    }

    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            artView(corner: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            labelText(size: 10)
                .padding(.top, 11)
            titleText(size: 17, lines: 2)
                .padding(.top, 3)
            Text(entry.state.podcast)
                .font(.system(size: 12))
                .foregroundStyle(palette.sub)
                .lineLimit(1)
                .padding(.top, 3)
            if entry.state.hasProgress { progressBar.padding(.top, 3) }
            if !entry.state.time.isEmpty {
                Text(entry.state.time)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.sub)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
        }
        .padding(14)
    }

    // MARK: 零件

    /// 封面。空态(或封面没落盘)时退回一个波形符号 —— 空卡也要是一张"完整的设计"。
    @ViewBuilder
    private func artView(corner: CGFloat) -> some View {
        if let art = entry.art {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(palette.track)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
        }
    }

    @ViewBuilder
    private func labelText(size: CGFloat) -> some View {
        if !entry.state.label.isEmpty {
            Text(entry.state.label)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(palette.accent)
                .lineLimit(1)
        }
    }

    private func titleText(size: CGFloat, lines: Int) -> some View {
        Text(entry.state.title)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(palette.text)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 进度条。`Gauge` / `ProgressView` 在卡片里各版本样貌不一,所以自己画两条。
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: geo.size.width * CGFloat(max(0, min(100, entry.state.percent))) / 100)
            }
        }
        .frame(height: 3)
    }
}
