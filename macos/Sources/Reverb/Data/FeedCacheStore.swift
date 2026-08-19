import Foundation

/// 频道详情(解析后的 RSS)的磁盘缓存,按 feedUrl。
///
/// 解决两件事:
///  1. **断网可看**:此前进频道详情只能等网络,失败即空页 —— 哪怕是自己订阅、刚看过的频道。
///     现在先出缓存内容,再后台刷新。
///  2. **秒开**:详情页原本每次都从 loading 开始(RSS 动辄几百 KB)。
///
/// 容量有意收紧(RSS 是这个 App 里最大的数据):最多 maxFeeds 个频道、每个频道 maxEpisodes 集,
/// 超出按最近写入时间淘汰。整体 ~1-2MB,计入设置页缓存大小。
final class FeedCacheStore {

    /// 一条缓存:解析结果 + 落缓存时刻(用于「上次更新于」与淘汰排序)。
    struct Entry {
        let podcast: Podcast
        let episodes: [Episode]
        let fetchedAt: Date
    }

    private static let maxFeeds = 30
    private static let maxEpisodes = 60

    private let fileURL: URL
    private let lock = NSLock()
    private var mem: [String: Entry] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Reverb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("feed_cache.json")
        mem = Self.load(fileURL)
        if !mem.isEmpty { Log.i("FeedCache", "频道缓存装载 \(mem.count) 个") }
    }

    func get(_ feedUrl: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return mem[feedUrl]
    }

    /// 写入并按容量淘汰。episodes 超量时只留最前面的(RSS 本身按时间倒序)。
    func put(_ feedUrl: String, _ result: FeedResult) {
        guard !feedUrl.isEmpty, !result.episodes.isEmpty else { return }
        lock.lock()
        mem[feedUrl] = Entry(
            podcast: result.podcast,
            episodes: Array(result.episodes.prefix(Self.maxEpisodes)),
            fetchedAt: Date()
        )
        if mem.count > Self.maxFeeds {
            // 丢掉最旧的若干条
            let ordered = mem.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            for (key, _) in ordered.prefix(mem.count - Self.maxFeeds) { mem.removeValue(forKey: key) }
        }
        let snapshot = mem
        lock.unlock()
        persist(snapshot)
    }

    func clear() {
        lock.lock()
        mem = [:]
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func sizeBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    // MARK: - 持久化

    /// 磁盘表示。Podcast/Episode 已是 Codable,这里只补时间戳。
    private struct Stored: Codable {
        var fetchedAt: Date
        var podcast: Podcast
        var episodes: [Episode]
    }

    private static func load(_ url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        var out: [String: Entry] = [:]
        for (key, s) in raw where !s.episodes.isEmpty {
            out[key] = Entry(podcast: s.podcast, episodes: s.episodes, fetchedAt: s.fetchedAt)
        }
        return out
    }

    private func persist(_ snapshot: [String: Entry]) {
        var raw: [String: Stored] = [:]
        for (key, e) in snapshot {
            raw[key] = Stored(fetchedAt: e.fetchedAt, podcast: e.podcast, episodes: e.episodes)
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
