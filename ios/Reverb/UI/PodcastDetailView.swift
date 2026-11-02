import SwiftUI

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
                        StateView(symbol: "waveform.slash", text: "暂无单集")
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
        .refreshable { await load(force: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load(force: true) } } label: {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading)
                .accessibilityLabel(Text("刷新"))
            }
        }
        .task(id: podcast.id) { await load() }
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
                            onPlay: {
                                player.playOrToggle(ep, queue: episodes, tag: ListTag.podcast(channelKey))
                            })
                        EpisodeDownloadButton(episode: ep, accent: accent)
                    }
                }
            }
        }
    }

    private func load(force: Bool = false) async {
        if !force && !episodes.isEmpty { return }
        if !force, let cached = env.repository.cachedFeed(podcast.feedUrl), !cached.episodes.isEmpty {
            loaded = cached.podcast
            episodes = cached.episodes
            staleAt = env.repository.feedCachedAt(podcast.feedUrl)
        }
        loading = true
        var result = await env.repository.feed(podcast.feedUrl)
        var tries = 0
        while (result == nil || result?.episodes.isEmpty == true) && tries < 2 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            result = await env.repository.feed(podcast.feedUrl)
            tries += 1
        }
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