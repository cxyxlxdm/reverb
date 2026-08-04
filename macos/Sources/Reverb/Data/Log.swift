import Foundation

/// 全局日志设施:带时间戳/级别/分类,持久化到文件并镜像到控制台。
///
/// - 线程安全:所有写入落在私有串行队列,永不阻塞主线程。
/// - 文件位置:`~/Library/Application Support/Reverb/Logs/reverb.log`。
/// - 轮转:单文件超过约 1.5MB 时,移动为 `reverb.1.log`(仅保留一份历史),再从空文件重新写。
/// - 任意文件 IO 均以 `try?` 包裹,失败静默,绝不崩溃。
/// - 本类型可从任意线程调用,不做 @MainActor 隔离。
enum Log {
    /// 日志级别。
    enum Level: String {
        case debug = "D"
        case info = "I"
        case warn = "W"
        case error = "E"
    }

    // MARK: - 配置

    /// 单文件字节上限,超过即轮转。
    private static let maxBytes: Int = 1_500_000

    /// 串行写入队列。
    private static let queue = DispatchQueue(label: "com.yuyin.reverb.log")

    /// 日志目录:Application Support/Reverb/Logs。
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let d = base.appendingPathComponent("Reverb/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 当前日志文件。
    static let currentFileURL: URL = dir.appendingPathComponent("reverb.log")

    /// 上一份轮转日志文件。
    private static let previousFileURL: URL = dir.appendingPathComponent("reverb.1.log")

    /// 固定 en_US_POSIX 格式器,输出如 `2026-08-04 10:00:00.123`。
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    // MARK: - 公开 API

    static func d(_ category: String, _ message: String) { write(.debug, category, message, nil) }
    static func i(_ category: String, _ message: String) { write(.info, category, message, nil) }
    static func w(_ category: String, _ message: String) { write(.warn, category, message, nil) }
    static func e(_ category: String, _ message: String, error: Error? = nil) { write(.error, category, message, error) }

    /// 将起始时间格式化为耗时标记,如 `(123ms)`,便于统一标注网络/耗时操作。
    static func ms(_ start: Date) -> String {
        "(\(Int(Date().timeIntervalSince(start) * 1000))ms)"
    }

    /// 拼接的完整日志文本(历史 + 当前),供导出/分享。
    static func allText() -> String {
        queue.sync {
            let prev = (try? String(contentsOf: previousFileURL, encoding: .utf8)) ?? ""
            let cur = (try? String(contentsOf: currentFileURL, encoding: .utf8)) ?? ""
            return prev + cur
        }
    }

    /// 当前日志文件大小(字节),历史 + 当前之和。
    static func totalSizeBytes() -> Int {
        queue.sync {
            func size(_ url: URL) -> Int {
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            return size(previousFileURL) + size(currentFileURL)
        }
    }

    /// 清空全部日志(历史 + 当前)。
    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: previousFileURL)
            try? Data().write(to: currentFileURL, options: .atomic)
        }
    }

    // MARK: - 内部

    private static func write(_ level: Level, _ category: String, _ message: String, _ error: Error?) {
        let ts = formatter.string(from: Date())
        var line = "\(ts) [\(level.rawValue)] [\(category)] \(message)\n"
        if let error {
            line += "    ↳ \(String(describing: error))\n"
        }
        // 控制台镜像(便于开发期实时观察)。
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            rotateIfNeeded()
            append(line)
        }
    }

    /// 追加一行到当前文件(队列内调用)。
    private static func append(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: currentFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 文件尚不存在,直接创建。
            try? data.write(to: currentFileURL, options: .atomic)
        }
    }

    /// 超限则轮转(队列内调用)。
    private static func rotateIfNeeded() {
        let size = (try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= maxBytes else { return }
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: currentFileURL, to: previousFileURL)
        try? Data().write(to: currentFileURL, options: .atomic)
    }
}
