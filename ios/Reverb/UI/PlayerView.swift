import SwiftUI
import UIKit

/// 全屏播放页:封面 + 进度 + 传输控制 + 倍速/收藏/睡眠/印记/批注/逐字稿。
///
/// 与 macOS 版同一套播放语义,布局改成触屏形态:简介与逐字稿各自成 sheet,
/// 不再做桌面那条横滑轮播(手机上横滑与返回手势打架,且一屏放不下三页)。
struct PlayerView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var showStamps = false
    @State private var showNote = false
    /// 按下「写批注」那一下冻结的时间与那一集:弹层开着时播放器还在走、也可能换集,
    /// 用实时值会把批注挂到错误的位置或错误的一集上(与 macOS 同一条门)。
    @State private var notePosMs = 0
    @State private var noteEpisode: Episode?
    @State private var noteDraft = ""
    @State private var showTranscript = false
    @State private var showQueue = false
    @State private var showNotes = false
    /// 章表弹层。手机上用一个 sheet(与逐字稿/简介同一种容器),不用 popover。
    @State private var showChapters = false
    @State private var channel: Podcast?
    @State private var noteParagraphs: [String] = []
    @State private var noteForEpisode = ""
    /// 剪藏同样要冻结「按下那一刻」的集与位置:渲染封面要等一次网络/磁盘读,
    /// 用实时值会在等待期间换成下一集或往后跑几秒(与批注同一条门)。
    @State private var clipEpisode: Episode?
    @State private var clipPosMs = 0
    @State private var clipImage: UIImage?
    @State private var showClip = false
    @State private var confirmDeleteDownload = false
    /// 确认框开着时播放器可能已自动续播到下一集,删除的必须是按下那一下的那一集。
    @State private var pendingDeleteDownload: String?

    private let sleepMinutes = [15, 30, 45, 60]
    private let seals: [(seal: String, label: String)] = [
        ("喜", "开心"), ("暖", "治愈"), ("燃", "热血"),
        ("惊", "震撼"), ("思", "沉思"), ("悟", "领悟"),
        ("悲", "难过"), ("怒", "愤怒"), ("疲", "疲惫")
    ]

    private var accent: Color { Theme.accent(env.settings.accentIndex) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let ep = player.current {
                content(ep)
            } else {
                Spacer()
                Text("没有正在播放的内容").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(Color(.systemBackground))
        .task(id: player.current?.id) {
            // 切集时把章表状态机复位(**不发请求**,见 `ChapterStore.prepare`)
            if let id = player.current?.id { env.chapters.prepare(episodeId: id) }
        }
        #if DEBUG
        // 模拟器没有点击注入工具(没有 WDA):`-open-chapters` 让章表弹层自己弹出来,
        // 用来验收「请求 → 列表 → 当前章高亮」这一屏。只在 Debug 包,TestFlight 里不存在。
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-open-chapters") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    showChapters = true
                }
            }
        }
        #endif
        .sheet(isPresented: $showStamps) {
            if let ep = player.current { stampSheet(ep) }
        }
        .sheet(isPresented: $showNote) {
            if let frozen = noteEpisode { noteComposer(frozen) }
        }
        .sheet(isPresented: $showTranscript) {
            if let ep = player.current { transcriptSheet(ep) }
        }
        .sheet(isPresented: $showChapters) {
            if let ep = player.current { chapterSheet(ep) }
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(player)
                .environmentObject(env.settings)
        }
        .sheet(isPresented: $showNotes) {
            if let ep = player.current { descriptionSheet(ep) }
        }
        .sheet(isPresented: $showClip) {
            Group {
                if let image = clipImage {
                    ShareCardPreview(
                        title: "剪藏海报",
                        image: image,
                        fileName: "reverb-moment-\(abs((clipEpisode?.id ?? "x").hashValue)).png",
                        accent: accent)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在生成…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .presentationDetents([.medium])
                }
            }
            .task(id: clipEpisode?.id) { await renderClip() }
        }
        .sheet(item: $channel) { p in
            NavigationStack {
                PodcastDetailView(podcast: p)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { channel = nil }
                        }
                    }
            }
            .environmentObject(env)
            .environmentObject(player)
            .environmentObject(env.settings)
        }
        .confirmationDialog("删除此单集的离线文件?", isPresented: $confirmDeleteDownload,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = pendingDeleteDownload { env.downloadManager.delete(id) }
                pendingDeleteDownload = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("关闭"))
            Spacer()
            Text("正在播放").font(.headline)
            Spacer()
            AirPlayRouteButton(tint: UIColor(accent))
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text("投放"))
        }
        .padding(.horizontal, 4)
    }

    private func content(_ ep: Episode) -> some View {
        ScrollView {
            VStack(spacing: 26) {
                artwork(ep)
                titleBlock(ep)
                VStack(spacing: 2) {
                    if hasChapters(ep) { chapterEntry(ep) }
                    seekBar(ep)
                }
                controls(ep)
                actionRow(ep)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 封面

    private func artwork(_ ep: Episode) -> some View {
        ZStack {
            InkWave(color: accent, animating: player.isPlaying)
                .frame(height: 250)
            SquareArtwork(url: ep.artworkUrl, corner: 18)
                .frame(maxWidth: 260)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                .padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }

    private func titleBlock(_ ep: Episode) -> some View {
        VStack(spacing: 6) {
            Text(ep.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if ep.feedUrl.isEmpty {
                Text(ep.podcastTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button {
                    channel = Podcast(id: ep.feedUrl, title: ep.podcastTitle, author: "",
                                      artworkUrl: ep.artworkUrl, feedUrl: ep.feedUrl)
                } label: {
                    Text(ep.podcastTitle)
                        .font(.callout)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                .accessibilityLabel(Text("查看频道"))
            }
        }
    }

    // MARK: - 进度

    /// 判据同 macOS:`isLive && durationMs <= 0`。有限时长的流报出时长后,
    /// 进度条与快进快退重新有意义,不该再装作直播。
    private func seekBar(_ ep: Episode) -> some View {
        // 冷启动恢复成**暂停**态时 `player.durationMs` 还是 0(AVPlayer 的时长要等
        // item 加载后由 tick 填,暂停不 tick),于是总时长显示 0:00、滑杆按 0...1 判满格。
        // 这里退到条目自带时长;真正报出时长后仍以播放器为准(直播流时长可能变)。
        let totalMs = player.durationMs > 0 ? player.durationMs : max(0, ep.durationSec * 1000)
        return Group {
            if ep.isLive && player.durationMs <= 0 {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("直播中").font(.callout).foregroundStyle(.red)
                }
                .frame(height: 34)
            } else {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { dragging ? dragValue : Double(player.positionMs) },
                            set: { dragValue = $0 }
                        ),
                        in: 0...Double(max(1, totalMs)),
                        onEditingChanged: { editing in
                            if editing { dragging = true }
                            else { player.seek(toMs: Int(dragValue)); dragging = false }
                        }
                    )
                    .tint(accent)
                    HStack {
                        Text(Fmt.clock(dragging ? Int(dragValue) : player.positionMs))
                        Spacer()
                        Text(Fmt.clock(totalMs))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 章节

    /// 只认有章表、且不是"没有时间轴的直播"的集(判据与 `seekBar` 同一把尺)
    private func hasChapters(_ ep: Episode) -> Bool {
        !(ep.isLive && player.durationMs <= 0) && !ep.chaptersUrl.isEmpty
    }

    /// 章表入口:一行文字(当前章标题,没有时写「章节」)+ 下拉小三角。
    /// 显示当前章标题而不只是"章节":它在播放时本身就是有用的信息,
    /// 也让"点这里能跳章"看得出来(与 Android / 鸿蒙 / macOS 同一条)。
    private func chapterEntry(_ ep: Episode) -> some View {
        Button { showChapters = true } label: {
            HStack(spacing: 5) {
                Text(currentChapterTitle(ep))
                    .font(.callout)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("章节"))
    }

    /// 列表没加载之前退回「章节」,不显示"第 N 章"之类的猜测(三端同一口径)
    private func currentChapterTitle(_ ep: Episode) -> String {
        let store = env.chapters
        guard store.episodeId == ep.id, store.state == .done else {
            return String(localized: "章节")
        }
        let idx = store.index(atMs: player.positionMs)
        guard idx >= 0, idx < store.chapters.count else { return String(localized: "章节") }
        let title = store.chapters[idx].title
        return title.isEmpty ? String(localized: "章节") : title
    }

    private func chapterSheet(_ ep: Episode) -> some View {
        NavigationStack {
            chapterBody(ep)
                .navigationTitle("章节")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showChapters = false }
                    }
                }
        }
        .tint(accent)
        // 每次打开都走一次 load:命中缓存是同步读几 KB,没缓存才发请求。
        // **入口不自动取** —— 章表只在用户真的要看列表时才有价值。
        .task(id: ep.id) { await env.chapters.load(episode: ep) }
    }

    @ViewBuilder
    private func chapterBody(_ ep: Episode) -> some View {
        let store = env.chapters
        switch store.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            Text("这一集没有章节")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            // 只有"取不到"才给重试;空表不给按钮,否则用户会一直点一个永远好不了的按钮
            Button {
                Task { await env.chapters.load(episode: ep) }
            } label: {
                Text("章节加载失败，点按重试")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .done:
            let idx = store.index(atMs: player.positionMs)
            List {
                ForEach(store.chapters.indices, id: \.self) { i in
                    chapterRow(i, active: i == idx)
                }
            }
            .listStyle(.plain)
        }
    }

    private func chapterRow(_ i: Int, active: Bool) -> some View {
        let c = env.chapters.chapters[i]
        return Button {
            player.seek(toMs: c.startMs)
            showChapters = false
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Fmt.clock(c.startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(active ? accent : .secondary)
                    .frame(width: 52, alignment: .leading)
                Text(c.title)
                    .font(.callout)
                    .fontWeight(active ? .medium : .regular)
                    .foregroundStyle(active ? accent : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(active ? accent.opacity(0.12) : Color.clear)
    }

    // MARK: - 传输控制

    private func controls(_ ep: Episode) -> some View {
        VStack(spacing: 12) {
            if let err = player.playbackError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Button("重试") { player.retry() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            transportRow(ep)
        }
    }

    private func transportRow(_ ep: Episode) -> some View {
        HStack(spacing: 26) {
            if !ep.isLive {
                controlButton("gobackward.\(min(env.settings.skipBackSec, 30))", size: 24) { player.skipBackward() }
                    .accessibilityLabel(Text("快退"))
            }
            controlButton("backward.fill", size: 22) { player.previous() }
                .disabled(!player.hasPrev || ep.isLive)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .foregroundStyle(player.buffering && !player.isPlaying ? Color.secondary : accent)
            }
            .accessibilityLabel(player.isPlaying ? Text("暂停") : Text("播放"))
            controlButton("forward.fill", size: 22) { player.next() }
                .disabled(!player.hasNext || ep.isLive)
            if !ep.isLive {
                controlButton("goforward.\(min(env.settings.skipForwardSec, 60))", size: 24) { player.skipForward() }
                    .accessibilityLabel(Text("快进"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作行

    private func actionRow(_ ep: Episode) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                // 倍速:直播不给(线性源没有"快进"这回事)。
                if !ep.isLive {
                    Menu {
                        ForEach(player.speedSteps, id: \.self) { s in
                            Button {
                                player.setSpeed(s)
                            } label: {
                                if abs(player.speed - s) < 0.001 { Label(speedText(s), systemImage: "checkmark") }
                                else { Text(speedText(s)) }
                            }
                        }
                    } label: {
                        actionLabel(Text(speedText(player.speed)), symbol: "speedometer",
                                    active: player.speed != 1.0, iconFirst: false)
                    }
                }

                Button { env.favorites.toggle(ep) } label: {
                    actionLabel(Text("收藏"), symbol: env.favorites.isFavorite(ep.id) ? "heart.fill" : "heart",
                                active: env.favorites.isFavorite(ep.id), iconFirst: true)
                }
                .accessibilityLabel(Text("收藏"))

                Button {
                    notePosMs = player.positionMs
                    noteEpisode = ep
                    noteDraft = ""
                    showNote = true
                } label: {
                    actionLabel(Text("写批注"), symbol: "square.and.pencil", active: false, iconFirst: true)
                }
                .accessibilityLabel(Text("写批注"))

                Menu {
                    ForEach(sleepMinutes, id: \.self) { m in
                        Button("\(m) 分钟") { player.setSleepTimer(minutes: m) }
                    }
                    Button("本集结束") { player.setSleepEndOfEpisode() }
                    Divider()
                    Button("关闭") { player.cancelSleep() }
                } label: {
                    // 倒计时就显示在本颗的字上(与 Android `SleepChip` / 鸿蒙 `SleepCountdownText`
                    // 同一口径):开着定时却只换图标的话,用户看不出还剩多久。
                    actionLabel(sleepTitle, symbol: sleepActive ? "moon.zzz.fill" : "moon.zzz",
                                active: sleepActive, iconFirst: true)
                }
                .accessibilityLabel(Text("睡眠定时"))

                Button { showStamps = true } label: {
                    actionLabel(Text("听觉印记"), symbol: "seal", active: currentSeal != nil, iconFirst: true)
                }
                .accessibilityLabel(Text("听觉印记"))
            }
            .frame(maxWidth: .infinity)

            // 自适应换行而不是一行 HStack:窄屏(SE 320pt 去掉左右 24)那一行放不下
            // 四颗胶囊,末尾的下载按钮会被挤出屏幕 —— 这是排版问题,不该靠截断解决。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                secondaryButton("简介", symbol: "text.alignleft") { showNotes = true }
                if !ep.isLive && (env.settings.transcriptionEnabled || !ep.transcriptUrl.isEmpty) {
                    secondaryButton("逐字稿", symbol: "text.viewfinder") { showTranscript = true }
                }
                secondaryButton("待播", symbol: "text.line.first.and.arrowtriangle.forward") { showQueue = true }
                secondaryButton("剪藏", symbol: "bookmark") {
                    clipEpisode = ep
                    clipPosMs = player.positionMs
                    clipImage = nil
                    showClip = true
                }
                if !ep.isLive && !BilibiliSource.isPseudo(ep.audioUrl) {
                    // 与其余四颗同为带字胶囊:早先这里是个 36pt 圆钮,夹在胶囊里像个漏排版的小件。
                    downloadPill(ep)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
        .task(id: ep.id) {
            noteParagraphs = Fmt.plainText(ep.description)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            noteForEpisode = ep.id
        }
    }

    private func actionLabel(_ title: Text, symbol: String, active: Bool, iconFirst: Bool) -> some View {
        VStack(spacing: 5) {
            if iconFirst {
                ZStack {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(active ? accent : .primary)
                    if symbol == "seal", let s = currentSeal {
                        Text(s).font(.system(size: 8, weight: .bold)).foregroundStyle(accent)
                    }
                }
                .frame(height: 24)
                // 用 `Color.secondary` 而不是 `.secondary`:按钮标签里的层级样式会按 tint
                // 解析,青瓷这类低饱和配色下小字会读成"禁用"(和下载钮同一类视觉问题)。
                title.font(.caption2).foregroundStyle(Color.secondary)
            } else {
                title
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(active ? accent : .primary)
                    .frame(height: 24)
                Text(" ").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func secondaryButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            pill { Label(title, systemImage: symbol) }
        }
        .buttonStyle(.plain)
    }

    /// 下载的四种状态收进同一颗胶囊。删掉离线文件仍要确认一次(与列表里的下载钮同一口径)。
    @ViewBuilder
    private func downloadPill(_ ep: Episode) -> some View {
        if env.downloads.contains(ep.id) {
            Button { pendingDeleteDownload = ep.id; confirmDeleteDownload = true } label: {
                pill {
                    Label("已下载", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                }
            }
            .buttonStyle(.plain)
        } else if env.downloadManager.isDownloading(ep.id) {
            pill {
                ProgressView().controlSize(.mini)
                Text("下载中")
            }
        } else {
            Button { env.downloadManager.download(ep) } label: {
                pill { Label("下载", systemImage: "arrow.down.circle") }
            }
            .buttonStyle(.plain)
            .disabled(ep.audioUrl.isEmpty)
        }
    }

    private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private var sleepActive: Bool { player.sleepRemainingMs > 0 || player.sleepEndOfEpisode }

    /// 与 Android `SleepChip` 同文案:倒计时优先,「本集结束」其次,否则就是未开。
    private var sleepTitle: Text {
        if player.sleepRemainingMs > 0 {
            return Text(Fmt.clock(player.sleepRemainingMs)).monospacedDigit()
        }
        if player.sleepEndOfEpisode { return Text("本集结束") }
        return Text("睡眠定时")
    }

    private var currentSeal: String? {
        guard let ep = player.current else { return nil }
        return env.stamps.sealFor(ep.id)
    }

    // MARK: - 弹层

    private func stampSheet(_ ep: Episode) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        return NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(seals, id: \.seal) { item in
                        let active = currentSeal == item.seal
                        Button {
                            if active {
                                env.stamps.remove(ep.id)
                            } else {
                                env.stamps.set(episodeId: ep.id, seal: item.seal, title: ep.title,
                                               podcastTitle: ep.podcastTitle, at: Date().timeIntervalSince1970)
                            }
                            showStamps = false
                        } label: {
                            VStack(spacing: 6) {
                                Text(item.seal).font(.system(size: 26, weight: .bold))
                                Text(LocalizedStringKey(item.label)).font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 74)
                            .background(active ? accent.opacity(0.2) : Color.secondary.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(active ? accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("听觉印记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showStamps = false }
                }
            }
        }
        .presentationDetents([.medium])
        .tint(accent)
    }

    /// 写批注:标题是**按下那一刻**冻结的时间;空文字静默丢弃(与另三端同一口径)。
    private func noteComposer(_ ep: Episode) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(Fmt.clock(notePosMs))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(accent)
                Text(ep.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $noteDraft)
                        .font(.body)
                        .frame(minHeight: 120)
                    if noteDraft.isEmpty {
                        Text("此刻想到什么，写下来")
                            .font(.body)
                            .foregroundStyle(.secondary.opacity(0.7))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
                Spacer()
            }
            .padding(20)
            .navigationTitle("记下这一秒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        env.notes.add(ep, positionMs: notePosMs,
                                      text: noteDraft, at: Int(Date().timeIntervalSince1970 * 1000))
                        showNote = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(accent)
    }

    private func transcriptSheet(_ ep: Episode) -> some View {
        NavigationStack {
            TranscriptPage(episode: ep, accent: accent)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showTranscript = false }
                    }
                }
        }
        .tint(accent)
    }

    private func descriptionSheet(_ ep: Episode) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if noteForEpisode == ep.id && !noteParagraphs.isEmpty {
                        ForEach(noteParagraphs.indices, id: \.self) { i in
                            Text(noteParagraphs[i])
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("暂无简介").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("简介")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showNotes = false }
                }
            }
        }
        .tint(accent)
    }

    /// 生成剪藏海报。封面先取到再渲染 —— `AsyncImage` 的异步链在 `ImageRenderer`
    /// 那一帧里还没回来,不先 `await` 就会渲染出占位方块。
    private func renderClip() async {
        guard let ep = clipEpisode else { return }
        let art = await loadUIImage(ep.artworkUrl)
        let card = MomentCard(episode: ep, positionMs: clipPosMs, accent: accent, artwork: art)
        clipImage = renderImage(card)
    }

    /// `%.2g` 会把 1.25 印成 `1.2×`、1.75 印成 `1.8×`(两位有效数字),菜单里选的那档
    /// 与显示的不是同一个数。这端用 `%g` 与设置页同一口径:1 → `1×`、1.25 → `1.25×`。
    private func speedText(_ s: Double) -> String {
        String(format: "%g×", s)
    }
}

/// 水墨波纹:三条正弦色带,仅在播放时流动。与 macOS 版同一算法。
private struct InkWave: View {
    let color: Color
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animating)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for r in 0..<3 {
                    var path = Path()
                    let amp = size.height * 0.06 * Double(r + 1)
                    let yBase = size.height * (0.4 + 0.12 * Double(r))
                    let phase = t * (0.6 + 0.25 * Double(r)) + Double(r)
                    let wavelength = size.width / (1.2 + 0.4 * Double(r))
                    path.move(to: CGPoint(x: 0, y: yBase))
                    var x: CGFloat = 0
                    while x <= size.width {
                        let y = yBase + amp * sin(Double(x) / wavelength * 2 * .pi + phase)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 6
                    }
                    ctx.stroke(path, with: .color(color.opacity(0.18 - 0.04 * Double(r))),
                               lineWidth: 2.0 + Double(r))
                }
            }
        }
        .allowsHitTesting(false)
        .blur(radius: 6)
    }
}