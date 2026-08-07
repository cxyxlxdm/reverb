import SwiftUI

/// 音阁:订阅 / 最新 / 收藏 / 下载 / 历史。分段控制置于内容顶部,内容区宽松展示。
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case subscriptions = "订阅"
        case inbox = "最新"
        case favorites = "收藏"
        case downloads = "下载"
        case history = "历史"
        var id: String { rawValue }
    }

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var segment: Segment = .subscriptions
    @State private var pendingDelete: Episode?

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private let columns = [GridItem(.adaptive(minimum: Metrics.cardMin, maximum: Metrics.cardMax),
                                    spacing: Metrics.gridSpacing)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.topPadding)
            .padding(.bottom, 18)

            Group {
                switch segment {
                case .subscriptions: subscriptionsGrid
                case .inbox: InboxView()
                case .favorites: favoritesList
                case .downloads: downloadsList
                case .history: historyList
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
        .toolbar {
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
                    Button(role: .destructive) { env.history.clear() } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .help("清空播放历史")
                }
            }
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
                                    onPlay: { player.playOrToggle(ep, queue: items) })
                                    .episodeContextMenu(ep)
                                Button { env.favorites.toggle(ep) } label: {
                                    Image(systemName: "heart.fill").foregroundStyle(accent)
                                }
                                .buttonStyle(.plain)
                                .help("取消收藏")
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
                                onPlay: { player.playOrToggle(ep, queue: items) })
                                .episodeContextMenu(ep)
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
                                    onPlay: { player.playOrToggle(ep, queue: items) })
                                    .episodeContextMenu(ep)
                                Button { pendingDelete = ep } label: {
                                    Image(systemName: "trash").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("删除下载")
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
