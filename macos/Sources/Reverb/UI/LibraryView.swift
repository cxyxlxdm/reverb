import SwiftUI

/// 音阁:订阅 / 最新 / 收藏 / 下载 / 历史 / 批注。分段控制置于内容顶部,内容区宽松展示。
///
/// **加新段只能加在末尾**:`segmentTag` 与段尾那颗动作都按段判断,插中间会把按钮指错段
/// (与 Android / 鸿蒙同一条约束 —— 三端段序一致,用户换端不用重新找)。
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case subscriptions = "订阅"
        case inbox = "最新"
        case favorites = "收藏"
        case downloads = "下载"
        case history = "历史"
        case notes = "批注"
        var id: String { rawValue }
    }

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var segment: Segment = .subscriptions
    @State private var pendingDelete: Episode?
    @State private var pendingNoteDelete: EpisodeNote?
    @State private var showListenStats = false
    /// 历史清空的二次确认。与 Android `LibraryScreen.kt` 那条路径同口径:
    /// 清掉的是收听记录与续播位置,桌面没有别的入口能补回来(见 docs/MACOS-GAPS.md M1)。
    @State private var confirmClearHistory = false
    /// 多选批量加入待播。桌面形态:工具栏「选择」进入,不做手机那条长按浮条(见 M5)。
    @State private var selecting = false
    @State private var picked = Set<String>()
    /// 入队后的结果话(与 Android `batch_added` / `batch_added_none` 同一句),2 秒自散。
    @State private var toast: String?
    @State private var toastToken = 0

    /// 当前分段里**能批量处理的那一份**列表。订阅/批注不在内:前者不是单集列表,
    /// 后者是用户手写的字,批量入队对它们都没有意义(与 Android / 鸿蒙同一范围)。
    private var selectableEpisodes: [Episode] {
        switch segment {
        case .inbox: return env.inbox.episodes
        case .favorites: return env.favorites.favorites
        case .downloads: return downloads.downloads.map { $0.episode }
        case .history: return env.history.history.map { $0.episode }
        case .subscriptions, .notes: return []
        }
    }

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private let columns = [GridItem(.adaptive(minimum: Metrics.cardMin, maximum: Metrics.cardMax),
                                    spacing: Metrics.gridSpacing)]

    /// 音阁三段的「列身份」。同一个串用在**两处**:分段行右端那颗模式按钮按它读写自己那一格,
    /// 段内某一行起播时把它随 `playQueue` 传下去(日志里 `tag='…'` 读到的就是它)。
    /// 订阅 / 历史两段返回 nil:前者不是单集列表,后者的按钮位置已经是「清空」。
    ///
    /// **批注段也刻意返回 nil,而且段尾什么都不放**(与 Android / 鸿蒙同一条口径,装机时别当成漏做):
    /// 不放播放模式按钮 —— 点一条批注是「播那一集并跳到那一秒」,它不参与列表播放;
    /// 也不放「清空」—— 用户手写的字不该一键清光,`NoteStore` 因此压根没有 clear。
    private var segmentTag: String? {
        switch segment {
        case .inbox: return ListTag.inbox
        case .favorites: return ListTag.fav
        case .downloads: return ListTag.dl
        case .subscriptions, .history, .notes: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 分段条是定宽上限,六段里标签最长的是法语/西语那对(Annotations / Anotaciones):
                // **加第六段之后会不会开始截断标签,只有把界面跑起来才看得见**。
                // 出包那台机器上按实际宽度定夺,不要现在凭猜改这个数值。
                .frame(maxWidth: 440)
                if let tag = segmentTag {
                    PlayModeButton(tag: tag)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.topPadding)
            .padding(.bottom, 18)

            Group {
                switch segment {
                case .subscriptions: subscriptionsGrid
                case .inbox: InboxView(selecting: selecting, picked: picked,
                                       onToggleSelect: toggleSelect)
                case .favorites: favoritesList
                case .downloads: downloadsList
                case .history: historyList
                case .notes: notesList
                }
            }
        }
        .navigationTitle("余音")
        .confirmationDialog("删除此单集的离线文件?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let ep = pendingDelete { downloadManager.delete(ep.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        // 批注的二次确认:**正文里带上被删的那句话**(与 Android / 鸿蒙同一口径)。
        // 删的是用户自己写的字,只说"确定删除吗"等于让他凭记忆核对。
        .confirmationDialog("删除批注", isPresented: Binding(
            get: { pendingNoteDelete != nil },
            set: { if !$0 { pendingNoteDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let n = pendingNoteDelete { env.notes.remove(n.noteId) }
                pendingNoteDelete = nil
            }
            Button("取消", role: .cancel) { pendingNoteDelete = nil }
        } message: {
            Text(noteDeleteMessage)
        }
        // 清空历史:正文照抄 Android `confirm_clear_history`。这里清掉的是收听记录与
        // 续播位置 —— 桌面没有第二条路径能把它们补回来(见 docs/MACOS-GAPS.md M1)。
        .confirmationDialog("清空播放历史?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清空", role: .destructive) { env.history.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空全部收听记录与续播位置。")
        }
        .sheet(isPresented: $showListenStats) {
            ListenStatsView()
                .environmentObject(env.listenStats)
                .environmentObject(settings)
                .themedSheet(settings)
        }
        // 换段 = 换了一列单集:已选集合不能跟着搬过去,否则「在收藏里选了 3 集,切到下载
        // 按入队」会把收藏那 3 集悄悄加进去(集合里存的是 id,不看当前列)。
        .onChange(of: segment) { _ in
            selecting = false
            picked.removeAll()
        }
        .overlay(alignment: .top) { TopToast(text: toast) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showListenStats = true } label: {
                    Label("收听时长", systemImage: "chart.bar.xaxis")
                }
                .help("收听时长")
            }
            if segment == .inbox {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await env.inbox.refresh(subscriptions: env.subscriptions.subscriptions,
                                                    repository: env.repository)
                        }
                    } label: {
                        if env.inbox.refreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(env.inbox.refreshing)
                    .help("刷新")
                }
            }
            if segment == .history && !env.history.history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { confirmClearHistory = true } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .help("清空播放历史")
                }
            }
            // 多选只在有单集的四段里出现(订阅是宫格、批注不是单集行)。
            if !selectableEpisodes.isEmpty {
                if selecting {
                    EpisodeBatchToolbar(episodes: selectableEpisodes,
                                        selecting: $selecting, picked: $picked,
                                        enqueue: enqueuePicked)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button { selecting = true } label: {
                            Label("选择", systemImage: "checklist")
                        }
                        .help("选择多集")
                    }
                }
            }
        }
    }

    // MARK: - 多选

    private func toggleSelect(_ ep: Episode) {
        if picked.contains(ep.id) { picked.remove(ep.id) } else { picked.insert(ep.id) }
    }

    /// 把已选的那些交给 `enqueueAll`(一次去重、一次更新导航标记),然后退出选择模式。
    /// 结果必须说出来:入队结果在「待播」里,当前列表看不出任何变化,不提示等于没按上
    /// (Android 用 Toast 说同一句话,这里用顶部的 `TopToast`)。
    private func enqueuePicked() {
        let eps = selectableEpisodes.filter { picked.contains($0.id) }
        let added = player.enqueueAll(eps)
        Log.i("UI", "批量加入待播 选中=\(eps.count) 新增=\(added)")
        showToast(added == 0
            ? NSLocalizedString("所选都已在待播里", comment: "批量入队全部重复")
            : String(format: NSLocalizedString("已加入待播 %lld 集", comment: "批量入队结果"),
                     Int64(added)))
        selecting = false
        picked.removeAll()
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

    // MARK: - 订阅

    private var subscriptionsGrid: some View {
        Group {
            if env.subscriptions.subscriptions.isEmpty {
                StateView(symbol: "books.vertical", text: "还没有订阅任何节目")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                        ForEach(env.subscriptions.subscriptions) { p in
                            NavigationLink(value: p) { PodcastCard(podcast: p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 4)
                    .padding(.bottom, Metrics.sectionSpacing)
                }
            }
        }
    }

    // MARK: - 收藏

    private var favoritesList: some View {
        Group {
            if env.favorites.favorites.isEmpty {
                StateView(symbol: "heart", text: "还没有收藏的单集")
            } else {
                let items = env.favorites.favorites
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { ep in
                            HStack(spacing: 12) {
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    played: env.history.isPlayed(ep.id),
                                    accent: accent,
                                    selecting: selecting,
                                    selected: picked.contains(ep.id),
                                    onPlay: {
                                        if selecting { toggleSelect(ep) }
                                        else { player.playOrToggle(ep, queue: items, tag: ListTag.fav) }
                                    })
                                    .episodeContextMenu(ep, enabled: !selecting)
                                if !selecting {
                                    Button { env.favorites.toggle(ep) } label: {
                                        Image(systemName: "heart.fill").foregroundStyle(accent)
                                    }
                                    .buttonStyle(.plain)
                                    .help("取消收藏")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 历史

    private var historyList: some View {
        Group {
            if env.history.history.isEmpty {
                StateView(symbol: "clock.arrow.circlepath", text: "暂无播放历史")
            } else {
                let items = env.history.history.map { $0.episode }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { ep in
                            RoomyEpisodeRow(
                                episode: ep,
                                isCurrent: player.current?.id == ep.id,
                                isPlaying: player.isPlaying,
                                showPodcast: true,
                                played: env.history.isPlayed(ep.id),
                                accent: accent,
                                selecting: selecting,
                                selected: picked.contains(ep.id),
                                onPlay: {
                                    if selecting { toggleSelect(ep) }
                                    else { player.playOrToggle(ep, queue: items) }
                                })
                                .episodeContextMenu(ep, enabled: !selecting)
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 批注

    /// 跨单集的一句话时间线,新写的置顶。
    ///
    /// 行的主行是**用户写的那句话**,集名退到副行 —— 这一段要回看的是"当时想到了什么",
    /// 不是又一集列表(与 Android / 鸿蒙同一取舍)。
    private var notesList: some View {
        Group {
            if env.notes.notes.isEmpty {
                StateView(symbol: "square.and.pencil", text: "还没有写过批注")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(env.notes.notes) { n in
                            HStack(spacing: 12) {
                                EpisodeArtworkLink(episode: n.episode, size: 54, corner: 10)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(n.text)
                                        .font(.headline).fontWeight(.medium)
                                        .lineSpacing(2)
                                        .lineLimit(2)
                                        .foregroundStyle(isNoteCurrent(n) ? accent : .primary)
                                    Text("\(Fmt.clock(n.positionMs))  ·  \(n.episode.title)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { playNote(n) }

                                Button { playNote(n) } label: {
                                    // **恒为播放图标。** 画暂停图标会承诺一个这里不存在的能力 ——
                                    // 点它永远是「回到那一秒」而不是暂停(另两端那枚 play/pause
                                    // 蒙层是"这一集正在播"的状态指示,桌面端用图标颜色表达同一件事)。
                                    // 图标与动作不一致这件事在播放模式那颗上真栽过,见 H118。
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(isNoteCurrent(n) ? accent : Color.secondary)
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .buttonStyle(.plain)
                                .help("回到那一秒")

                                Button { pendingNoteDelete = n } label: {
                                    Image(systemName: "trash").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("删除批注")
                            }
                            .padding(.vertical, 14)
                            .frame(minHeight: 74)
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// 这一条批注的那一集是否正在播(只点亮图标,不承担暂停语义)。
    private func isNoteCurrent(_ n: EpisodeNote) -> Bool { player.current?.id == n.episode.id }

    /// 二次确认正文单独成属性,不是风格问题:`String(format: NSLocalizedString(…))` 直接写在
    /// `body` 的闭包里时,整个 `body` 大到 Swift 类型检查器超时(本机 typecheck 实测报
    /// `the compiler is unable to type-check this expression in reasonable time`)。
    /// 同 H86 里「别在插值里叠 .map(String.init)」那条,是同一个编译器的同一个上限。
    private var noteDeleteMessage: String {
        let text = pendingNoteDelete?.text ?? ""
        return String(format: NSLocalizedString("将删除这条批注，无法恢复。\n\n「%@」",
                                                comment: "批注二次确认:正文带上被删的那句话"), text)
    }

    /// 点一行 = 播那一集并**跳到批注的那一秒**,队列只放被点的这一集。
    ///
    /// 走 `player.playAt` 而不是 `playOrToggle`:后者在同一集正在播时会判成「按暂停」,
    /// 于是"点第二条批注想再看一次那一秒"变成了暂停,而用户没有任何反馈可看。
    /// 起点容差也不同 —— 见 `PlayerController.playAt` 与 H127。
    private func playNote(_ n: EpisodeNote) {
        Log.i("UI", "播放批注 @\(n.positionMs)ms id=\(n.episode.id)")
        player.playAt(n.episode, startMs: n.positionMs)
    }

    // MARK: - 下载

    private var downloadsList: some View {
        Group {
            if downloads.downloads.isEmpty {
                StateView(symbol: "arrow.down.circle", text: "还没有离线下载的单集")
            } else {
                let items = downloads.downloads.map { $0.episode }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { ep in
                            HStack(spacing: 12) {
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    played: env.history.isPlayed(ep.id),
                                    accent: accent,
                                    selecting: selecting,
                                    selected: picked.contains(ep.id),
                                    onPlay: {
                                        if selecting { toggleSelect(ep) }
                                        else { player.playOrToggle(ep, queue: items, tag: ListTag.dl) }
                                    })
                                    .episodeContextMenu(ep, enabled: !selecting)
                                if !selecting {
                                    Button { pendingDelete = ep } label: {
                                        Image(systemName: "trash").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除下载")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
