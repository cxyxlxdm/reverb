import Foundation

/// 榜单结果的本地持久化:以 JSON 文件缓存到 Application Support 目录。
/// 读写均容错,失败返回空/静默忽略。
final class PopularCacheStore {
    private let dir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("Reverb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 读取缓存。无缓存或解析失败返回 []。
    func get(_ key: String) -> [Podcast] {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder.decode([Podcast].self, from: data) else { return [] }
        return list
    }

    /// 写入缓存。失败静默忽略。
    func put(_ key: String, _ list: [Podcast]) {
        guard let data = try? encoder.encode(list) else { return }
        let url = fileURL(for: key)
        try? data.write(to: url, options: .atomic)
        AppSupport.excludeFromBackup(url)
    }

    /// 「清除缓存」用:删掉本目录下全部 `popular_*.json`。返回删除的个数(供日志)。
    ///
    /// 只按**文件名前缀**匹配,不删整个 Application Support/Reverb ——
    /// 那里还躺着订阅、历史、下载账本与日志,清缓存不能碰它们。
    @discardableResult
    func clear() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for n in names where n.hasPrefix("popular_") && n.hasSuffix(".json") {
            if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// 榜单缓存的磁盘占用(字节)。设置页把它算进缓存总量。
    func sizeBytes() -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        for n in names where n.hasPrefix("popular_") && n.hasSuffix(".json") {
            let p = dir.appendingPathComponent(n).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: - 私有

    private func fileURL(for key: String) -> URL {
        dir.appendingPathComponent("popular_\(sanitize(key)).json")
    }

    /// 将 key 清洗为安全文件名。
    private func sanitize(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let s = String(mapped)
        return s.isEmpty ? "default" : s
    }
}
