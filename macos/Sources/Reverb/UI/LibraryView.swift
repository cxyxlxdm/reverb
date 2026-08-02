import SwiftUI

/// 音阁:订阅 / 收藏 / 历史。
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case subscriptions = "订阅"
        case favorites = "收藏"
        case history = "历史"
        var id: String { rawValue }
    }

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @State private var segment: Segment = .subscriptions

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()

                Group {
                    switch segment {
                    case .subscriptions: subscriptionsList
                    case .favorites: favoritesList
                    case .history: historyList
                    }
                }
            }
            .navigationTitle("音阁")
            .navigationDestination(for: Podcast.self) { PodcastDetailView(podcast: $0) }
            .toolbar {
                if segment == .history && !env.history.history.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { env.history.clear() } label: {
                            Label("清空", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 订阅

    private var subscriptionsList: some View {
        Group {
            if env.subscriptions.subscriptions.isEmpty {
                emptyState("还没有订阅任何节目")
            } else {
                List {
                    ForEach(env.subscriptions.subscriptions) { p in
                        NavigationLink(value: p) { PodcastRow(podcast: p) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - 收藏

    private var favoritesList: some View {
        Group {
            if env.favorites.favorites.isEmpty {
                emptyState("还没有收藏的单集")
            } else {
                let items = env.favorites.favorites
                List {
                    ForEach(items) { ep in
                        HStack {
                            EpisodeRow(episode: ep,
                                       isCurrent: player.current?.id == ep.id,
                                       isPlaying: player.isPlaying,
                                       showPodcast: true,
                                       onPlay: { player.playOrToggle(ep, queue: items) })
                            Button {
                                env.favorites.toggle(ep)
                            } label: {
                                Image(systemName: "heart.fill").foregroundStyle(Theme.accent(env.settings.accentIndex))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - 历史

    private var historyList: some View {
        Group {
            if env.history.history.isEmpty {
                emptyState("暂无播放历史")
            } else {
                let items = env.history.history.map { $0.episode }
                List {
                    ForEach(items) { ep in
                        EpisodeRow(episode: ep,
                                   isCurrent: player.current?.id == ep.id,
                                   isPlaying: player.isPlaying,
                                   showPodcast: true,
                                   onPlay: { player.playOrToggle(ep, queue: items) })
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
