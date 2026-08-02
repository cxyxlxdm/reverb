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

    init() {
        charts = AppleChartsSource(itunes: itunes)
    }

    // MARK: - 搜索

    /// 搜索频道。URL 直接走 RSS 导入;否则依次尝试 Apple / fyyd / gpodder,取首个非空。
    /// 返回结果列表与来源名。
    func search(_ query: String, region: String = "") async -> (podcasts: [Podcast], source: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], "") }

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

    /// 读取本地缓存的榜单。
    func cachedPopular(genreId: Int?, region: String) -> [Podcast] {
        cache.get(cacheKey(genreId, region))
    }

    /// 拉取并刷新榜单。综合榜为空时依次回退到 us 综合榜、fyyd 热门。非空即写入缓存。
    func refreshPopular(genreId: Int?, region: String) async -> [Podcast] {
        var list: [Podcast]
        if let genreId = genreId {
            list = await charts.topByGenre(region: region, genreId: genreId, limit: 30)
        } else {
            list = await charts.top(region: region, limit: 30)
        }

        if list.isEmpty && genreId == nil {
            list = await charts.top(region: "us", limit: 30)
            if list.isEmpty {
                list = await fyyd.hot(30)
            }
        }

        if !list.isEmpty {
            cache.put(cacheKey(genreId, region), list)
        }
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
        // 组池:遍历各分类的缓存榜单,按 feedUrl 去重。
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

        guard !pool.isEmpty else { return nil }

        // 过滤付费频道;若全部付费则保留原池。
        let free = pool.filter { !$0.isPaid }
        let candidates = free.isEmpty ? pool : free

        let picks = candidates.shuffled().prefix(6)
        for podcast in picks {
            guard let result = await feed(podcast.feedUrl) else { continue }
            let playable = result.episodes.filter { !$0.audioUrl.isEmpty && !exclude.contains($0.id) }
            if let chosen = playable.randomElement() {
                return chosen
            }
        }
        return nil
    }
}
