import SwiftUI

/// 追更:所有订阅频道的单集按发布时间倒序。与另三端同一份 `InboxStore` 落盘口径。
struct InboxView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

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
                                },
                                onEnterSelection: { selection.enter(ep.id) })
                        }
                    }
                    .frame(maxWidth: Metrics.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                }
                .refreshable {
                    await env.inbox.refresh(subscriptions: env.subscriptions.subscriptions,
                                            repository: env.repository)
                }
            }
        }
        .navigationTitle("追更")
        .toolbarTitleDisplayMode(.inlineLarge)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.selecting {
                EpisodeSelectionBar(
                    count: selection.picked.count,
                    allSelected: selection.picked.count >= items.count,
                    onAll: { selection.picked = Set(items.map(\.id)) },
                    onEnqueue: { selection.enqueue(from: items, using: player, log: "列=追更") },
                    onExit: { selection.reset() },
                    accent: accent)
            }
        }
        .selectionToast(selection)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PlayModeButton(tag: ListTag.inbox)
            }
            ToolbarItem(placement: .topBarTrailing) {
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
                .accessibilityLabel(Text("刷新"))
            }
        }
        .task {
            await env.inbox.refreshIfStale(subscriptions: env.subscriptions.subscriptions,
                                           repository: env.repository)
        }
    }
}