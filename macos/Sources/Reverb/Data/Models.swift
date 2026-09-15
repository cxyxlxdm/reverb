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
    var feedUrl: String = ""   // 所属频道的 RSS 地址,用于从播放页跳转频道主页
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
    var played: Bool = false  // 是否已播完(自然播放到结尾,或手动标记)
    var id: String { episode.id }

    enum CodingKeys: String, CodingKey { case episode, positionMs, durationMs, updatedAt, played }
}

// 自定义解码必须放在 extension:写在类型体内会**吞掉成员初始化器**,
// 而 Stores.record() 等处仍在用 `HistoryEntry(episode:…:)` 逐参构造(H86)。
extension HistoryEntry {
    /// 见 H86:
    /// ① Swift 合成解码里「有默认值」不等于「键可缺省」,Android 旧版导出的历史
    ///    没有 played 键,曾让整份备份解码失败、恢复静默无效 —— 这里逐键 decodeIfPresent;
    /// ② Android 备份的 updatedAt 是毫秒,本端口径是秒,在此统一归一(阈值 1e11,
    ///    毫秒级时间戳远大于它,而秒级时间戳到 5138 年都够不着)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episode = try c.decode(Episode.self, forKey: .episode)
        positionMs = (try? c.decode(Int.self, forKey: .positionMs)) ?? 0
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
        var ts = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        if ts > 100_000_000_000 { ts /= 1000 }
        updatedAt = ts
        played = (try? c.decode(Bool.self, forKey: .played)) ?? false
    }
}

/// 单个频道的累计收听时长(累计"实际播放过的内容毫秒")。
/// key 为频道键:feedUrl 非空时用它,否则回退频道名。
///
/// 时长**按设备分账**存放于 perDevice(设备ID → 毫秒),展示值为各设备之和。
/// 这样备份恢复的合并规则可取「按设备取 max」而非相加,重复恢复同一份备份不会重复统计
/// (等价于 G-Counter CRDT);跨设备恢复则天然把两台的时长加总。
struct ChannelListen: Codable, Identifiable, Hashable {
    var key: String
    var title: String
    var artworkUrl: String
    var feedUrl: String
    var perDevice: [String: Int] = [:]
    var id: String { key }

    /// 展示用总时长 = 各设备之和。
    var listenedMs: Int { perDevice.values.reduce(0, +) }

    enum CodingKeys: String, CodingKey { case key, title, artworkUrl, feedUrl, perDevice, listenedMs }

    init(key: String, title: String, artworkUrl: String, feedUrl: String, perDevice: [String: Int] = [:]) {
        self.key = key; self.title = title; self.artworkUrl = artworkUrl
        self.feedUrl = feedUrl; self.perDevice = perDevice
    }

    /// 兼容旧格式:无 perDevice 时,把扁平的 listenedMs 归入 legacyFlatMs,由 store 迁移到本机名下。
    var legacyFlatMs: Int = 0

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        artworkUrl = (try? c.decode(String.self, forKey: .artworkUrl)) ?? ""
        feedUrl = (try? c.decode(String.self, forKey: .feedUrl)) ?? ""
        if let pd = try? c.decode([String: Int].self, forKey: .perDevice), !pd.isEmpty {
            perDevice = pd
        } else {
            perDevice = [:]
            legacyFlatMs = (try? c.decode(Int.self, forKey: .listenedMs)) ?? 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(title, forKey: .title)
        try c.encode(artworkUrl, forKey: .artworkUrl)
        try c.encode(feedUrl, forKey: .feedUrl)
        try c.encode(perDevice, forKey: .perDevice)
        try c.encode(listenedMs, forKey: .listenedMs)   // 便于人读/旧版本兼容读取
    }
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
