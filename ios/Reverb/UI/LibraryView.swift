import SwiftUI

/// 音阁:订阅 / 收藏 / 下载 / 待播 / 历史 / 批注。段序与另三端一致。
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case subscriptions = "订阅"
        case favorites = "收藏"
        case downloads = "下载"
        case queue = "待播"
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
    @State private var confirmClearHistory = false
    @State private var confirmClearQueue = false
    @State private var showListenStats = false
    /// 每一段各自一份多选状态(集合里存 id,跨段共用会「在这段选、在那段入队」)。
    @StateObject private var selection = EpisodeSelection()

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private let columns = [GridItem(.adaptive(minimum: Metrics.cardMin, maximum: 220),
                                    spacing: Metrics.gridSpacing)]

    /// 当前分段可多选的那些集(全选与入队都以它为准 —— 被 Lazy 容器回收的行不参与)。
    private var selectableItems: [Episode] {
        switch segment {
        case .favorites: return env.favorites.favorites
        case .downloads: return downloads.downloads.map(\.episode)
        case .history: return env.history.history.map(\.episode)
        default: return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            segmentBar
            Group {
                switch segment {
                case .subscriptions: subscriptionsGrid
                case .favorites: favoritesList
                case .downloads: downloadsList
                case .queue: queueList
                case .history: historyList
                case .notes: notesList
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.selecting {
                let shown = selectableItems
                EpisodeSelectionBar(
                    count: selection.picked.count,
                    allSelected: selection.picked.count >= shown.count,
                    onAll: { selection.picked = Set(shown.map(\.id)) },
                    onEnqueue: {
                        selection.enqueue(from: shown, using: player,
                                          log: "列=\(segment.rawValue)")
                    },
                    onExit: { selection.reset() },
                    accent: accent)
            }
        }
        .selectionToast(selection)
        .onChange(of: segment) { _, _ in selection.reset() }
        .navigationTitle("音阁")
        .toolbarTitleDisplayMode(.inlineLarge)
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
        .confirmationDialog("清空播放历史?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清空", role: .destructive) { env.history.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空全部收听记录与续播位置。")
        }
        .confirmationDialog("清空播放队列?", isPresented: $confirmClearQueue, titleVisibility: .visible) {
            Button("清空", role: .destructive) { player.clearQueue() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空待播队列中的全部单集，无法恢复。")
        }
        .sheet(isPresented: $showListenStats) {
            ListenStatsView()
                .environmentObject(env.listenStats)
                .environmentObject(settings)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showListenStats = true } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .accessibilityLabel(Text("收听时长"))
            }
            if segment == .subscriptions {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settings.subsGrid.toggle()
                    } label: {
                        // 图标画的是「切换后的目标布局」(与 Android `LibraryScreen` 同一条)。
                        Image(systemName: settings.subsGrid ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(Text("切换订阅排列"))
                }
            }
            if segment == .favorites || segment == .downloads {
                ToolbarItem(placement: .topBarTrailing) {
                    PlayModeButton(tag: segment == .favorites ? ListTag.fav : ListTag.dl)
                }
            }
            if segment == .queue && !player.userQueue.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            if segment == .queue && !player.userQueue.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmClearQueue = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("清空待播"))
                }
            }
            if segment == .history && !env.history.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmClearHistory = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("清空播放历史"))
                }
            }
        }
    }

    private var segmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Segment.allCases) { s in
                    Button {
                        segment = s
                    } label: {
                        Text(LocalizedStringKey(s.rawValue))
                            .font(.subheadline.weight(segment == s ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(segment == s ? accent.opacity(0.16) : Color.secondary.opacity(0.09),
                                        in: Capsule())
                            .foregroundStyle(segment == s ? accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - 订阅

    private var subscriptionsGrid: some View {
        Group {
            if env.subscriptions.subscriptions.isEmpty {
                StateView(symbol: "books.vertical", text: "还没有订阅任何节目")
            } else if settings.subsGrid {
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
                    .padding(.bottom, Metrics.sectionSpacing)
                }
            } else {
                // 默认是列表:与 Android `SubscriptionsSection(gridLayout=false)` 同一条,
                // 宫格是用户显式打开的那一档。
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(env.subscriptions.subscriptions) { p in
                            NavigationLink(value: p) {
                                PodcastListRow(podcast: p)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 4)
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
                            HStack(spacing: 10) {
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    played: env.history.isPlayed(ep.id),
                                    accent: accent,
                                    selecting: selection.selecting,
                                    selected: selection.picked.contains(ep.id),
                                    onPlay: {
                                        if selection.selecting { selection.toggle(ep) }
                                        else { player.playOrToggle(ep, queue: items, tag: ListTag.fav) }
                                    },
                                    onEnterSelection: { selection.enter(ep.id) })
                                if !selection.selecting {
                                    Button { env.favorites.toggle(ep) } label: {
                                        Image(systemName: "heart.fill")
                                            .foregroundStyle(accent)
                                            .frame(width: 32, height: 32)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("取消收藏"))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
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
                            HStack(spacing: 10) {
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    played: env.history.isPlayed(ep.id),
                                    accent: accent,
                                    selecting: selection.selecting,
                                    selected: selection.picked.contains(ep.id),
                                    onPlay: {
                                        if selection.selecting { selection.toggle(ep) }
                                        else { player.playOrToggle(ep, queue: items, tag: ListTag.dl) }
                                    },
                                    onEnterSelection: { selection.enter(ep.id) })
                                if !selection.selecting {
                                    Button { pendingDelete = ep } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32, height: 32)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("删除下载"))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 待播

    private var queueList: some View {
        Group {
            if player.userQueue.isEmpty {
                StateView(symbol: "text.line.first.and.arrowtriangle.forward", text: "播放队列为空")
            } else {
                List {
                    ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { idx, ep in
                        Button {
                            player.playFromQueue(id: ep.id)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                Artwork(url: ep.artworkUrl, size: 38, corner: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ep.title).font(.callout).lineLimit(1)
                                    Text(ep.podcastTitle).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                player.removeFromQueue(ep.id)
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { from, to in
                        guard let f = from.first else { return }
                        player.moveInQueue(from: f, to: to)
                    }
                }
                .listStyle(.plain)
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
                                selecting: selection.selecting,
                                selected: selection.picked.contains(ep.id),
                                onPlay: {
                                    if selection.selecting { selection.toggle(ep) }
                                    else { player.playOrToggle(ep, queue: items) }
                                },
                                onEnterSelection: { selection.enter(ep.id) })
                            // 这里**不能**再挂一层 `.contextMenu`:外层会整份顶掉行内那颗
                            // `EpisodeActionMenu`(收藏/待播/下一集/下载与「标记为未播完」全都消失)。
                            // 反向撤销已经由 `EpisodeActionMenu` 自己给(isPlayed 时出现)。
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 批注

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
                                        .font(.headline.weight(.medium))
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
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(isNoteCurrent(n) ? accent : Color.secondary)
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("回到那一秒"))

                                Button { pendingNoteDelete = n } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("删除批注"))
                            }
                            .padding(.vertical, 14)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func isNoteCurrent(_ n: EpisodeNote) -> Bool { player.current?.id == n.episode.id }

    private var noteDeleteMessage: String {
        let text = pendingNoteDelete?.text ?? ""
        return String(format: NSLocalizedString("将删除这条批注，无法恢复。\n\n「%@」",
                                                comment: "批注二次确认:正文带上被删的那句话"), text)
    }

    private func playNote(_ n: EpisodeNote) {
        Log.i("UI", "播放批注 @\(n.positionMs)ms id=\(n.episode.id)")
        player.playAt(n.episode, startMs: n.positionMs)
    }
}

/// 订阅列表形态的一行(宫格之外的另一档)。与 Android `PodcastListItem` 同信息量:
/// 封面 + 频道名 + 作者 + 右箭头。
private struct PodcastListRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkUrl, size: 54, corner: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.title)
                    .font(.headline).fontWeight(.medium)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !podcast.author.isEmpty {
                    Text(podcast.author)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}