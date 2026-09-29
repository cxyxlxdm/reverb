import SwiftUI

/// 最新:跨订阅合并的最新单集列表。先展示缓存,首屏自动刷新。
/// 作为「音阁」的一个分段内嵌展示,手动刷新按钮由 LibraryView 工具栏提供。
struct InboxView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

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
                                onPlay: { player.playOrToggle(ep, queue: items, tag: ListTag.inbox) })
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
        .task {
            // 订阅集未变时切回本分段不重刷(避免每次切 tab 全量重载与列表跳动)
            await env.inbox.refreshIfStale(subscriptions: env.subscriptions.subscriptions,
                                           repository: env.repository)
        }
    }
}
