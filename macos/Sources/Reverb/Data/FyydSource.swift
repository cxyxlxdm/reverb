import Foundation

/// fyyd.de 播客搜索引擎数据源。以 RSS 地址(xmlURL)作为频道 id。
final class FyydSource {
    /// 按标题搜索。跳过没有 xmlURL 的结果。
    func search(_ term: String) async -> [Podcast] {
        let url = "https://api.fyyd.de/0.2/search/podcast?title=\(HTTP.encode(term))"
        return await fetchList(url)
    }

    /// 热门推荐。
    func hot(_ limit: Int = 30) async -> [Podcast] {
        let url = "https://api.fyyd.de/0.2/feature/podcast/hot?count=\(limit)"
        return await fetchList(url)
    }

    private func fetchList(_ url: String) async -> [Podcast] {
        guard let json = await HTTP.json(url),
              let data = json["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { item in
            guard let xmlURL = item["xmlURL"] as? String, !xmlURL.isEmpty else { return nil }
            return Podcast(
                id: xmlURL,
                title: (item["title"] as? String) ?? "",
                author: (item["author"] as? String) ?? "",
                artworkUrl: (item["imgURL"] as? String) ?? "",
                feedUrl: xmlURL
            )
        }
    }
}
