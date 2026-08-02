import Foundation

/// Apple iTunes Search API 数据源:频道搜索、单集搜索、批量 lookup。
final class ITunesSource {
    /// 搜索播客频道。跳过没有 feedUrl 的结果。
    func search(_ term: String, country: String = "", limit: Int = 50) async -> [Podcast] {
        var url = "https://itunes.apple.com/search?media=podcast&term=\(HTTP.encode(term))&limit=\(limit)"
        if !country.isEmpty { url += "&country=\(country)" }
        guard let json = await HTTP.json(url),
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { parsePodcast($0) }
    }

    /// 搜索单集。跳过没有音频直链的结果。
    func searchEpisodes(_ term: String, country: String = "", limit: Int = 50) async -> [Episode] {
        var url = "https://itunes.apple.com/search?media=podcast&entity=podcastEpisode&term=\(HTTP.encode(term))&limit=\(limit)"
        if !country.isEmpty { url += "&country=\(country)" }
        guard let json = await HTTP.json(url),
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
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
                pubDate: (item["releaseDate"] as? String) ?? ""
            )
        }
    }

    /// 按 collectionId 批量查询频道。空 ID 列表直接返回空。
    func lookupBatch(_ ids: [String], country: String = "") async -> [Podcast] {
        let joined = ids.filter { !$0.isEmpty }.joined(separator: ",")
        guard !joined.isEmpty else { return [] }
        var url = "https://itunes.apple.com/lookup?id=\(joined)&entity=podcast"
        if !country.isEmpty { url += "&country=\(country)" }
        guard let json = await HTTP.json(url),
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { parsePodcast($0) }
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
