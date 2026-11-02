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

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private let columns = [GridItem(.adaptive(minimum: Metrics.cardMin, maximum: 220),
                                    spacing: Metrics.gridSpacing)]

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
                            HStack(spacing: 10) {
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    played: env.history.isPlayed(ep.id),
                                    accent: accent,
                                    onPlay: { player.playOrToggle(ep, queue: items, tag: ListTag.fav) })
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
                                    onPlay: { player.playOrToggle(ep, queue: items, tag: ListTag.dl) })
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
                                onPlay: { player.playOrToggle(ep, queue: items) })
                                .contextMenu {
                                    if env.history.isPlayed(ep.id) {
                                        Button {
                                            env.history.markPlayed(ep.id, false)
                                        } label: {
                                            Label("标记为未播完", systemImage: "arrow.uturn.backward")
                                        }
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