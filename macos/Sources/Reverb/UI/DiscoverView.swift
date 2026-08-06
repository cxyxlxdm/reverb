import SwiftUI

/// 发现页分类。genreId 为 nil 表示综合推荐。
struct DiscoverCategory: Identifiable, Hashable {
    let key: String
    let name: String
    let genreId: Int?
    var id: String { key }

    static let all: [DiscoverCategory] = [
        .init(key: "recommend", name: "推荐", genreId: nil),
        .init(key: "news", name: "新闻", genreId: 1489),
        .init(key: "business", name: "商业", genreId: 1321),
        .init(key: "tech", name: "科技", genreId: 1318),
        .init(key: "culture", name: "文化", genreId: 1324),
        .init(key: "knowledge", name: "知识", genreId: 1533),
        .init(key: "education", name: "教育", genreId: 1304),
        .init(key: "comedy", name: "喜剧", genreId: 1303),
        .init(key: "health", name: "健康", genreId: 1512),
        .init(key: "history", name: "历史", genreId: 1487),
        .init(key: "sports", name: "体育", genreId: 1545),
        .init(key: "food", name: "美食", genreId: 1306),
        .init(key: "travel", name: "旅行", genreId: 1320),
        .init(key: "anime", name: "动漫", genreId: 1499),
        .init(key: "relationship", name: "情感", genreId: 1517),
        .init(key: "arts", name: "艺术", genreId: 1301),
        .init(key: "music", name: "音乐", genreId: 1310),
        .init(key: "kids", name: "亲子", genreId: 1305),
        .init(key: "tv", name: "影视", genreId: 1309)
    ]

    /// 全部分类的 genreId(用于随机电台)。
    static var allGenreIds: [Int?] { all.compactMap { $0.genreId }.map { Optional($0) } }
}

struct DiscoverView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

    @State private var selected: DiscoverCategory = DiscoverCategory.all[0]
    @State private var popular: [Podcast] = []
    @State private var loading = false

    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var searchPodcasts: [Podcast] = []
    @State private var searchEpisodes: [Episode] = []
    @State private var searching = false

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var isSearchActive: Bool { !submittedQuery.isEmpty }

    private let columns = [GridItem(.adaptive(minimum: Metrics.cardMin, maximum: Metrics.cardMax),
                                    spacing: Metrics.gridSpacing)]

    var body: some View {
        Group {
            if isSearchActive {
                searchContent
            } else {
                popularContent
            }
        }
        .navigationTitle("余音")
        .searchable(text: $searchText, placement: .toolbar,
                    prompt: "搜索节目、单集或粘贴 RSS 链接")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: searchText) { v in
            if v.trimmingCharacters(in: .whitespaces).isEmpty {
                submittedQuery = ""
                searchPodcasts = []
                searchEpisodes = []
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { refreshButton }
            ToolbarItem(placement: .primaryAction) { radioButton }
        }
        .task { await loadPopular(initial: true) }
    }

    // MARK: - 榜单

    // MARK: - 继续收听

    /// 进行中的单集:有时长、进度在 10s 与 95% 之间、未播完;按更新时间倒序,至多 15 条。
    private var continueItems: [HistoryEntry] {
        Array(env.history.history
            .filter { e in
                e.durationMs > 0
                    && e.positionMs >= 10_000
                    && e.positionMs <= Int(Double(e.durationMs) * 0.95)
                    && !e.played
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(15))
    }

    private var continueStrip: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("继续收听").font(.title3).fontWeight(.semibold)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(continueItems) { entry in
                        ContinueCard(entry: entry, accent: accent) {
                            player.playQueue([entry.episode], startIndex: 0)
                        }
                        .episodeContextMenu(entry.episode)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var popularContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if !continueItems.isEmpty { continueStrip }

                HStack(spacing: 12) {
                    Text("每日热门")
                        .font(.title2).fontWeight(.semibold)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 12)
                    categoryMenu
                }

                if popular.isEmpty {
                    StateView(loading: loading, symbol: "square.stack.3d.up.slash",
                              text: "暂无内容")
                        .frame(minHeight: 320)
                } else {
                    LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                        ForEach(popular) { p in
                            NavigationLink(value: p) { PodcastCard(podcast: p) }
                                .buttonStyle(.plain)
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
    }

    /// 安静的分类下拉,取代原先密集的胶囊条。
    private var categoryMenu: some View {
        Menu {
            ForEach(DiscoverCategory.all) { c in
                Button {
                    guard c.id != selected.id else { return }
                    selected = c
                    Task { await loadPopular(initial: false) }
                } label: {
                    if c.id == selected.id { Label(LocalizedStringKey(c.name), systemImage: "checkmark") }
                    else { Text(LocalizedStringKey(c.name)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("分类").foregroundStyle(.secondary)
                Text(LocalizedStringKey(selected.name)).foregroundStyle(accent)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .noFocusRing()
    }

    private func loadPopular(initial: Bool) async {
        let genreId = selected.genreId
        let region = env.region
        popular = env.repository.cachedPopular(genreId: genreId, region: region)
        loading = true
        let fresh = await env.repository.refreshPopular(genreId: genreId, region: region)
        guard selected.genreId == genreId else { return }
        if !fresh.isEmpty { popular = fresh }
        loading = false
    }

    // MARK: - 搜索

    private var searchContent: some View {
        ScrollView {
            if searching {
                StateView(loading: true, text: "搜索中…").frame(minHeight: 360)
            } else if searchPodcasts.isEmpty && searchEpisodes.isEmpty {
                StateView(symbol: "magnifyingglass",
                          text: "没有找到「\(submittedQuery)」").frame(minHeight: 360)
            } else {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if !searchPodcasts.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("节目").font(.title3).fontWeight(.semibold)
                            LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                                ForEach(searchPodcasts) { p in
                                    NavigationLink(value: p) { PodcastCard(podcast: p) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !searchEpisodes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("单集").font(.title3).fontWeight(.semibold)
                                .padding(.bottom, 4)
                            ForEach(searchEpisodes) { ep in
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    played: env.history.isPlayed(ep.id),
                                    accent: accent,
                                    onPlay: { player.playOrToggle(ep, queue: searchEpisodes) })
                                    .episodeContextMenu(ep)
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
        }
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        submittedQuery = q
        searching = true
        Task {
            async let podsTask = env.repository.search(q, region: env.region)
            async let epsTask = env.repository.searchEpisodes(q, region: env.region)
            let pods = await podsTask
            let eps = await epsTask
            guard submittedQuery == q else { return }
            searchPodcasts = pods.podcasts
            searchEpisodes = eps
            searching = false
        }
    }

    // MARK: - 电台

    private var refreshButton: some View {
        Button {
            Task { await loadPopular(initial: false) }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("刷新")
        .disabled(loading || isSearchActive)
        .noFocusRing()
    }

    private var radioButton: some View {
        Button {
            if player.radioMode { player.next() } else { startRadio() }
        } label: {
            Image(systemName: radioIcon)
        }
        .help(player.radioMode ? "下一集(右键停止电台)"
              : (settings.contextualRadio ? "情境电台" : "随机电台"))
        .contextMenu {
            if player.radioMode {
                Button("停止电台", role: .destructive) { player.stopRadio() }
            }
        }
    }

    private var radioIcon: String {
        guard settings.contextualRadio else { return "shuffle" }
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5...10: return "sunrise"
        case 11...16: return "sun.max"
        case 17...19: return "sunset"
        default: return "moon.stars"
        }
    }

    /// 依据小时选择情境分类的 genreId。
    private func contextualGenreIds() -> [Int?] {
        let h = Calendar.current.component(.hour, from: Date())
        let ids: [Int]
        switch h {
        case 5...8: ids = [1489, 1321, 1533]
        case 9...11: ids = [1489, 1318, 1321]
        case 12...13: ids = [1303, 1324, 1306]
        case 14...17: ids = [1318, 1533, 1324]
        case 18...21: ids = [1303, 1310, 1517, 1324]
        default: ids = [1512, 1310, 1324]
        }
        return ids.map { Optional($0) }
    }

    private func startRadio() {
        let region = env.region
        let genreIds = settings.contextualRadio ? contextualGenreIds() : DiscoverCategory.allGenreIds
        let repo = env.repository
        player.startRadio { await repo.randomEpisode(region: region, genreIds: genreIds, exclude: []) }
        Task {
            if let first = await repo.randomEpisode(region: region, genreIds: genreIds, exclude: []) {
                player.playRadioEpisode(first)
            } else {
                player.stopRadio()
            }
        }
    }
}

/// 「继续收听」横向卡片:封面 + 标题(两行) + 细进度条。点按续播。
private struct ContinueCard: View {
    let entry: HistoryEntry
    var accent: Color
    var onTap: () -> Void
    @State private var hover = false

    private let width: CGFloat = 132

    private var progress: Double {
        guard entry.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(entry.positionMs) / Double(entry.durationMs)))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Artwork(url: entry.episode.artworkUrl, size: width, corner: 12)
                    .shadow(color: .black.opacity(hover ? 0.20 : 0.10),
                            radius: hover ? 12 : 6, y: hover ? 5 : 3)
                Text(entry.episode.title)
                    .font(.callout).fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, height: 40, alignment: .topLeading)
                // 细进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(accent).frame(width: geo.size.width * progress)
                    }
                }
                .frame(width: width, height: 3)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.18), value: hover)
    }
}
