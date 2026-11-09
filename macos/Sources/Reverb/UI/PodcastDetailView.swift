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
    @State private var shareCardURL: URL?
    /// 非 nil 表示当前内容来自磁盘缓存、联网刷新还没成功,据此显示「离线内容」提示
    @State private var staleAt: Date?
    /// 多选批量加入待播(桌面形态:工具栏「选择」,与音阁 / 追更同一套,见 M5)。
    /// 状态放在 `EpisodeSelection` 里:推入下一个频道时本页重建,已选集合随之清空。
    @StateObject private var selection = EpisodeSelection()
    /// 私有订阅源的 401 挑战(见 `FeedAuthChallenge` / H253)。
    @State private var authPrompt: FeedAuthChallenge?

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
                        HStack {
                            Text("单集")
                                .font(.title3).fontWeight(.semibold)
                            Spacer()
                            // 这一列的播放模式(与音阁三段用的是同一颗按钮、同一套 tag 规则)。
                            PlayModeButton(tag: ListTag.podcast(channelKey))
                        }
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
                                        // 已经在频道页里了,封面再点一次只会把同一个频道压进栈
                                        // (Android `coverChannelJump` 同一条门)。
                                        coverOpensChannel: false,
                                        selecting: selection.selecting,
                                        selected: selection.picked.contains(ep.id),
                                        onPlay: {
                                            if selection.selecting { selection.toggle(ep) }
                                            else {
                                                player.playOrToggle(ep, queue: episodes,
                                                                    tag: ListTag.podcast(channelKey))
                                            }
                                        })
                                        .episodeContextMenu(ep, enabled: !selection.selecting)
                                    if !selection.selecting {
                                        EpisodeDownloadButton(episode: ep, accent: accent)
                                    }
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
        .toolbar {
            // 手动刷新:macOS 没有下拉手势,与发现页一致用工具栏按钮(触控板横滑仍然可用)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load(force: true) }
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("刷新")
            }
            ToolbarItem(placement: .primaryAction) {
                if let shareCardURL {
                    ShareLink(item: shareCardURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("分享")
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.tertiary)
                        .help("分享")
                }
            }
            // 频道页也能批量入队(Android / 鸿蒙 2026-10-17 补的同一栏)。
            if !episodes.isEmpty {
                if selection.selecting {
                    EpisodeBatchToolbar(episodes: episodes,
                                        selecting: $selection.selecting, picked: $selection.picked) {
                        selection.enqueue(from: episodes, using: player, log: "列=频道 \(channelKey)")
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
        .task(id: "\(display.title)|\(display.artworkUrl)|\(settings.accentIndex)") {
            await prepareShareCard()
        }
    }

    // MARK: - 多选

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

    @MainActor
    private func prepareShareCard() async {
        shareCardURL = nil
        let target = display
        let artwork = await loadNSImage(target.artworkUrl)
        if Task.isCancelled { return }
        shareCardURL = renderPNG(ChannelShareCard(podcast: target, accent: accent, artwork: artwork))
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
            if BilibiliSource.isPseudo(episode.audioUrl) {
                // 视频集的音频直链带 2 小时 `deadline`,存不住,而「下载」在别处承诺的正是
                // 「长期留在盘上」⇒ 这个动作对视频集不成立。**置灰但留着**:同一列表里各行的
                // 键位不该错开(用户 2026-10-28 拍的口径是「置灰」,不是隐藏)。
                // 判据从**集子自己**的 audioUrl 推、不由调用方传 —— 搜索结果 / 历史 / 待播 /
                // 收藏里都可能有视频源的单集,逐个调用点传就一定会漏一处。
                // 自动缓存(300 MB 预算那一套)仍然保留:它是浏览器缓存同性质的东西。
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .opacity(0.4)
                    .help("下载不可用")
                    .accessibilityLabel(Text("下载不可用"))
            } else if downloads.contains(episode.id) {
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
