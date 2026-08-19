import SwiftUI

/// 频道详情:大头部(封面 / 标题 / 作者 / 订阅 / 简介)+ 宽松分集列表。
struct PodcastDetailView: View {
    let podcast: Podcast

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var listenStats: ListenStatsStore

    @State private var episodes: [Episode] = []
    @State private var loaded: Podcast?
    @State private var loading = false
    /// 非 nil 表示当前内容来自磁盘缓存、联网刷新还没成功,据此显示「离线内容」提示
    @State private var staleAt: Date?

    private var display: Podcast { loaded ?? podcast }
    private var accent: Color { Theme.accent(settings.accentIndex) }
    /// 频道键:与 ListenStatsStore.key(for:) 一致(feedUrl 优先,回退频道名)。
    private var channelKey: String { display.feedUrl.isEmpty ? display.title : display.feedUrl }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                header

                // 展示的是缓存、刷新尚未成功 —— 明确告诉用户内容可能不是最新的
                if let staleAt { OfflineNotice(cachedAt: staleAt) }

                if loading && episodes.isEmpty {
                    StateView(loading: true, text: "").frame(minHeight: 280)
                } else if episodes.isEmpty {
                    VStack(spacing: 14) {
                        StateView(symbol: "waveform.slash", text: "暂无单集")
                        Button("重试") { Task { await load(force: true) } }
                            .buttonStyle(.bordered)
                    }
                    .frame(minHeight: 280)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("单集")
                            .font(.title3).fontWeight(.semibold)
                            .padding(.bottom, 4)
                        LazyVStack(spacing: 0) {
                            ForEach(episodes) { ep in
                                HStack(spacing: 12) {
                                    RoomyEpisodeRow(
                                        episode: ep,
                                        isCurrent: player.current?.id == ep.id,
                                        isPlaying: player.isPlaying,
                                        played: env.history.isPlayed(ep.id),
                                        accent: accent,
                                        onPlay: { player.playOrToggle(ep, queue: episodes) })
                                        .episodeContextMenu(ep)
                                    EpisodeDownloadButton(episode: ep, accent: accent)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.topPadding)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .navigationTitle(display.title)
        .task(id: podcast.id) { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
            Artwork(url: display.artworkUrl, size: 180, corner: 18)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 12) {
                Text(display.title)
                    .font(.largeTitle).fontWeight(.bold)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if !display.author.isEmpty {
                    Text(display.author)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                subscribeButton
                    .padding(.top, 4)
                let listenedSec = listenStats.listenedMs(for: channelKey) / 1000
                if listenedSec > 0 {
                    Label("已收听 \(Fmt.duration(listenedSec))", systemImage: "headphones")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                let desc = Fmt.plainText(display.description)
                if !desc.isEmpty {
                    Text(desc)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    private var subscribeButton: some View {
        let subscribed = env.subscriptions.isSubscribed(display.id)
        return Button {
            env.subscriptions.toggle(display)
        } label: {
            Label(subscribed ? "已订阅" : "订阅",
                  systemImage: subscribed ? "checkmark" : "plus")
                .frame(minWidth: 84)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func load(force: Bool = false) async {
        if !force && !episodes.isEmpty { return }
        // 先出缓存:秒开,且断网时也有内容可看
        if !force, let cached = env.repository.cachedFeed(podcast.feedUrl), !cached.episodes.isEmpty {
            loaded = cached.podcast
            episodes = cached.episodes
            staleAt = env.repository.feedCachedAt(podcast.feedUrl)
        }
        loading = true
        // 首次请求偶发失败(冷连接/重定向),重试至多 3 次再放弃
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
                staleAt = nil          // 拿到新数据,撤掉离线提示
            }
        }
        loading = false
    }
}

/// 单集下载控制:未下载(下载图标)→ 下载中(进度环)→ 已下载(勾选,点击删除需确认)。
struct EpisodeDownloadButton: View {
    let episode: Episode
    var accent: Color = .accentColor

    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if downloads.contains(episode.id) {
                Button { confirmDelete = true } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("已下载 · 点击删除")
                .confirmationDialog("删除此单集的离线文件?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除", role: .destructive) { downloadManager.delete(episode.id) }
                    Button("取消", role: .cancel) {}
                }
            } else if downloadManager.isDownloading(episode.id) {
                ProgressView(value: downloadManager.progress[episode.id] ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("下载中")
            } else {
                Button { downloadManager.download(episode) } label: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("下载")
                .disabled(episode.audioUrl.isEmpty)
            }
        }
        .font(.system(size: 20))
        .frame(width: 28, height: 28)
    }
}
