import Foundation

/// fyyd.de 播客搜索引擎数据源。以 RSS 地址(xmlURL)作为频道 id。
final class FyydSource {
    /// 按标题搜索。跳过没有 xmlURL 的结果。
    func search(_ term: String) async -> [Podcast] {
        let url = "https://api.fyyd.de/0.2/search/podcast?title=\(HTTP.encode(term))"
        // kind 会在 `fetchList` 的三行日志里被展开,所以这里也必须只写词数
        // (见 REVIEW-2026-10-25 高-1 / 政策「日志不记录搜索词」)。
        return await fetchList(url, kind: "search termWords=\(Log.wordCount(term))")
    }

    /// 热门推荐。
    func hot(_ limit: Int = 30) async -> [Podcast] {
        let url = "https://api.fyyd.de/0.2/feature/podcast/hot?count=\(limit)"
        return await fetchList(url, kind: "hot limit=\(limit)")
    }

    private func fetchList(_ url: String, kind: String) async -> [Podcast] {
        let t0 = Date()
        Log.d("fyyd", kind)
        guard let json = await HTTP.json(url),
              let data = json["data"] as? [[String: Any]] else {
            Log.w("fyyd", "\(kind) 无结果 \(Log.ms(t0))")
            return []
        }
        let list = data.compactMap { item -> Podcast? in
            guard let xmlURL = item["xmlURL"] as? String, !xmlURL.isEmpty else { return nil }
            return Podcast(
                id: xmlURL,
                title: (item["title"] as? String) ?? "",
                author: (item["author"] as? String) ?? "",
                artworkUrl: (item["imgURL"] as? String) ?? "",
                feedUrl: xmlURL
            )
        }
        Log.i("fyyd", "\(kind) → \(list.count) 频道 \(Log.ms(t0))")
        return list
    }
}
