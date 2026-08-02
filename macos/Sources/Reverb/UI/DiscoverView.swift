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

    @State private var selected: DiscoverCategory = DiscoverCategory.all[0]
    @State private var popular: [Podcast] = []
    @State private var loading = false

    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var searchPodcasts: [Podcast] = []
    @State private var searchEpisodes: [Episode] = []
    @State private var searching = false

    private var isSearchActive: Bool { !submittedQuery.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if isSearchActive {
                    searchResults
                } else {
                    popularList
                }
            }
            .navigationTitle("发现")
            .navigationDestination(for: Podcast.self) { PodcastDetailView(podcast: $0) }
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索节目、单集或粘贴 RSS 链接")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: searchText) { v in
                if v.trimmingCharacters(in: .whitespaces).isEmpty {
                    submittedQuery = ""
                    searchPodcasts = []
                    searchEpisodes = []
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { radioButton }
            }
        }
        .task { await loadPopular(initial: true) }
    }

    // MARK: - 榜单

    private var popularList: some View {
        VStack(spacing: 0) {
            categoryChips
            Divider()
            List {
                ForEach(popular) { p in
                    NavigationLink(value: p) { PodcastRow(podcast: p) }
                }
                if popular.isEmpty {
                    ContentUnavailableViewCompat(loading: loading, text: "暂无内容")
                }
            }
            .listStyle(.inset)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DiscoverCategory.all) { c in
                    let active = c.id == selected.id
                    Button {
                        guard c.id != selected.id else { return }
                        selected = c
                        Task { await loadPopular(initial: false) }
                    } label: {
                        Text(c.name)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(active ? Theme.accent(env.settings.accentIndex).opacity(0.18) : Color.gray.opacity(0.12),
                                        in: Capsule())
                            .foregroundStyle(active ? Theme.accent(env.settings.accentIndex) : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func loadPopular(initial: Bool) async {
        let genreId = selected.genreId
        let region = env.region
        popular = env.repository.cachedPopular(genreId: genreId, region: region)
        loading = true
        let fresh = await env.repository.refreshPopular(genreId: genreId, region: region)
        // 若期间用户切换了分类,忽略过期结果。
        guard selected.genreId == genreId else { return }
        if !fresh.isEmpty { popular = fresh }
        loading = false
    }

    // MARK: - 搜索

    private var searchResults: some View {
        List {
            if searching {
                ContentUnavailableViewCompat(loading: true, text: "搜索中…")
            } else {
                if !searchEpisodes.isEmpty {
                    Section("单集") {
                        ForEach(searchEpisodes) { ep in
                            EpisodeRow(episode: ep,
                                       isCurrent: player.current?.id == ep.id,
                                       isPlaying: player.isPlaying,
                                       showPodcast: true,
                                       onPlay: { player.playOrToggle(ep, queue: searchEpisodes) })
                        }
                    }
                }
                if !searchPodcasts.isEmpty {
                    Section("节目") {
                        ForEach(searchPodcasts) { p in
                            NavigationLink(value: p) { PodcastRow(podcast: p) }
                        }
                    }
                }
                if searchEpisodes.isEmpty && searchPodcasts.isEmpty {
                    ContentUnavailableViewCompat(loading: false, text: "没有找到「\(submittedQuery)」")
                }
            }
        }
        .listStyle(.inset)
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

    private var radioButton: some View {
        Button {
            if player.radioMode {
                player.next()
            } else {
                startRadio()
            }
        } label: {
            Image(systemName: radioIcon)
        }
        .help(player.radioMode ? "下一集(长按停止电台)" : (env.settings.contextualRadio ? "情境电台" : "随机电台"))
        .contextMenu {
            if player.radioMode {
                Button("停止电台", role: .destructive) { player.stopRadio() }
            }
        }
    }

    private var radioIcon: String {
        guard env.settings.contextualRadio else { return "shuffle" }
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5...8: return "sunrise"
        case 9...16: return "sun.max"
        case 17...20: return "sunset"
        default: return "moon"
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
        let genreIds = env.settings.contextualRadio ? contextualGenreIds() : DiscoverCategory.allGenreIds
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

/// macOS 13 兼容的空/加载态占位。
struct ContentUnavailableViewCompat: View {
    var loading: Bool
    var text: String
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                if loading { ProgressView() }
                Text(loading ? "加载中…" : text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 40)
            Spacer()
        }
        .listRowSeparator(.hidden)
    }
}
