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
        AppSupport.excludeFromBackup(d)
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

    /// 搜索词的**词数**,不是原文。
    ///
    /// 为什么要有这个函数:已发布的隐私政策(`docs/PRIVACY.md` 第二节)写明
    /// 「日志不记录搜索词、完整 URL 或安装随机标识」,而这份日志在设置页有导出 / 分享 / 发邮箱
    /// 三条离机出口。H131(2026-10-05)定的修法「搜索词一律换词数」当时**只落在了
    /// `PodcastRepository.search` 一个调用点**,三个 Source 层各自把搜索词原文拼进了消息串,
    /// 于是 10 处漏扫 —— 正是那次自己总结的「规矩落在调用点上必漏」的复发
    /// (见 `docs/REVIEW-2026-10-25.md` 高-1)。
    /// 结构性解法只有一个:把「记什么」收到这一处。词数之外的事实(地区、条数上限、命中数、耗时)
    /// 照常打 —— 它们不含用户输入,却正是排查要看的。
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0.isNewline }).count
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
        var line = "\(ts) [\(level.rawValue)] [\(category)] \(sanitize(message))\n"
        if let error {
            // error 的 description 可能整段带 URL(URLError 的 userInfo 会塞失败地址),
            // 所以这一行也必须过同一个函数,不能只处理 message。
            line += "    ↳ \(sanitize(String(describing: error)))\n"
        }
        // 控制台镜像(便于开发期实时观察)。
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            rotateIfNeeded()
            append(line)
        }
    }

    /// 把文本里出现的 `http(s)://…` 收成 `scheme://host`。
    ///
    /// **为什么在 write 里统一做,而不是在各个调用点**:已发布的隐私政策第二节写明
    /// 「日志不记录搜索词、完整 URL」,而这句承诺对三端一起生效。Android 在
    /// `util/Logger.write` 里有同一个函数,鸿蒙在 `util/Logger.ets` 的 `sanitize()` ——
    /// 靠十几个调用点各自记得写 `host=` 必然漏(此前 macOS 的 `HTTPClient`、`RssParser`、
    /// `PlayerController`、`DownloadManager` 五处直接把完整 URL 打进文件)。
    /// 集中一处还有一个好处:新加日志的人不需要知道这条规矩。
    static func sanitize(_ text: String) -> String {
        guard text.contains("://") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>]+", options: [.caseInsensitive]) else { return text }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text) else { continue }
            result += text[cursor..<r.lowerBound]
            result += endpoint(String(text[r]))
            cursor = r.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// URL → `scheme://host`(去 path / query / fragment / 端口 / userinfo)。解析不出来时
    /// 返回 `invalid` 而不是原样吐回 —— 后者的失败方向是"悄悄把 URL 写进文件"。
    static func endpoint(_ url: String) -> String {
        guard let marker = url.range(of: "://") else { return "invalid" }
        let scheme = url[..<marker.lowerBound].lowercased()
        var authority = url[marker.upperBound...]
        if let cut = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = authority[..<cut]
        }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("[") {
            // IPv6 字面量:整个地址带冒号,不能按"最后一个冒号"去端口(鸿蒙 endpointOf 同处理)
            if let close = authority.firstIndex(of: "]") { authority = authority[...close] }
        } else if let colon = authority.lastIndex(of: ":") {
            authority = authority[..<colon]
        }
        guard !scheme.isEmpty, !authority.isEmpty else { return "invalid" }
        return "\(scheme)://\(authority)"
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
