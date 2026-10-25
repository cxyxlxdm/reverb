import SwiftUI

/// 追更:顶层三格之一,合并所有订阅的**全部单集**(与 Android `InboxScreen.kt` /
/// 鸿蒙 `FeedPage.ets` 同口径,内核见 `InboxStore` 的落盘口径注释)。
///
/// 为什么从音阁的一个分段提上来(手机两端 2026-10-08 那轮):内容是"订阅频道播过的集",
/// 是每天打开 App 要看的第一眼,埋在六段里要靠横滑才够得着。桌面这一轮补齐同一格。
struct InboxView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    /// 这份多选只属于这一列(见 `EpisodeSelection`:同一个 id 也出现在收藏/下载里)。
    @StateObject private var selection = EpisodeSelection()

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var items: [Episode] { env.inbox.episodes }

    var body: some View {
        Group {
            if items.isEmpty {
                if env.inbox.refreshing {
                    StateView(loading: true, text: "")
                } else if env.subscriptions.subscriptions.isEmpty {
                    StateView(symbol: "tray", text: "还没有订阅。去「发现」订阅几档，它们播过的单集都会汇到这里")
                } else {
                    StateView(symbol: "tray", text: "这些频道还没有可播的单集，点工具栏刷新再试")
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
                                selecting: selection.selecting,
                                selected: selection.picked.contains(ep.id),
                                onPlay: {
                                    if selection.selecting { selection.toggle(ep) }
                                    else { player.playOrToggle(ep, queue: items, tag: ListTag.inbox) }
                                })
                                .episodeContextMenu(ep, enabled: !selection.selecting)
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("追更")
        .toolbar {
            // 手动刷新:桌面没有下拉手势(与发现页 / 频道页同一条),所以放工具栏。
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
            if !items.isEmpty {
                if selection.selecting {
                    EpisodeBatchToolbar(episodes: items,
                                        selecting: $selection.selecting, picked: $selection.picked) {
                        selection.enqueue(from: items, using: player, log: "列=追更")
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button { selection.selecting = true } label: {
                            Label("选择", systemImage: "checklist")
                        }
                        .help("选择多集")
                    }
                }
            }
        }
        .overlay(alignment: .top) { TopToast(text: selection.toast) }
        .task {
            // 订阅集未变时切回本页不重刷(避免每次切 tab 全量重载与列表跳动)
            await env.inbox.refreshIfStale(subscriptions: env.subscriptions.subscriptions,
                                           repository: env.repository)
        }
    }
}
