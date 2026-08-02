import SwiftUI

/// 音阁:订阅 / 收藏 / 历史。分段控制置于内容顶部,内容区宽松展示。
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case subscriptions = "订阅"
        case favorites = "收藏"
        case history = "历史"
        case downloads = "下载"
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
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 20)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()

            Group {
                switch segment {
                case .subscriptions: subscriptionsGrid
                case .favorites: favoritesList
                case .history: historyList
                case .downloads: downloadsList
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
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(env.subscriptions.subscriptions) { p in
                            NavigationLink(value: p) { PodcastCard(podcast: p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
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
                            HStack(spacing: 8) {
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    accent: accent,
                                    onPlay: { player.playOrToggle(ep, queue: items) })
                                Button { env.favorites.toggle(ep) } label: {
                                    Image(systemName: "heart.fill").foregroundStyle(accent)
                                }
                                .buttonStyle(.plain)
                                .help("取消收藏")
                            }
                            .padding(.horizontal, 24)
                            Divider().padding(.leading, 24)
                        }
                    }
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
                                accent: accent,
                                onPlay: { player.playOrToggle(ep, queue: items) })
                                .padding(.horizontal, 24)
                            Divider().padding(.leading, 24)
                        }
                    }
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
                            HStack(spacing: 8) {
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    accent: accent,
                                    onPlay: { player.playOrToggle(ep, queue: items) })
                                Button { pendingDelete = ep } label: {
                                    Image(systemName: "trash").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("删除下载")
                            }
                            .padding(.horizontal, 24)
                            Divider().padding(.leading, 24)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
