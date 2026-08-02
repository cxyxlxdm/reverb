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
        try? data.write(to: fileURL(for: key), options: .atomic)
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
