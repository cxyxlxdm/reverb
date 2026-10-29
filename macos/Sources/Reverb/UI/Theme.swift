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

    /// 悬停显示小手光标。SwiftUI 没有 pointer 修饰符,只能 NSCursor push/pop;
    /// pushed 标记是防止 hover=false 先于 hover=true 到达时误 pop 别处的光标设置。
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}

private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
            else if !inside, pushed { NSCursor.pop(); pushed = false }
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
        return m >= 60
            ? String(format: NSLocalizedString("%lld 小时 %lld 分", comment: ""), Int64(m / 60), Int64(m % 60))
            : String(format: NSLocalizedString("%lld 分钟", comment: ""), Int64(m))
    }

    /// 集内时刻 `mm:ss`(批注行上的那一秒徽标与写批注弹窗共用;超过一小时就一直往上涨,
    /// 与播放页 `timeText` 同格式 —— 这里要的是"那一秒在第几分钟",不是可读的时长摘要)。
    static func clock(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 去除 HTML 标签与常见实体,得到干净文本(RSS 简介常含 HTML)。
    /// 保留段落/换行:<br> 与块级标签转为换行,避免整段糊成一坨。
    static func plainText(_ raw: String) -> String {
        var s = raw
        // 换行标签 + 块级标签(开/闭)→ 换行,保留结构
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</?(p|div|li|ul|ol|h[1-6]|tr|blockquote|section)[^>]*>",
                                    with: "\n", options: .regularExpression)
        // 去掉其余标签
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&hellip;": "…"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // 行内空白压缩(不动换行);去掉行首尾空格;多余空行收敛为最多一个空行
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
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

/// 远程图片:先查封面磁盘缓存,没有再联网取一份顺手落盘(见 `ArtworkCache`)。
/// 失败按 0.4s 退避重试至多 3 次 —— 冷启动时网络栈偶发未就绪,给一次重试比直接留白好。
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
        // id 绑定 url:换集时重跑;先清空旧图,避免残留上一集封面
        .task(id: url) {
            image = nil
            await load()
        }
    }

    private func load() async {
        guard !url.isEmpty else { return }
        for attempt in 0..<3 {
            if Task.isCancelled { return }
            if let data = await ArtworkCache.shared.data(for: url),
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

extension Episode {
    /// 这一集所属频道的最小描述,用于「点封面直达频道页」。
    ///
    /// 只有单集自带的元信息;频道页会按 `feedUrl` 重新拉完整详情,缺 `author` / 简介无妨。
    /// `feedUrl` 为空时返回 nil —— 老数据可能缺这一格,不判就会把空串塞进导航栈(H187 同一条门)。
    var channelRef: Podcast? {
        guard !feedUrl.isEmpty else { return nil }
        return Podcast(id: feedUrl, title: podcastTitle,
                       author: "", artworkUrl: artworkUrl, feedUrl: feedUrl)
    }
}

/// 单集封面:点一下进这一集所属的频道页。
///
/// 规则与 Android `coverChannelJump` 逐条相同:①本行允许(频道页自己传 `enabled: false`,
/// 否则点一下会在栈上再压一份同一个频道);②`feedUrl` 非空 —— 老数据可能缺,不判就塞空串进路由。
/// 另加一条本端约束:选择模式下必须关掉(那一格点击被勾选占用),由调用方传 `enabled: false`。
///
/// 用 `NavigationLink(value:)` 而不是回调:根 `RootView` 已注册 `Podcast.self` 的 destination,
/// 任何一层的列表都能直接把目标塞进栈,不必把 path 一路透传下来。
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
            .help("进入频道页")
            .accessibilityLabel(Text("进入频道页"))
            .pointingHandCursor()
        } else {
            Artwork(url: episode.artworkUrl, size: size, corner: corner)
        }
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
    /// 这一条**来自哪个目录**。只有搜索结果传(nil = 不画)。
    /// 单集搜索是两路结果拼起来的(Apple 在前、视频站在后),一个表头装不下两个来源,
    /// 所以来源落在**行上** —— 滚到哪一条都看得见它来自哪儿。
    var sourceTag: String? = nil
    /// 封面是否可点进频道页(见 `EpisodeArtworkLink`);频道详情页传 false。
    var coverOpensChannel: Bool = true
    /// 选择模式:整行的点击语义由调用方改成"勾选"(行自身不存这份状态 ——
    /// 与 Android 同一条理由:行会被 Lazy 容器回收,状态留在行里会随滚动丢失)。
    var selecting: Bool = false
    var selected: Bool = false
    var onPlay: () -> Void = {}

    private var playing: Bool { isCurrent && isPlaying }
    /// 已播完且非当前:标题以次要色淡化。
    private var titleColor: Color { isCurrent || selected ? accent : (played ? .secondary : .primary) }

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
            // 封面缩略图:为列表增添色彩,不再单调;当前播放态叠加高亮圈;
            // 选择模式压一枚勾选环(封面的命中区此时只用于勾选,不跳频道)。
            Group {
                if selecting {
                    Artwork(url: episode.artworkUrl, size: 54, corner: 10)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onPlay)
                } else {
                    EpisodeArtworkLink(episode: episode, size: 54, corner: 10,
                                       enabled: coverOpensChannel)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent, lineWidth: isCurrent ? 2 : 0)
            )
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? accent : Color.black.opacity(0.35))
                        .offset(x: 5, y: -5)
                }
            }

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
                if sourceTag != nil || !meta.isEmpty {
                    HStack(spacing: 6) {
                        if let tag = sourceTag {
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                        if !meta.isEmpty {
                            Text(meta)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            // 选择模式里行尾这颗**不显示**(不是禁灰):它在行内自己消费点击,
            // 留着就是「点行尾播放、点行中间勾选」—— 同一行两种语义,用户无从预期
            // (与 Android `Components.kt` 里那三颗行尾按钮同一条理由)。
            if !selecting {
                Button(action: onPlay) {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(isCurrent ? accent : Color.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help(playing ? "暂停" : "播放")
            }
        }
        .padding(.vertical, 16)
        .frame(minHeight: 74)
    }
}

/// 播放模式按钮:点一下在顺序 / 单曲循环 / 随机之间循环切换**这一列**的走法。
///
/// **一颗只管模式,不表播放状态。** 早先那颗是「起播 + 切模式」两件事挤在一个图标槽里,
/// 为此还养过"未起播时画暂停图标"之类的会话状态,结果与全 App 的图标口径相反、首点看不出变化
/// (Android/鸿蒙 2026-09-28 装机报的,见 H118)。macOS 直接按定稿口径实现,没走那段弯路。
/// 起播的入口是「点列表里的某一集」;列空着也照样能设模式 —— 它改的是这一列**以后**怎么播。
///
/// 与 Android `Components.kt PlayModeButton`、鸿蒙 `Components.ets PlayModeButton`
/// 同名同语义,三端改一处要一起改。
struct PlayModeButton: View {
    /// 这一列的身份(`ListTag`);模式按它读写自己那一格。
    let tag: String
    @EnvironmentObject var player: PlayerController

    var body: some View {
        let mode = player.mode(for: tag)
        Button { player.cyclePlayMode(tag) } label: {
            Image(systemName: Self.symbol(for: mode))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)   // 恒为次要色:这颗按钮不再"点亮"
        }
        .buttonStyle(.plain)
        .help(Text(Self.name(for: mode)))      // 悬停提示 = Android 的 contentDescription
    }

    /// 图标三态就是模式本身。
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

/// 一列单集的「多选」状态:进入/退出、已选集合、入队后那句话。
///
/// 三张列表(音阁 / 追更 / 频道页)各持一份 `@StateObject`,互不串味 —— 集合里存的是 id,
/// 而同一个 id 可能同时出现在收藏与下载两列,共用一份就会"在这一列选、在那列入队"。
/// 行本身不存这份状态:行会被 Lazy 容器回收(与 Android `EpisodeBatchBar` 同一条理由)。
@MainActor final class EpisodeSelection: ObservableObject {
    @Published var selecting = false
    @Published var picked = Set<String>()
    @Published private(set) var toast: String?
    private var toastToken = 0

    func toggle(_ ep: Episode) {
        if picked.contains(ep.id) { picked.remove(ep.id) } else { picked.insert(ep.id) }
    }

    func reset() {
        selecting = false
        picked.removeAll()
    }

    /// 把已选的那些交给 `enqueueAll`(一次去重、一次更新导航标记),然后退出选择模式。
    /// 结果必须说出来:入队结果在「待播」里,当前列表看不出任何变化,不提示等于没按上
    /// (Android 用 Toast 说同一句话,这里用顶部的 `TopToast`)。
    ///
    /// - Parameter log: 日志里那一列的名字(「列=追更」「列=频道 <key>」),用来分辨读数。
    func enqueue(from episodes: [Episode], using player: PlayerController, log: String) {
        let chosen = episodes.filter { picked.contains($0.id) }
        let added = player.enqueueAll(chosen)
        Log.i("UI", "批量加入待播 \(log) 选中=\(chosen.count) 新增=\(added)")
        showToast(added == 0
            ? NSLocalizedString("所选都已在待播里", comment: "批量入队全部重复")
            : String(format: NSLocalizedString("已加入待播 %lld 集", comment: "批量入队结果"),
                     Int64(added)))
        reset()
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toastToken == token { toast = nil }
        }
    }
}

/// 多选批量入队的**工具栏**(桌面形态,不做手机那条长按浮条)。
///
/// 为什么不是浮条:桌面没有长按手势的传统,浮条还会压住末行;窗口工具栏是 macOS 里
/// 「选一批东西然后对它们做一件事」的默认落点(Finder、邮件都这样)。
/// 进入选择模式仍然是工具栏上那颗「选择」,退出是「完成」—— 与全选/入队同属一组。
///
/// 已选集合由调用方持有(`@State Set<String>`),这里只改它:
/// 行会被 Lazy 容器回收,状态留在行里会随滚动丢失,而且「全选」要能一次改整列
/// (与 Android `EpisodeBatchBar` 同一条理由)。
struct EpisodeBatchToolbar: ToolbarContent {
    /// 这一列**当前显示的**全部单集(全选按它算,调用方必须传显示的那一份)。
    let episodes: [Episode]
    @Binding var selecting: Bool
    @Binding var picked: Set<String>
    var enqueue: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Text("已选 \(picked.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("全选") { picked = Set(episodes.map(\.id)) }
                .disabled(picked.count >= episodes.count)
            Button("加入待播") { enqueue() }
                .disabled(picked.isEmpty)
            Button("完成") {
                selecting = false
                picked.removeAll()
            }
        }
    }
}

/// 顶部自散的一条结果提示。桌面没有 Toast:`NSUserNotification` 已废弃、
/// 弹 sheet 会把用户从正在做的事里拽出来(批量入队是低风险动作,不值得打断)。
/// 胶囊走 `.regularMaterial`,2 秒后由调用方清空;`allowsHitTesting(false)` 让它不挡任何点击。
struct TopToast: View {
    let text: String?

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: text)
        .allowsHitTesting(false)
    }
}

/// 单集行通用右键菜单:下一个播放 / 加入队列,外加**调用方显式给的那一颗**单集状态项。
///
/// 单集状态项**不再按 `played` 换向**(H192 / `docs/MACOS-GAPS.md` D7):两颗各是一个可选回调,
/// 传哪颗就显示哪颗、文案写死。`played` 的显示(标题压暗 + 打勾)不归这里管,照旧。
/// - `onMarkPlayed`(正向「标记为已播完」)**只有发现页「继续收听」卡传** —— 那一处是全 App
///   唯一的正向入口(卡片按"未播完"过滤,标完即从横条消失;两端同口径,Android 那张卡用的是
///   `DiscoverScreen` 自己的菜单)。
/// - `onMarkUnplayed`(反向「标记为未播完」)**只有 `音阁 · 历史` 的已播完行传**。
///   浏览列不给正向的两条理由见 H192:① 那些列的集大多没进过历史,而 `Stores.swift` 的
///   `markPlayed` 对没有历史条目的 id 直接 return,点了连标题压暗都不会发生;② 少数真生效的
///   (播过、有历史条目)当页也没有回程 —— 想撤必须翻到历史页找同一条。
///
/// **别把这两颗改回"一个布尔开关 + 按状态换向"**:换向表达式本身就是"下一列顺手接出正向"
/// 的通道,写死之后接错只会在 review 里露出来,不会静默上线(`Components.kt` 同一条注释)。
struct EpisodeContextMenu: ViewModifier {
    let episode: Episode
    /// 选择模式里不挂菜单:那三项在批量面前逐条做没有意义,而且右键菜单会抢走
    /// 本该用于勾选的注意力(Android 同一条取舍,见 `Components.kt` 的 `selectionMode` 分支)。
    var enabled: Bool = true
    var onMarkPlayed: (() -> Void)? = nil
    var onMarkUnplayed: (() -> Void)? = nil
    @EnvironmentObject var player: PlayerController

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button {
                    player.playNext(episode)
                } label: { Label("下一个播放", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button {
                    player.enqueue(episode)
                } label: { Label("加入队列", systemImage: "text.append") }
                if onMarkPlayed != nil || onMarkUnplayed != nil {
                    Divider()
                }
                if let action = onMarkPlayed {
                    Button { action() } label: {
                        Label("标记为已播完", systemImage: "checkmark.circle")
                    }
                }
                if let action = onMarkUnplayed {
                    Button { action() } label: {
                        Label("标记为未播完", systemImage: "circle")
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    /// 为单集行附加通用右键菜单。两个 `onMark*` 的给法见 `EpisodeContextMenu` 注释:
    /// **正向只给发现页横条卡,反向只给历史的已播完行**,其余调用点两个都不传。
    func episodeContextMenu(_ episode: Episode, enabled: Bool = true,
                            onMarkPlayed: (() -> Void)? = nil,
                            onMarkUnplayed: (() -> Void)? = nil) -> some View {
        modifier(EpisodeContextMenu(episode: episode, enabled: enabled,
                                    onMarkPlayed: onMarkPlayed,
                                    onMarkUnplayed: onMarkUnplayed))
    }
}

extension View {
    /// 给 sheet 补上 App 主题的配色方案。
    ///
    /// **必须逐个 sheet 声明**:`.preferredColorScheme` 加在根视图上只作用于窗口本身,
    /// sheet 是独立呈现、**不继承**它。漏了的表现是:App 主题设为深色而系统仍是浅色时,
    /// sheet 的背景走主题(深),而其中未显式指定颜色的文字走系统语义色(黑)—— 看不见。
    /// 收听时长页的频道名就是这么丢的。
    func themedSheet(_ settings: SettingsStore) -> some View {
        preferredColorScheme(Theme.colorScheme(settings.themeMode))
    }
}

/// 「离线内容」提示条。当前展示的是磁盘缓存、联网刷新还没成功时显示。
///
/// 刻意做得很轻(一行小字、无图标、无边框):这不是错误,内容是可用的,
/// 只是可能不是最新的 —— 做成警告色反而会让人以为出了问题。
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
