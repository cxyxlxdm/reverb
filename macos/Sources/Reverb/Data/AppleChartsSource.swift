import Foundation

/// Apple 排行榜数据源:榜单只给 id,再经由 iTunes lookup 补全频道详情。
final class AppleChartsSource {
    private let itunes: ITunesSource

    init(itunes: ITunesSource) {
        self.itunes = itunes
    }

    /// 综合热门榜:marketingtools 榜单 → id 列表 → lookup。
    func top(region: String = "cn", limit: Int = 30) async -> [Podcast] {
        let url = "https://rss.marketingtools.apple.com/api/v2/\(region)/podcasts/top/\(limit)/podcasts.json"
        guard let json = await HTTP.json(url),
              let feed = json["feed"] as? [String: Any],
              let results = feed["results"] as? [[String: Any]] else { return [] }
        let ids = results.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return [] }
        return await itunes.lookupBatch(ids, country: region)
    }

    /// 分类热门榜:老版 rss toppodcasts 接口 → im:id → lookup。
    func topByGenre(region: String = "cn", genreId: Int, limit: Int = 30) async -> [Podcast] {
        let url = "https://itunes.apple.com/\(region)/rss/toppodcasts/limit=\(limit)/genre=\(genreId)/json"
        guard let json = await HTTP.json(url),
              let feed = json["feed"] as? [String: Any] else { return [] }

        // entry 可能是数组,也可能是单个对象(仅一条时)。
        let entries: [[String: Any]]
        if let arr = feed["entry"] as? [[String: Any]] {
            entries = arr
        } else if let single = feed["entry"] as? [String: Any] {
            entries = [single]
        } else {
            entries = []
        }

        let ids = entries.compactMap { entry -> String? in
            guard let idObj = entry["id"] as? [String: Any],
                  let attrs = idObj["attributes"] as? [String: Any],
                  let imId = attrs["im:id"] as? String else { return nil }
            return imId
        }
        guard !ids.isEmpty else { return [] }
        return await itunes.lookupBatch(ids, country: region)
    }
}
