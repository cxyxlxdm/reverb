import Foundation

/// 播客数据仓库:聚合各数据源,提供搜索、榜单、订阅源解析与随机一集。
/// 镜像 Android 版行为。标记 @MainActor 便于 SwiftUI 直接调用。
@MainActor
final class PodcastRepository {
    private let itunes = ITunesSource()
    private let charts: AppleChartsSource
    private let fyyd = FyydSource()
    private let gpodder = GpodderSource()
    private let rss = RssParser()
    private let cache = PopularCacheStore()
    // 随包内置的精选清单:缓存为空(首启/清缓存/无网)时给发现页兜底,避免首屏空白
    private let seed = SeedCatalog()

    init() {
        charts = AppleChartsSource(itunes: itunes)
    }

    // MARK: - 搜索

    /// 搜索频道。URL 直接走 RSS 导入;否则依次尝试 Apple / fyyd / gpodder,取首个非空。
    /// 返回结果列表与来源名。
    func search(_ query: String, region: String = "") async -> (podcasts: [Podcast], source: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], "") }

        Log.i("Repo", "search \"\(q)\" region=\(region.isEmpty ? "-" : region)")
        if q.hasPrefix("http://") || q.hasPrefix("https://") {
            if let result = await rss.fetch(q) {
                return ([result.podcast], "RSS")
            }
            return ([], "")
        }

        let apple = await itunes.search(q, country: region)
        if !apple.isEmpty { return (apple, "Apple Podcasts") }

        let fy = await fyyd.search(q)
        if !fy.isEmpty { return (fy, "fyyd.de") }

        let gp = await gpodder.search(q)
        if !gp.isEmpty { return (gp, "gpodder.net") }

        Log.w("Repo", "search \"\(q)\" 所有数据源均无结果")
        return ([], "")
    }

    /// 搜索单集。空查询或 URL 直接返回空。
    func searchEpisodes(_ query: String, region: String = "") async -> [Episode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if q.hasPrefix("http://") || q.hasPrefix("https://") { return [] }
        return await itunes.searchEpisodes(q, country: region)
    }

    // MARK: - 榜单缓存

    /// 榜单缓存 key。
    func cacheKey(_ genreId: Int?, _ region: String) -> String {
        "\(region):\(genreId.map(String.init) ?? "default")"
    }

    /// 立即返回可展示的榜单。优先真实缓存;缓存为空(首启/清过缓存/一直无网)则回退到随包
    /// 内置清单,保证首屏不空。种子**只读不写缓存**,联网刷新成功即被真数据取代。
    func cachedPopular(genreId: Int?, region: String) -> [Podcast] {
        let real = cache.get(cacheKey(genreId, region))
        if !real.isEmpty { return real }
        return seed.get(genreId: genreId, region: region)
    }

    /// 当前展示的是内置清单(而非联网取回的真榜单)——UI 据此把标题标成「内置精选」。
    func isSeedList(genreId: Int?, region: String) -> Bool {
        cache.get(cacheKey(genreId, region)).isEmpty && !seed.get(genreId: genreId, region: region).isEmpty
    }

    /// 内置清单的生成日期(yyyy-MM-dd)。
    func seedGeneratedAt() -> String { seed.generatedAt() }

    /// 拉取并刷新榜单。综合榜为空时依次回退到 us 综合榜、fyyd 热门。非空即写入缓存。
    func refreshPopular(genreId: Int?, region: String) async -> [Podcast] {
        let t0 = Date()
        Log.i("Repo", "refreshPopular region=\(region) genre=\(genreId.map(String.init) ?? "综合")")
        var list: [Podcast]
        if let genreId = genreId {
            list = await charts.topByGenre(region: region, genreId: genreId, limit: 30)
        } else {
            list = await charts.top(region: region, limit: 30)
        }

        if list.isEmpty && genreId == nil {
            Log.w("Repo", "refreshPopular region=\(region) 综合榜为空,回退 us 综合榜")
            list = await charts.top(region: "us", limit: 30)
            if list.isEmpty {
                Log.w("Repo", "refreshPopular us 综合榜仍为空,回退 fyyd 热门")
                list = await fyyd.hot(30)
            }
        }

        if !list.isEmpty {
            cache.put(cacheKey(genreId, region), list)
        }
        Log.i("Repo", "refreshPopular region=\(region) genre=\(genreId.map(String.init) ?? "综合") → \(list.count) 频道 \(Log.ms(t0))")
        return list
    }

    // MARK: - 订阅源

    /// 解析订阅源。
    func feed(_ feedUrl: String) async -> FeedResult? {
        await rss.fetch(feedUrl)
    }

    // MARK: - 随机一集

    /// 从各分类的热门频道里随机抽取一集可播放的内容。
    /// exclude 中的 episode id 会被排除。抽不到时返回 nil。
    func randomEpisode(region: String, genreIds: [Int?], exclude: Set<String> = []) async -> Episode? {
        // 组池:遍历各分类榜单,按 feedUrl 去重。cachedPopular 在缓存为空时给出内置清单,
        // 所以首次启动点「随机」也能直接组出池子,省掉一次榜单往返。
        var pool: [Podcast] = []
        var seenFeeds = Set<String>()
        for genreId in genreIds {
            for p in cachedPopular(genreId: genreId, region: region) where !p.feedUrl.isEmpty {
                if seenFeeds.insert(p.feedUrl).inserted { pool.append(p) }
            }
        }

        // 池不足时补充综合榜。
        if pool.count < 10 {
            for p in await refreshPopular(genreId: nil, region: region) where !p.feedUrl.isEmpty {
                if seenFeeds.insert(p.feedUrl).inserted { pool.append(p) }
            }
        }

        guard !pool.isEmpty else {
            Log.w("Radio", "randomEpisode region=\(region) 频道池为空")
            return nil
        }

        // 过滤付费频道;若全部付费则保留原池。
        let free = pool.filter { !$0.isPaid }
        let candidates = free.isEmpty ? pool : free

        Log.i("Radio", "randomEpisode region=\(region) 池=\(pool.count) 候选=\(candidates.count) 排除=\(exclude.count)")
        let picks = candidates.shuffled().prefix(6)
        for podcast in picks {
            guard let result = await feed(podcast.feedUrl) else { continue }
            let playable = result.episodes.filter { !$0.audioUrl.isEmpty && !exclude.contains($0.id) }
            if let chosen = playable.randomElement() {
                Log.i("Radio", "randomEpisode 选中 频道=\"\(podcast.title)\" 单集=\"\(chosen.title)\" id=\(chosen.id)")
                return chosen
            }
        }
        Log.w("Radio", "randomEpisode region=\(region) 无可播放单集")
        return nil
    }
}
