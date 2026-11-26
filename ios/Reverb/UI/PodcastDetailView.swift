import SwiftUI
import UIKit

/// 频道详情:封面 / 标题 / 作者 / 订阅 / 简介 + 单集列表。触屏形态下拉刷新。
struct PodcastDetailView: View {
    let podcast: Podcast

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

    @State private var episodes: [Episode] = []
    @State private var loaded: Podcast?
    @State private var loading = false
    /// 非 nil = 当前内容来自磁盘缓存,联网刷新还没成功。
    @State private var staleAt: Date?
    /// 源被平台限制时,空态写「数据源暂不可用」而不是「暂无单集」(见 H308)。
    @State private var sourceUnavailable = false
    @State private var shareImage: UIImage?
    @State private var showShare = false
    @StateObject private var selection = EpisodeSelection()
    /// 私有订阅源的 401 挑战(见 `FeedAuthChallenge` / H253)。
    @State private var authPrompt: FeedAuthChallenge?

    private var display: Podcast { loaded ?? podcast }
    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var channelKey: String { display.feedUrl.isEmpty ? display.title : display.feedUrl }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                header

                if let staleAt { OfflineNotice(cachedAt: staleAt) }

                if loading && episodes.isEmpty {
                    StateView(loading: true, text: "").frame(minHeight: 240)
                } else if episodes.isEmpty {
                    VStack(spacing: 14) {
                        StateView(symbol: sourceUnavailable ? "cloud.exclamation" : "waveform.slash",
                                  text: sourceUnavailable ? "数据源暂不可用" : "该节目暂无内容")
                        Button("重试") { Task { await load(force: true) } }
                            .buttonStyle(.bordered)
                    }
                    .frame(minHeight: 240)
                } else {
                    episodeSection
                }
            }
            .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .navigationTitle(display.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.selecting {
                EpisodeSelectionBar(
                    count: selection.picked.count,
                    allSelected: selection.picked.count >= episodes.count,
                    onAll: { selection.picked = Set(episodes.map(\.id)) },
                    onEnqueue: {
                        selection.enqueue(from: episodes, using: player, log: "列=频道 \(channelKey)")
                    },
                    onExit: { selection.reset() },
                    accent: accent)
            }
        }
        .selectionToast(selection)
        .refreshable { await load(force: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    shareImage = nil
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("朋友圈海报"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load(force: true) } } label: {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading)
                .accessibilityLabel(Text("刷新"))
            }
        }
        .sheet(isPresented: $showShare) {
            Group {
                if let image = shareImage {
                    ShareCardPreview(
                        title: "朋友圈海报",
                        image: image,
                        fileName: "reverb-moments-\(abs(display.feedUrl.hashValue)).png",
                        accent: accent)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在生成…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .presentationDetents([.medium])
                }
            }
            .task { await renderShareCard() }
        }
        .task(id: podcast.id) { await load() }
        // 只有**本页这个源**的 401 才弹框:同一时刻别处(发现页、追更巡检)也可能在拉 feed。
        .onReceive(env.repository.authRequired) { challenge in
            guard env.repository.cleanUrl(podcast.feedUrl) == challenge.feedUrl else { return }
            authPrompt = challenge
        }
        .sheet(item: $authPrompt) { challenge in
            FeedAuthSheet(
                feedUrl: challenge.feedUrl,
                failed: challenge.failed,
                initialUsername: env.repository.credential(for: challenge.feedUrl)?.username ?? "",
                onSubmit: { user, pass in
                    env.repository.saveAuth(challenge.feedUrl, username: user, password: pass)
                    authPrompt = nil
                    Task { await load(force: true) }
                },
                onCancel: { authPrompt = nil }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Artwork(url: display.artworkUrl, size: 124, corner: 16)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 10) {
                    Text(display.title)
                        .font(.title3.bold())
                        .lineLimit(4)
                    if !display.author.isEmpty {
                        Text(display.author)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    subscribeButton
                    let listenedSec = env.listenedSeconds(for: channelKey)
                    if listenedSec > 0 {
                        Label("已收听 \(Fmt.duration(listenedSec))", systemImage: "headphones")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let desc = Fmt.plainText(display.description)
            if !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
    }

    private var subscribeButton: some View {
        let subscribed = env.subscriptions.isSubscribed(display.id)
        return Button {
            env.subscriptions.toggle(display)
        } label: {
            Label(subscribed ? "已订阅" : "订阅",
                  systemImage: subscribed ? "checkmark" : "plus")
                .font(.callout.weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .controlSize(.small)
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("单集")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    player.playQueue(episodes, startIndex: 0, tag: ListTag.podcast(channelKey))
                } label: {
                    Label("全部播放", systemImage: "play.fill")
                        .font(.footnote)
                }
                PlayModeButton(tag: ListTag.podcast(channelKey))
            }
            .padding(.bottom, 4)
            LazyVStack(spacing: 0) {
                ForEach(episodes) { ep in
                    HStack(spacing: 10) {
                        RoomyEpisodeRow(
                            episode: ep,
                            isCurrent: player.current?.id == ep.id,
                            isPlaying: player.isPlaying,
                            played: env.history.isPlayed(ep.id),
                            accent: accent,
                            // 已经在频道页里,封面再点只会把同一个频道压进栈。
                            coverOpensChannel: false,
                            selecting: selection.selecting,
                            selected: selection.picked.contains(ep.id),
                            onPlay: {
                                if selection.selecting { selection.toggle(ep) }
                                else { player.playOrToggle(ep, queue: episodes, tag: ListTag.podcast(channelKey)) }
                            },
                            onEnterSelection: { selection.enter(ep.id) })
                        if !selection.selecting {
                            EpisodeDownloadButton(episode: ep, accent: accent)
                        }
                    }
                }
            }
        }
    }

    private func renderShareCard() async {
        let art = await loadUIImage(display.artworkUrl)
        shareImage = renderImage(ChannelShareCard(podcast: display, accent: accent, artwork: art))
    }

    private func load(force: Bool = false) async {
        if !force && !episodes.isEmpty { return }
        if !force, let cached = env.repository.cachedFeed(podcast.feedUrl), !cached.episodes.isEmpty {
            loaded = cached.podcast
            episodes = cached.episodes
            staleAt = env.repository.feedCachedAt(podcast.feedUrl)
        }
        loading = true
        // 平台级拦截已被解析层短期熔断,这里不再连打;普通失败退避 1s / 2s / 4s。
        var result = await env.repository.feed(podcast.feedUrl)
        var delayNs: UInt64 = 1_000_000_000
        var tries = 0
        while (result == nil || result?.episodes.isEmpty == true),
              env.repository.feedStatus(podcast.feedUrl) != .unavailable,
              tries < 3 {
            try? await Task.sleep(nanoseconds: delayNs)
            result = await env.repository.feed(podcast.feedUrl)
            delayNs *= 2
            tries += 1
        }
        sourceUnavailable = env.repository.feedStatus(podcast.feedUrl) == .unavailable
                         && (result?.episodes.isEmpty ?? true)
        if let r = result {
            loaded = r.podcast
            if !r.episodes.isEmpty {
                episodes = r.episodes
                staleAt = nil
            }
        }
        loading = false
    }
}

private extension AppEnvironment {
    /// 频道累计收听秒数。key 口径与 ListenStatsStore 一致。
    func listenedSeconds(for key: String) -> Int {
        listenStats.listenedMs(for: key) / 1000
    }
}