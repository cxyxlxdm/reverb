import Foundation

/// gpodder.net 目录搜索数据源。以订阅地址(url)作为频道 id。
final class GpodderSource {
    /// 按关键词搜索。跳过没有 url 的结果。
    func search(_ term: String) async -> [Podcast] {
        let url = "https://gpodder.net/search.json?q=\(HTTP.encode(term))"
        guard let arr = await HTTP.jsonArray(url) else { return [] }
        return arr.compactMap { any in
            guard let item = any as? [String: Any],
                  let feedUrl = item["url"] as? String, !feedUrl.isEmpty else { return nil }
            return Podcast(
                id: feedUrl,
                title: (item["title"] as? String) ?? "",
                author: (item["author"] as? String) ?? "",
                artworkUrl: (item["logo_url"] as? String) ?? "",
                feedUrl: feedUrl
            )
        }
    }
}
