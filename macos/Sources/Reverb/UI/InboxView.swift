import SwiftUI

/// 最新:跨订阅合并的最新单集列表。先展示缓存,首屏自动刷新;工具栏提供手动刷新。
struct InboxView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

    @State private var didAppear = false

    private var accent: Color { Theme.accent(settings.accentIndex) }

    var body: some View {
        let items = env.inbox.episodes
        Group {
            if items.isEmpty {
                if env.inbox.refreshing {
                    StateView(loading: true, text: "")
                } else if env.subscriptions.subscriptions.isEmpty {
                    StateView(symbol: "tray", text: "订阅节目后,这里会汇集最新单集")
                } else {
                    StateView(symbol: "tray", text: "暂无最新单集")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { ep in
                            RoomyEpisodeRow(
                                episode: ep,
                                isCurrent: player.current?.id == ep.id,
                                isPlaying: player.isPlaying,
                                showPodcast: true,
                                showDate: true,
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
        .navigationTitle("余音")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: {
                    if env.inbox.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(env.inbox.refreshing)
                .help("刷新")
            }
        }
        .task {
            guard !didAppear else { return }
            didAppear = true
            await refresh()
        }
    }

    private func refresh() async {
        await env.inbox.refresh(subscriptions: env.subscriptions.subscriptions,
                                repository: env.repository)
    }
}
