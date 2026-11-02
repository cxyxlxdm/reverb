import Foundation

/// 频道详情(解析后的 RSS)的磁盘缓存,按 feedUrl。
///
/// 解决两件事:
///  1. **断网可看**:此前进频道详情只能等网络,失败即空页 —— 哪怕是自己订阅、刚看过的频道。
///     现在先出缓存内容,再后台刷新。
///  2. **秒开**:详情页原本每次都从 loading 开始(RSS 动辄几百 KB)。
///
/// 容量有意收紧(RSS 是这个 App 里最大的数据):最多 maxFeeds 个频道、每个频道 maxEpisodes 集,
/// 超出按最近写入时间淘汰。整体 ~1-2MB。
/// (两个入口 `sizeBytes()` / `clear()` 现由设置页「清除缓存」调用,见 `PodcastRepository.cacheSizeBytes()`。)
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
    private static let fileName = "feed_cache.json"
    private let lock = NSLock()
    private var mem: [String: Entry] = [:]

    /// 读是自己拼路径、**写走 `AppSupport.save(文件名)`** ⇒ 两边必须同源,否则会变成
    /// "从一个目录读、往另一个目录写" —— 缓存永远读不回来,症状是"每次进详情页都从零拉 RSS"。
    /// 这里原先自建了一套目录(还带一条 `applicationSupportDirectory` 取不到就回落临时目录的兜底),
    /// 而那条兜底恰恰就是分叉的来源:`AppSupport` 从不回落到临时目录。
    /// 现在路径以 `AppSupport.dir` 为唯一真相,不再自建。
    init() {
        fileURL = AppSupport.dir.appendingPathComponent(Self.fileName)
        AppSupport.excludeFromBackup(fileURL)
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

    /// 清空。**走同一条写盘通道,而不是直接删文件。**
    ///
    /// 为什么:`AppSupport.save` 是去抖的 —— 此刻 pending 里很可能还挂着一次
    /// 「把清空前的整份快照写回去」的任务。直接 `removeItem` 的话,0.4 秒后那份
    /// 旧快照照样落盘,文件原地复活:内存里清了、盘上还有 1-2 MB,下次启动又全装载回来,
    /// 等于这次清空只生效到进程结束。写一份空字典进同一条通道,天然覆盖那份待写的旧快照。
    func clear() {
        lock.lock()
        mem = [:]
        lock.unlock()
        AppSupport.save(Self.fileName, [String: Stored]())
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

    /// `Entry → Stored` 这一步是廉价的(数组是 CoW,只拷引用),留在调用方;
    /// **编码 + 写盘交给 `AppSupport.save`** —— 那是去抖 + 后台队列的通道。
    ///
    /// 为什么必须走它:一次「刷新最新」是逐源并发回来的,15 个源就是 15 次 `put`,
    /// 而这份缓存整体 ~1-2 MB。原先 15 次都在主线程上各编一遍整份 JSON 再原子写盘,
    /// 每次 `put` 还都真跑一次(没有去抖)。与鸿蒙那一轮同一个道理(TROUBLESHOOTING H65):
    /// **去抖要连"生成数据"一起去抖** —— 只把写盘挪走、编码还留在主线程等于没解决。
    /// 现在 15 次调用只落最后一份,且编码也不在主线程。
    ///
    /// **代价**:退出时窗口内的最后一次写入可能丢 —— `AppSupport.flushPending()`
    /// 已在 `ReverbApp` 的 willTerminate 钩子里兜住(其他 store 走的同一通道)。
    private func persist(_ snapshot: [String: Entry]) {
        var raw: [String: Stored] = [:]
        for (key, e) in snapshot {
            raw[key] = Stored(fetchedAt: e.fetchedAt, podcast: e.podcast, episodes: e.episodes)
        }
        AppSupport.save(Self.fileName, raw)
    }
}
