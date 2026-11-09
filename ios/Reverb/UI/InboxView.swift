import SwiftUI

/// 追更:所有订阅频道的单集按发布时间倒序。与另三端同一份 `InboxStore` 落盘口径。
struct InboxView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

    /// 双击底部「追更」时外壳递增这个数(见 RootView)。
    var scrollTopToken: Int = 0
    private static let topAnchor = "inbox-top"
    /// 离开这一格时的头一条 id。用来补上「人在别的 tab 时追更刷新了」这一种:
    /// 那种情况下 `onChange` 仍会触发,但这一页不在屏上、`scrollTo` 滚不动,
    /// 只能等回到本页再对一次(见下面的 `onAppear`)。
    @State private var headWhenLeft: String?

    @StateObject private var selection = EpisodeSelection()

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var items: [Episode] { env.inbox.episodes }

    var body: some View {
        ScrollViewReader { proxy in
            page
                .onChange(of: scrollTopToken) { _, _ in scrollToTop(proxy) }
                // 内容更新(头一条换了)就回顶。判据取**头一条 id**而不是条数:
                // 条数不变也可能整批换了(退订一档又订回来);旧值为空(首次装配)时不动。
                .onChange(of: items.first?.id) { old, new in
                    guard let old, let new, old != new else { return }
                    scrollToTop(proxy)
                }
                .onAppear {
                    if let left = headWhenLeft, left != items.first?.id { scrollToTop(proxy) }
                    headWhenLeft = nil
                }
                .onDisappear { headWhenLeft = items.first?.id }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.topAnchor, anchor: .top)
    }

    private var page: some View {
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
                    Color.clear.frame(height: 0).id(Self.topAnchor)
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