import Foundation

/// Apple iTunes Search API 数据源:频道搜索、单集搜索、批量 lookup。
final class ITunesSource {
    /// 搜索播客频道。跳过没有 feedUrl 的结果。
    func search(_ term: String, country: String = "", limit: Int = 50) async -> [Podcast] {
        var url = "https://itunes.apple.com/search?media=podcast&term=\(HTTP.encode(term))&limit=\(limit)"
        if !country.isEmpty { url += "&country=\(country)" }
        let t0 = Date()
        // 日志只记**词数**不记原文(见 REVIEW-2026-10-25 高-1):已发布的隐私政策第二节承诺
        // 「日志不记录搜索词」,而 `reverb.log` 在设置页有导出 / 分享 / 发邮箱三条离机出口。
        // 这一行原先把用户敲进去的那串字整个拼进了消息里,与同一个仓库里
        // `PodcastRepository.search` 那条正确范式自相矛盾 —— 用户搜什么,日志里就躺着什么。
        // country / limit / 命中数留着:它们不含用户输入,又正是排查要看的。
        let termWords = Log.wordCount(term)
        Log.d("iTunes", "search termWords=\(termWords) country=\(country.isEmpty ? "-" : country)")
        guard let json = await HTTP.json(url),
              let results = json["results"] as? [[String: Any]] else {
            Log.w("iTunes", "search 无结果 termWords=\(termWords) \(Log.ms(t0))")
            return []
        }
        let list = results.compactMap { parsePodcast($0) }
        Log.i("iTunes", "search termWords=\(termWords) 命中 \(list.count) 频道 \(Log.ms(t0))")
        return list
    }

    /// 搜索单集。跳过没有音频直链的结果。
    func searchEpisodes(_ term: String, country: String = "", limit: Int = 50) async -> [Episode] {
        var url = "https://itunes.apple.com/search?media=podcast&entity=podcastEpisode&term=\(HTTP.encode(term))&limit=\(limit)"
        if !country.isEmpty { url += "&country=\(country)" }
        let t0 = Date()
        // 同 `search`:只记词数(见 REVIEW-2026-10-25 高-1)。
        let termWords = Log.wordCount(term)
        Log.d("iTunes", "searchEpisodes termWords=\(termWords) country=\(country.isEmpty ? "-" : country)")
        guard let json = await HTTP.json(url),
              let results = json["results"] as? [[String: Any]] else {
            Log.w("iTunes", "searchEpisodes 无结果 termWords=\(termWords) \(Log.ms(t0))")
            return []
        }
        let episodes: [Episode] = results.compactMap { item in
            let kind = item["kind"] as? String
            let episodeUrl = item["episodeUrl"] as? String
            guard kind == "podcast-episode" || (episodeUrl?.isEmpty == false) else { return nil }
            let audioUrl = episodeUrl ?? ""
            guard !audioUrl.isEmpty else { return nil }
            let guid = item["episodeGuid"] as? String
            let art = (item["artworkUrl600"] as? String) ?? (item["artworkUrl160"] as? String) ?? ""
            let millis = intValue(item["trackTimeMillis"]) ?? 0
            return Episode(
                id: (guid?.isEmpty == false ? guid! : audioUrl),
                title: (item["trackName"] as? String) ?? "",
                description: (item["description"] as? String) ?? "",
                audioUrl: audioUrl,
                artworkUrl: art,
                podcastTitle: (item["collectionName"] as? String) ?? "",
                durationSec: millis / 1000,
                pubDate: (item["releaseDate"] as? String) ?? "",
                feedUrl: (item["feedUrl"] as? String) ?? ""
            )
        }
        Log.i("iTunes", "searchEpisodes termWords=\(termWords) 命中 \(episodes.count) 单集 \(Log.ms(t0))")
        return episodes
    }

    /// 按 collectionId 批量查询频道。空 ID 列表直接返回空。
    func lookupBatch(_ ids: [String], country: String = "") async -> [Podcast] {
        let joined = ids.filter { !$0.isEmpty }.joined(separator: ",")
        guard !joined.isEmpty else { return [] }
        var url = "https://itunes.apple.com/lookup?id=\(joined)&entity=podcast"
        if !country.isEmpty { url += "&country=\(country)" }
        let t0 = Date()
        Log.d("iTunes", "lookupBatch ids=\(ids.count) country=\(country.isEmpty ? "-" : country)")
        guard let json = await HTTP.json(url),
              let results = json["results"] as? [[String: Any]] else {
            Log.w("iTunes", "lookupBatch 无结果 ids=\(ids.count) \(Log.ms(t0))")
            return []
        }
        let list = results.compactMap { parsePodcast($0) }
        Log.i("iTunes", "lookupBatch ids=\(ids.count) → \(list.count) 频道 \(Log.ms(t0))")
        return list
    }

    // MARK: - 解析

    /// 从 iTunes 结果条目解析频道。缺 feedUrl 或非播客类型时返回 nil。
    private func parsePodcast(_ item: [String: Any]) -> Podcast? {
        // lookup 结果中夹带单集/艺人等,过滤为播客类型。
        if let wrapper = item["wrapperType"] as? String, wrapper != "track" && wrapper != "collection" {
            return nil
        }
        if let kind = item["kind"] as? String, kind != "podcast" {
            return nil
        }
        guard let feedUrl = item["feedUrl"] as? String, !feedUrl.isEmpty else { return nil }
        let collectionId = intValue(item["collectionId"])
        let price = doubleValue(item["trackPrice"]) ?? 0
        return Podcast(
            id: collectionId.map(String.init) ?? feedUrl,
            title: (item["collectionName"] as? String) ?? "",
            author: (item["artistName"] as? String) ?? "",
            artworkUrl: (item["artworkUrl600"] as? String) ?? (item["artworkUrl100"] as? String) ?? "",
            feedUrl: feedUrl,
            description: "",
            genre: (item["primaryGenreName"] as? String) ?? "",
            isPaid: price > 0
        )
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
