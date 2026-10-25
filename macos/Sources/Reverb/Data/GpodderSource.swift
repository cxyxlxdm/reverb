import Foundation

/// gpodder.net 目录搜索数据源。以订阅地址(url)作为频道 id。
final class GpodderSource {
    /// 按关键词搜索。跳过没有 url 的结果。
    func search(_ term: String) async -> [Podcast] {
        let url = "https://gpodder.net/search.json?q=\(HTTP.encode(term))"
        let t0 = Date()
        // 只记词数(见 REVIEW-2026-10-25 高-1):政策说「日志不记录搜索词」,
        // 而这三行原本把用户敲进去的那串字整个拼进了消息里,
        // 和同一个仓库里 `PodcastRepository.search` 的口径相反。
        let termWords = Log.wordCount(term)
        Log.d("gpodder", "search termWords=\(termWords)")
        guard let arr = await HTTP.jsonArray(url) else {
            Log.w("gpodder", "search 无结果 termWords=\(termWords) \(Log.ms(t0))")
            return []
        }
        let list = arr.compactMap { any -> Podcast? in
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
        Log.i("gpodder", "search termWords=\(termWords) → \(list.count) 频道 \(Log.ms(t0))")
        return list
    }
}
