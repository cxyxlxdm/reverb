import SwiftUI

/// 发现页分类。genreId 为 nil 表示综合推荐。key 与 macOS / 手机两端同义。
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

    static var allGenreIds: [Int?] { all.compactMap { $0.genreId }.map { Optional($0) } }

    /// 口径与 Android `loadOrdered()` / 鸿蒙 `CategoryStore.ordered()` / macOS 逐条一致。
    static func ordered(by keys: [String]) -> [DiscoverCategory] {
        guard !keys.isEmpty else { return all }
        let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
        var seen = Set<String>()
        var out: [DiscoverCategory] = []
        for k in keys {
            guard let c = byKey[k], seen.insert(k).inserted else { continue }
            out.append(c)
        }
        for c in all where !seen.contains(c.key) { out.append(c) }
        return out
    }
}

struct DiscoverView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

    @State private var selected = DiscoverCategory.all[0]
    @State private var showReorder = false
    @State private var popular: [Podcast] = []
    @State private var loading = false
    @State private var isSeed = false

    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var searchPodcasts: [Podcast] = []
    @State private var searchEpisodes: [Episode] = []
    @State private var searchSource = ""
    @State private var searching = false
    @State private var liveEpisode: Episode?
    /// 仅 Debug:`-search` 钩子写下的查询词,用来挡住搜索框复位带来的清空。
    @State private var debugQuery = ""
    /// 「加入待播」的结果提示:入队落在待播页,当前页看不出任何变化,不提示等于没按上。
    @State private var toast: String?
    @State private var toastToken = 0

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var isSearchActive: Bool { !submittedQuery.isEmpty }
    private var categories: [DiscoverCategory] { DiscoverCategory.ordered(by: settings.categoryOrder) }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        Group {
            if isSearchActive { searchContent } else { popularContent }
        }
        .navigationTitle("余音")
        // 标题与右侧按钮同处工具栏一行,不再另起一行大标题(四个 tab 同口径)。
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索播客/视频或粘贴 RSS、直播流、视频链接")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: searchText) { _, v in
            // `-search` 验收钩子设进去的查询词会被 `.searchable` 的初始绑定复位成空串;
            // 那一轮空串不能把已提交的查询也清掉(否则跑完搜索又退回榜单页)。
            if v.trimmingCharacters(in: .whitespaces).isEmpty && debugQuery.isEmpty {
                submittedQuery = ""
                searchPodcasts = []
                searchEpisodes = []
                searchSource = ""
                liveEpisode = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { refreshButton }
            ToolbarItem(placement: .topBarTrailing) { radioButton }
        }
        .task {
            await loadPopular(initial: true)
            #if DEBUG
            // 与 RootView 的 `-start-tab` 同一类验收钩子:中文关键词没法用 `simctl`
            // 或 adb 注入,所以留一个启动即搜索的参数,Release / TestFlight 里不存在。
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-search"), i + 1 < args.count {
                // 必须等 `.searchable` 挂上再赋值:`.task` 先跑时设进去的值会被搜索框的
                // 初始绑定复位成空串,连带 `onChange` 把 `submittedQuery` 也清掉。
                try? await Task.sleep(nanoseconds: 800_000_000)
                let q = args[i + 1]
                debugQuery = q
                searchText = q
                runSearch(q)
            }
            #endif
        }
        .sheet(isPresented: $showReorder) {
            CategoryOrderSheet(initial: categories) { ordered in
                if !ordered.isEmpty { settings.categoryOrder = ordered.map(\.key) }
                showReorder = false
            } onCancel: {
                showReorder = false
            }
        }
        .overlay(alignment: .top) { TopToast(text: toast) }
        // 地区换了榜单就该跟着换:数据是按 region 取的缓存键,不重载会把上一地区的
        // 「每日热门」原地留到下次冷启动(与 macOS 设置页那条 onChange 同一理由)。
        .onChange(of: settings.regionOverride) { _, _ in
            Task { await loadPopular(initial: false) }
        }
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toastToken == token { toast = nil }
        }
    }

    // MARK: - 榜单

    private var continueItems: [HistoryEntry] {
        Array(env.history.history
            .filter { e in
                e.durationMs > 0
                    && e.positionMs >= 10_000
                    && e.positionMs <= Int(Double(e.durationMs) * 0.95)
                    && !e.played
                    && !e.episode.isLive
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(15))
    }

    private var firstRun: Bool {
        env.subscriptions.subscriptions.isEmpty && env.history.history.isEmpty
    }

    @ViewBuilder
    private var guideCard: some View {
        if let ep = GuideEpisode.make() {
            Button {
                player.playQueue([ep], startIndex: 0)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle")
                        .font(.title2)
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("余音使用引导").font(.body)
                        Text("30 秒 · 内置音频，不联网也能播")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private var continueStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续收听").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(continueItems) { entry in
                        ContinueCard(entry: entry, accent: accent) {
                            player.playQueue([entry.episode], startIndex: 0)
                        }
                        .contextMenu {
                            Button {
                                player.playNext(entry.episode)
                            } label: {
                                Label("下一个播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Button {
                                player.enqueue(entry.episode)
                                showToast(NSLocalizedString("已加入待播", comment: "入队结果提示"))
                            } label: {
                                Label("加入待播", systemImage: "text.badge.plus")
                            }
                            // 卡片能出现在这条横里就说明它未播完(过滤条件如此),所以只给单向的
                            // 「标记已播完」;撤销入口在音阁 · 历史(reverse 才是那条列的本分)。
                            Button {
                                env.history.markPlayed(entry.episode.id, true)
                            } label: {
                                Label("标记为已播完", systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var popularContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if !continueItems.isEmpty {
                    continueStrip
                } else if firstRun {
                    guideCard
                }

                HStack(spacing: 10) {
                    Text(isSeed ? "内置精选" : "每日热门")
                        .font(.title3).fontWeight(.semibold)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 10)
                    categoryMenu
                }

                if popular.isEmpty {
                    StateView(loading: loading, symbol: "square.stack.3d.up.slash", text: "暂无内容")
                        .frame(minHeight: 260)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(popular) { p in
                            NavigationLink(value: p) { PodcastCard(podcast: p) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .refreshable { await loadPopular(initial: false) }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(categories) { c in
                Button {
                    guard c.id != selected.id else { return }
                    selected = c
                    Task { await loadPopular(initial: false) }
                } label: {
                    if c.id == selected.id { Label(LocalizedStringKey(c.name), systemImage: "checkmark") }
                    else { Text(LocalizedStringKey(c.name)) }
                }
            }
            Divider()
            Button {
                showReorder = true
            } label: {
                Label("自定义分类排序…", systemImage: "arrow.up.arrow.down")
            }
        } label: {
            HStack(spacing: 4) {
                Text("分类").foregroundStyle(.secondary)
                Text(LocalizedStringKey(selected.name)).foregroundStyle(accent)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func loadPopular(initial: Bool) async {
        let genreId = selected.genreId
        let region = env.region
        popular = env.repository.cachedPopular(genreId: genreId, region: region)
        isSeed = env.repository.isSeedList(genreId: genreId, region: region)
        loading = true
        let fresh = await env.repository.refreshPopular(genreId: genreId, region: region)
        guard selected.genreId == genreId else { return }
        if !fresh.isEmpty {
            popular = fresh
            isSeed = false
        }
        loading = false
    }

    // MARK: - 搜索

    private var searchContent: some View {
        ScrollView {
            if let live = liveEpisode, searchPodcasts.isEmpty && searchEpisodes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("直播流").font(.headline)
                    RoomyEpisodeRow(
                        episode: live,
                        isCurrent: player.current?.id == live.id,
                        isPlaying: player.isPlaying,
                        sourceTag: "直播",
                        coverOpensChannel: false,
                        onPlay: { player.playOrToggle(live, queue: [live]) }
                    )
                    Text("点一下开始收听。直播不记录播放进度,也不能快进或回看。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 8)
            } else if searching {
                StateView(loading: true, text: "搜索中…").frame(minHeight: 320)
            } else if searchPodcasts.isEmpty && searchEpisodes.isEmpty {
                StateView(symbol: "magnifyingglass",
                          text: "没有找到「\(submittedQuery)」").frame(minHeight: 320)
            } else {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if !searchPodcasts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Text("节目").font(.headline)
                                if !searchSource.isEmpty {
                                    Text(String(format: NSLocalizedString("来自 %@", comment: ""),
                                                searchSourceLabel))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(searchPodcasts) { p in
                                    NavigationLink(value: p) { PodcastCard(podcast: p) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !searchEpisodes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("单集").font(.headline).padding(.bottom, 4)
                            ForEach(searchEpisodes) { ep in
                                RoomyEpisodeRow(
                                    episode: ep,
                                    isCurrent: player.current?.id == ep.id,
                                    isPlaying: player.isPlaying,
                                    showPodcast: true,
                                    played: env.history.isPlayed(ep.id),
                                    accent: accent,
                                    sourceTag: BilibiliSource.isPseudo(ep.audioUrl) ? "B 站" : "Apple",
                                    onPlay: { player.playOrToggle(ep, queue: searchEpisodes) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 8)
            }
        }
    }

    private var searchSourceLabel: String {
        if searchSource.hasPrefix("Bilibili") { return "B 站" }
        if searchSource.hasPrefix("Apple") { return "Apple" }
        return searchSource
    }

    private func runSearch(_ raw: String? = nil) {
        let q = (raw ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        submittedQuery = q
        searching = true
        liveEpisode = nil
        searchPodcasts = []
        searchEpisodes = []
        searchSource = ""
        if LiveStream.looksLikeStream(q) {
            // 直播流与目录搜索是**互斥**的两种结果形态(与 Android `DiscoverState.Live`
            // 同一条:那边识别成流之后根本不发目录请求)。原先这里两条路一起跑,
            // 于是"粘一个流地址却搜出几个同名播客"时,直播那一块被条件挡在结果后面、看不见。
            Task {
                let live = await LiveStream.resolve(q)
                guard submittedQuery == q else { return }
                liveEpisode = live
                searching = false
            }
            return
        }
        Task {
            async let podsTask = env.repository.search(q, region: env.region)
            async let epsTask = env.repository.searchEpisodes(q, region: env.region)
            let pods = await podsTask
            let eps = await epsTask
            guard submittedQuery == q else { return }
            searchPodcasts = pods.podcasts
            searchSource = pods.source
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
        .disabled(loading || isSearchActive)
        .accessibilityLabel(Text("刷新"))
    }

    private var radioButton: some View {
        Menu {
            Button {
                if player.radioMode { player.next() } else { startRadio() }
            } label: {
                Label(player.radioMode ? "下一集" : (settings.contextualRadio ? "情境电台" : "随机电台"),
                      systemImage: radioIcon)
            }
            if player.radioMode {
                Button("停止电台", role: .destructive) { player.stopRadio() }
            }
        } label: {
            Image(systemName: radioIcon)
        }
        .accessibilityLabel(Text("电台"))
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
        let playerRef = player
        player.startRadio {
            await repo.randomEpisode(region: region, genreIds: genreIds,
                                     exclude: playerRef.recentRadioIds())
        }
        Task {
            if let first = await repo.randomEpisode(region: region, genreIds: genreIds,
                                                    exclude: playerRef.recentRadioIds()) {
                playerRef.playRadioEpisode(first)
            } else {
                playerRef.stopRadio()
            }
        }
    }
}

/// 分类排序弹窗:拖动行调整顺序,完成才落盘。
private struct CategoryOrderSheet: View {
    @State private var items: [DiscoverCategory]
    var onDone: ([DiscoverCategory]) -> Void
    var onCancel: () -> Void

    init(initial: [DiscoverCategory],
         onDone: @escaping ([DiscoverCategory]) -> Void,
         onCancel: @escaping () -> Void) {
        _items = State(initialValue: initial)
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { c in
                    Text(LocalizedStringKey(c.name))
                }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("自定义分类排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDone(items) }
                }
            }
        }
    }
}

/// 「继续收听」横向卡片:封面 + 标题(两行) + 细进度条。点按续播。
private struct ContinueCard: View {
    let entry: HistoryEntry
    var accent: Color
    var onTap: () -> Void
    private let width: CGFloat = 122

    private var progress: Double {
        guard entry.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(entry.positionMs) / Double(entry.durationMs)))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: entry.episode.artworkUrl, size: width, corner: 10)
                Text(entry.episode.title)
                    .font(.callout).fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, height: 38, alignment: .topLeading)
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
    }
}