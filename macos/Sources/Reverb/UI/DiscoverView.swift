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

    /// 按用户存下的 key 顺序排列(`SettingsStore.categoryOrder`),口径与 Android
    /// `DiscoverViewModel.loadOrdered()` / 鸿蒙 `CategoryStore.ordered()` 逐条一致:
    ///
    /// - 没存过(空数组)→ 原序;
    /// - 存过的按序取,**表里已经不在的 key 直接丢**(分类下线时不会留空位),重复的 key 只取第一次;
    /// - **新增的分类挂在末尾** —— 加了新分类不至于插到用户最看重的那个前面。
    ///   这一条同时兜住了"存的 key 全都不认识":它们全被丢掉,末尾补回原序的全部(与 Android
    ///   `loadOrdered()` 末尾那句 `+ DISCOVER_CATEGORIES.filter { … }` 同一个结果)。
    ///
    /// 用字典查而不是 `first(where:)`,因为本函数每次重渲都要跑一遍(19 项,仍是 O(n))。
    static func ordered(by keys: [String]) -> [DiscoverCategory] {
        guard !keys.isEmpty else { return all }
        let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
        var seen = Set<String>()
        var out: [DiscoverCategory] = []
        out.reserveCapacity(all.count)
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

    @State private var selected: DiscoverCategory = DiscoverCategory.all[0]
    @State private var showReorder = false
    @State private var popular: [Podcast] = []
    @State private var loading = false
    /// 当前列表来自随包内置清单(而非联网榜单),据此改标题
    @State private var isSeed = false

    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var searchPodcasts: [Podcast] = []
    @State private var searchEpisodes: [Episode] = []
    /// 节目那一路的来源短名(`Bilibili` / `Apple Podcasts` / …),仓储层给的原始标识。
    @State private var searchSource = ""
    @State private var searching = false
    /// 用户粘的是一路直播流时它非空(见 `LiveStream`)。它与三个搜索结果数组互斥:
    /// 直播流不是节目也不是单集,单独一条渲染。
    @State private var liveEpisode: Episode?

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var isSearchActive: Bool { !submittedQuery.isEmpty }
    /// 用户排过序就按它,没排过就是原序(见 `DiscoverCategory.ordered(by:)`)。
    private var categories: [DiscoverCategory] { DiscoverCategory.ordered(by: settings.categoryOrder) }

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
                    prompt: "搜索播客/视频或粘贴 RSS、直播流、视频链接")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: searchText) { v in
            if v.trimmingCharacters(in: .whitespaces).isEmpty {
                submittedQuery = ""
                searchPodcasts = []
                searchEpisodes = []
                searchSource = ""
                liveEpisode = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { refreshButton }
            ToolbarItem(placement: .primaryAction) { radioButton }
        }
        .task { await loadPopular(initial: true) }
        .sheet(isPresented: $showReorder) {
            CategoryOrderSheet(initial: categories) { ordered in
                // 空表不落盘:与 Android `saveOrder` 的早退、鸿蒙 `CategoryStore.save` 同一条
                // —— 「空」在有备份参与的语境里表示"从没排过",不能当成"恢复默认序"。
                if !ordered.isEmpty { settings.categoryOrder = ordered.map(\.key) }
                showReorder = false
            } onCancel: {
                showReorder = false
            }
            // sheet 是独立呈现,不继承窗口的 preferredColorScheme(见 `themedSheet` 注释);
            // 漏掉的症状是深色主题下这份白底表格里的黑字看不见。
            .themedSheet(settings)
        }
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

    /// 全新用户(既没订阅也没听过任何东西)才展示引导入口。
    /// 一旦有任何使用痕迹就不再出现 —— 它是引导,不是常驻功能。
    private var firstRun: Bool {
        env.subscriptions.subscriptions.isEmpty && env.history.history.isEmpty
    }

    /// 首次使用时的引导卡:点一下播放随包内置的 30 秒音频。
    /// 意义是让「全新安装 + 没网」也能走通完整播放链路,而不是对着空白猜是 App 坏了还是网不通。
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
        VStack(alignment: .leading, spacing: 14) {
            Text("继续收听").font(.title3).fontWeight(.semibold)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(continueItems) { entry in
                        ContinueCard(entry: entry, accent: accent) {
                            player.playQueue([entry.episode], startIndex: 0)
                        }
                        // 横条卡是全 App **唯一**保留正向「标记为已播完」的地方(H192 / D7):
                        // 它按"未播完"过滤,这颗同时是把条目从横条上拿掉的入口。两端同口径。
                        .episodeContextMenu(entry.episode,
                                            onMarkPlayed: { env.history.markPlayed(entry.episode.id, true) })
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

                HStack(spacing: 12) {
                    // 内置清单是打包时的榜单快照,不是今天的榜,标成「每日热门」会误导
                    Text(isSeed ? "内置精选" : "每日热门")
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
            // 排序入口放在这份下拉里而不是单独一颗工具栏按钮:桌面没有那条密集的胶囊条可挂图标,
            // 而「分类」这一份菜单正是它在这端的等价物(Android 把它挂在胶囊条右端)。
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .noFocusRing()
    }

    private func loadPopular(initial: Bool) async {
        let genreId = selected.genreId
        let region = env.region
        // 缓存为空时 cachedPopular 给出随包内置清单,首屏不空;联网刷新成功再替换
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
                // 直播流只有一条、也不是"节目/单集":不复用下面那两个分段,单独一段渲染。
                // 放在 `searching` 之前:探针通常比目录检索先回来,而那一边对电台地址
                // 要白等到超时 —— 让用户先看到这一条、点下去就能听。
                VStack(alignment: .leading, spacing: 8) {
                    Text("直播流").font(.title3).fontWeight(.semibold)
                    RoomyEpisodeRow(
                        episode: live,
                        isCurrent: player.current?.id == live.id,
                        isPlaying: player.isPlaying,
                        sourceTag: NSLocalizedString("直播", comment: ""),
                        coverOpensChannel: false,
                        onPlay: { player.playOrToggle(live, queue: [live]) }
                    )
                    Text("点一下开始收听。直播不记录播放进度,也不能快进或回看。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, Metrics.topPadding)
                .padding(.bottom, Metrics.sectionSpacing)
            } else if searching {
                StateView(loading: true, text: "搜索中…").frame(minHeight: 360)
            } else if searchPodcasts.isEmpty && searchEpisodes.isEmpty {
                StateView(symbol: "magnifyingglass",
                          text: "没有找到「\(submittedQuery)」").frame(minHeight: 360)
            } else {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if !searchPodcasts.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Text("节目").font(.title3).fontWeight(.semibold)
                                if !searchSource.isEmpty {
                                    Text(String(format: NSLocalizedString("来自 %@", comment: ""),
                                                searchSourceLabel))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                                    // 单集是两路拼起来的(Apple 在前、视频站在后),表头装不下两个来源,
                                    // 所以来源落在行上。判据与另两端同一条:`bilibili://` 伪地址。
                                    sourceTag: BilibiliSource.isPseudo(ep.audioUrl)
                                        ? NSLocalizedString("B 站", comment: "") : "Apple",
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

    /// 节目那一路的来源短名。仓储给的是 `Bilibili` / `Apple Podcasts` 这种内部标识,
    /// 而单集行上标的是「B 站」/「Apple」—— 同一个屏幕上两种写法会显得像两个源,这里统一收口。
    private var searchSourceLabel: String {
        if searchSource.hasPrefix("Bilibili") { return NSLocalizedString("B 站", comment: "") }
        if searchSource.hasPrefix("Apple") { return "Apple" }
        return searchSource
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        submittedQuery = q
        searching = true
        liveEpisode = nil
        // 上一轮的结果先清掉:下面直播那一支要拿「两个数组都空」当判据,
        // 留着旧数据会让它一直等到目录检索回来才肯显示。
        searchPodcasts = []
        searchEpisodes = []
        searchSource = ""
        /// 直播探针与目录检索**并行发**:粘一条电台地址时目录那边会先把它当 RSS 去拉、
        /// 一路白等到超时,串行等于让用户先干等十几秒。探针回来就先上屏,
        /// 目录若真有结果,下面那条 `searching = false` 之后它自然盖过去。
        if LiveStream.looksLikeStream(q) {
            Task {
                let live = await LiveStream.resolve(q)
                guard submittedQuery == q else { return }
                liveEpisode = live
            }
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
        // 排除集合从播放器取(radioHistory 末尾 40 条)。原先两处都写死 `exclude: []`,
        // 于是「随机」没有任何记忆 —— 与 Android `RadioStation` 传 recent 的口径不一致
        // (见 REVIEW-2026-10-25 族 E)。
        // 这里把 player 收到局部变量再进闭包:escaping 闭包里直接写 `player` 会把整个 View 的
        // self 捕获进去,而这里要的只是那一个 ObservableObject。
        let playerRef = player
        player.startRadio { await repo.randomEpisode(region: region, genreIds: genreIds,
                                                     exclude: playerRef.recentRadioIds()) }
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

/// 分类排序弹窗。
///
/// Android 的形态是「长按分类胶囊再拖动」—— 那是触屏独有的手势,桌面端没有长按。
/// 这里把同一个能力表达成两件 macOS 上本来就有的东西:**拖动行**与**行尾的上/下箭头**。
/// 箭头放在每一行上(而不是整表一颗「置顶」):它对键盘与读屏可达,拖动只能靠指针。
///
/// 两套操作都只改弹窗里的副本,点「完成」才交给调用方落盘 —— 与 Android
/// `ReorderCategoriesDialog` 的 draft 同口径:取消即全丢,不会边拖边写。
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
        VStack(alignment: .leading, spacing: 0) {
            Text("自定义分类排序").font(.headline).padding(.horizontal, 24).padding(.top, 24)
            Text("拖动行或用箭头调整顺序")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 6)
            // 用 List 而不是 ScrollView + 手搓行:`.onMove` 在 macOS 的 List 上直接
            // 提供拖动排序(本端没有 Android 那种"进入编辑模式"的一步)。
            List {
                ForEach(items) { c in
                    row(c)
                }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)
            .padding(.top, 8)
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("完成") { onDone(items) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 380, height: 480)
    }

    private func row(_ c: DiscoverCategory) -> some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(c.name))
            Spacer(minLength: 12)
            arrow("chevron.up", label: "上移", disabled: items.first?.id == c.id) {
                move(c.id, by: -1)
            }
            arrow("chevron.down", label: "下移", disabled: items.last?.id == c.id) {
                move(c.id, by: 1)
            }
        }
        .padding(.vertical, 2)
    }

    /// `.borderless`:行内有指针交互时仍然允许整行被拖动(默认按钮样式会吃掉这次拖拽),
    /// 同时也让同一行里的两颗按钮都拿得到点击。
    private func arrow(_ symbol: String, label: LocalizedStringKey, disabled: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.small)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func move(_ id: String, by delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        withAnimation(.easeOut(duration: 0.15)) { items.swapAt(i, j) }
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
