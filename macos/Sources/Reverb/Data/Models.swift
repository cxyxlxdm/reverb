import Foundation

/// 一档播客节目(频道)。
struct Podcast: Codable, Identifiable, Hashable {
    var id: String            // Apple collectionId,或 feedUrl(RSS 直接导入时)
    var title: String
    var author: String
    var artworkUrl: String
    var feedUrl: String
    var description: String = ""
    var genre: String = ""
    var isPaid: Bool = false
    var fundingUrl: String = ""
    var fundingLabel: String = ""
}

/// 播客中的一集。audioUrl 为 RSS enclosure 中发布方的原始直链。
struct Episode: Codable, Identifiable, Hashable {
    var id: String            // guid,缺失时回退为 audioUrl
    var title: String
    var description: String
    var audioUrl: String
    var artworkUrl: String
    var podcastTitle: String
    var durationSec: Int = 0
    var pubDate: String = ""
}

/// 解析 RSS 后的结果:频道元信息 + 分集列表。
struct FeedResult {
    var podcast: Podcast
    var episodes: [Episode]
}

/// 播放历史一条。
struct HistoryEntry: Codable, Identifiable, Hashable {
    var episode: Episode
    var positionMs: Int
    var durationMs: Int
    var updatedAt: Double     // 时间戳(秒)
    var id: String { episode.id }
}

/// 一枚听觉印记。
struct Stamp: Codable, Identifiable, Hashable {
    var episodeId: String
    var seal: String
    var title: String
    var podcastTitle: String
    var createdAt: Double
    var id: String { episodeId }
}
