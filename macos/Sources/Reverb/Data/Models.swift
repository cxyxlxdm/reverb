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

/// 一条听觉批注:**某一集的某一秒 + 自己写的一句话**。
///
/// 落盘格式与 Android `EpisodeNote` / 鸿蒙 `EpisodeNote` 逐字同构(三端共用同一份 `notes.json`):
/// `{noteId, positionMs, text, createdAt, episode:{…整条快照}}`。两条口径都不是随手定的:
/// ① **自有 id 叫 `noteId` 而不是 `id`** —— 内嵌的 `episode` 体里已经有一个 `id`(= guid,
///    全仓按它查历史进度与下载状态)。摊平在同一个对象里时后写的键会静默盖掉先写的,
///    读回来还看不出写坏了(见 H127)。
/// ② **存整条快照而不是 `episodeId` 引用** —— 零后端、无云同步,发布方从 RSS 删了旧集就无处找回,
///    引用式存储的"点回那一秒"会永久失效且用户没有自救入口。
struct EpisodeNote: Codable, Identifiable, Hashable {
    var noteId: String
    var episode: Episode
    /// 那一秒,毫秒(字段名带单位是刻意的,见 H86)
    var positionMs: Int
    var text: String
    /// 落笔时刻,毫秒。**跟本端 Stamp / HistoryEntry 的「秒」口径不一致是有意为之**:
    /// 这一份文件三端共用、时间线按它排序,而三端写入点实测都是毫秒
    /// (Android `System.currentTimeMillis()`、鸿蒙 `Date.now()`、此处 `timeIntervalSince1970 * 1000`)。
    /// **不做秒/毫秒归一**:没有任何一端写秒,加了只会把真正的单位 bug 悄悄吃掉 ——
    /// 真要改口径,按硬规矩 11 加版本号让旧数据作废,而不是在解码侧兜住。
    var createdAt: Int
    var id: String { noteId }

    enum CodingKeys: String, CodingKey { case noteId, episode, positionMs, text, createdAt }

    init(noteId: String, episode: Episode, positionMs: Int, text: String, createdAt: Int) {
        self.noteId = noteId; self.episode = episode
        self.positionMs = positionMs; self.text = text; self.createdAt = createdAt
    }
}

// 自定义解码必须放在 extension:写在类型体内会**吞掉成员初始化器**(同 HistoryEntry,H86)。
extension EpisodeNote {
    /// 逐键 `decodeIfPresent`:备份 JSON 是跨端边界,任何一个非可选键缺失都会让
    /// **整份** notes 解码失败、恢复静默无效(H86 就是这个坑)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episode = (try? c.decode(Episode.self, forKey: .episode))
            ?? Episode(id: "", title: "", description: "", audioUrl: "", artworkUrl: "", podcastTitle: "")
        positionMs = (try? c.decode(Int.self, forKey: .positionMs)) ?? 0
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        let ts = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
        createdAt = ts
        // noteId 缺失时给一个确定性的兜底,而不是留空串 ——
        // 空 id 让"删除哪一条"无从分辨,列表里就会有一条删不掉的记录。
        let raw = (try? c.decode(String.self, forKey: .noteId)) ?? ""
        noteId = raw.isEmpty ? "legacy-\(ts)" : raw
    }
}
