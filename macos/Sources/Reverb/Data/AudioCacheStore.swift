import Foundation

/// 一条「播过即缓存」的账目。`fileName` 相对缓存目录(见 `AudioCacheManager`)。
///
/// 与 `DownloadedEpisode` 是**两份独立的账**,这是刻意的:
///  - 下载 = 用户**点名**要留的,永久有效、进备份、由「清空下载」负责;
///  - 缓存 = App **自己**为「下次别联网」攒的,可被预算挤掉、**不进备份**、由「清除缓存」负责。
/// 两者的目录也不同(`Downloads/` 与 `audio_cache/`),任何一侧的清理都不可能误删另一侧的文件。
///
/// 只存 id / url / 文件名 / 字节数,**不整份抄 `Episode`**:这条账唯一要回答的是
/// 「这一集的音频在不在本地、在哪个文件」,起播时元数据本来就来自列表(列表另有频道缓存)。
///
/// 记的是**文件名而不是绝对路径**:路径随 Application Support 的落点变,
/// 存相对名让账本与目录能一起搬。
struct AudioCacheEntry: Codable, Equatable {
    var episodeId: String
    var audioUrl: String
    var fileName: String
    var bytes: Int64
    /// 落缓存时刻(毫秒)。只用于日志与排查,淘汰看的是 `lastAccess`。
    var cachedAt: Int64
    /// 最后一次**从缓存起播**的时刻(毫秒)。LRU 的唯一依据。
    var lastAccess: Int64
}

/// `audio_cache.json` 的读写。线程安全:起播在主线程调,下载收尾在后台任务里调。
///
/// **带版本号**(硬规矩 11):账本口径以后会变。旧账在新版本里照样能解析成功、只是每条
/// 都指不到文件 —— 界面上就是「缓存莫名其妙空了」,而用户没有自救入口。版本不符时整体作废,
/// 不猜;留下的孤儿文件由 `AudioCacheManager.reconcile()` 扫掉。
final class AudioCacheStore {
    /// 缓存目录名。**与 Android `AudioCacheStore.DIR_NAME` / 鸿蒙同值**,便于三端对照排查。
    static let dirName = "audio_cache"

    private static let fileName = "audio_cache.json"
    private static let version = 1
    private static let category = "AudioCache"

    private let fileURL: URL
    private let lock = NSLock()
    private var mem: [String: AudioCacheEntry]

    init() {
        fileURL = AppSupport.dir.appendingPathComponent(Self.fileName)
        AppSupport.excludeFromBackup(fileURL)
        mem = Self.load(fileURL)
        if !mem.isEmpty { Log.i(Self.category, "cache ledger loaded items=\(mem.count)") }
    }

    private struct Stored: Codable {
        let v: Int
        let items: [AudioCacheEntry]
    }

    func get(_ episodeId: String) -> AudioCacheEntry? {
        lock.lock(); defer { lock.unlock() }
        return mem[episodeId]
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return mem.count
    }

    func all() -> [AudioCacheEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(mem.values)
    }

    /// 当前账目的拷贝,按最后一次访问**升序**(淘汰从头部开始)。
    func byLeastRecent() -> [AudioCacheEntry] {
        lock.lock(); defer { lock.unlock() }
        return mem.values.sorted { $0.lastAccess < $1.lastAccess }
    }

    /// 文件名 → episodeId。`reconcile` 用它判断目录里某个文件有没有人认领。
    func fileNameToId() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: String] = [:]
        for (id, e) in mem { out[e.fileName] = id }
        return out
    }

    /// 落一条新账(同一集重复落时覆盖旧记录,访问时间重置到现在)。
    func put(_ item: AudioCacheEntry) {
        lock.lock(); defer { lock.unlock() }
        mem[item.episodeId] = item
        persist()
    }

    /// 记一次「这一集真的从缓存里起播了」。
    ///
    /// 单独存在是因为 **LRU 的那个 L 全靠它**:淘汰只看 `lastAccess`,而「用过」只发生在起播那一刻。
    /// 只在写入时更新的话,一条反复听的集会因 `cachedAt` 太旧而被优先挤掉,预算就白设了。
    func touch(_ episodeId: String) {
        lock.lock(); defer { lock.unlock() }
        guard var item = mem[episodeId] else { return }
        item.lastAccess = Self.nowMs()
        mem[episodeId] = item
        persist()
    }

    /// 删账并返回待删的文件名(账与文件必须一起处理,否则孤儿文件清不掉)。
    @discardableResult
    func remove(_ episodeId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let gone = mem.removeValue(forKey: episodeId) else { return nil }
        persist()
        return gone.fileName
    }

    /// 清空账本并返回所有待删的文件名。**先作废账、再让调用方删文件** ——
    /// 反过来的话,在途下载会在目录清空后把文件 rename 回来,设置页的数字当场又变非 0。
    func clearAll() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let names = mem.values.map { $0.fileName }
        mem.removeAll()
        persist()
        return names
    }

    /// 落盘走 `AppSupport.save`(去抖 + 后台编码/写盘)。快照在**持锁时**取,
    /// 保证多次 `put` 的落盘顺序与内存一致 —— 否则后写的那次可能被先写的旧快照覆盖。
    private func persist() {
        AppSupport.save(Self.fileName, Stored(v: Self.version, items: Array(mem.values)))
    }

    private static func load(_ url: URL) -> [String: AudioCacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Stored.self, from: data) else { return [:] }
        guard raw.v == version else {
            Log.w("AudioCache", "cache ledger v=\(raw.v) != \(version), discard")
            return [:]
        }
        var out: [String: AudioCacheEntry] = [:]
        for e in raw.items where !e.episodeId.isEmpty && !e.fileName.isEmpty {
            out[e.episodeId] = e
        }
        return out
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
