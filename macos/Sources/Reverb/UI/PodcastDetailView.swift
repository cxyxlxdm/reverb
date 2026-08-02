import SwiftUI

/// 频道详情:大头部(封面 / 标题 / 作者 / 订阅 / 简介)+ 宽松分集列表。
struct PodcastDetailView: View {
    let podcast: Podcast

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

    @State private var episodes: [Episode] = []
    @State private var loaded: Podcast?
    @State private var loading = false

    private var display: Podcast { loaded ?? podcast }
    private var accent: Color { Theme.accent(settings.accentIndex) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                header

                if loading && episodes.isEmpty {
                    StateView(loading: true, text: "").frame(minHeight: 280)
                } else if episodes.isEmpty {
                    StateView(symbol: "waveform.slash", text: "暂无单集").frame(minHeight: 280)
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
                                        accent: accent,
                                        onPlay: { player.playOrToggle(ep, queue: episodes) })
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
        .task { await load() }
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
                if !display.description.isEmpty {
                    Text(display.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .lineLimit(6)
                        .textSelection(.enabled)
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

    private func load() async {
        guard episodes.isEmpty else { return }
        loading = true
        if let result = await env.repository.feed(podcast.feedUrl) {
            loaded = result.podcast
            episodes = result.episodes
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
