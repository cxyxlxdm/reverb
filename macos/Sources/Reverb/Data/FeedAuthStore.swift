import Foundation

/// 私有订阅源的凭据账本:`feedUrl -> 用户名/密码`。与 Android `data/local/FeedAuthStore.kt` 同一口径。
///
/// 三条口径(与 `docs/FEATURES.md` 订阅那一节同源):
///  1. **只存本机,不进任何备份。** 落盘位置与其余 JSON 账本同目录,但文件本身排除在
///     iOS 备份之外(`excludeFromBackup`);系统的「完整备份」只导出订阅列表,不含凭据。
///     换机后用户需要重新输入一次 —— 这是有意的:口令不该跟着 JSON 到处走。
///  2. **只发给源自己。** [`headerForUrl`] 按主机匹配(= 同主机或互为子域),不对"任意音频
///     CDN"发送。音频与 feed 常常不同主机,那种情况下宁可不带 —— 把口令交给一个与用户
///     无关的主机,是本仓库隐私口径里不能接受的一步(见 H253)。
///  3. **日志只记主机。** `Log.endpoint` 会把 URL 裁到 scheme://host,账号密码一个字都不进日志。
///
/// 不加密:与应用里其余 JSON 账本一样落在 Application Support 的私有目录,没有 Keychain 支持时
/// "加密"只是把钥匙放在同一台设备上,不值得多一层自欺。
///
/// 线程模型:本类是 `@unchecked Sendable`,由 `NSLock` 保护内存表 ——
/// 音频缓存的下载在 `Task.detached` 里、feed 请求在任意线程,都要能同步读到头。
final class FeedAuthStore: @unchecked Sendable {

    private static let fileName = "feed_auth.json"

    /// 磁盘表示。字段名与 Android 那份 `{"v":1,"items":{feed:{"u","p"}}}` 一致 ——
    /// 这份文件从不跨端同步,同形只是为了让两端排查时读同一个键。
    private struct Stored: Codable {
        var v: Int
        var items: [String: Item]
    }
    private struct Item: Codable {
        var u: String
        var p: String
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var mem: [String: FeedCredential]

    init() {
        fileURL = AppSupport.dir.appendingPathComponent(Self.fileName)
        AppSupport.excludeFromBackup(fileURL)
        mem = Self.load(fileURL)
        if !mem.isEmpty { Log.i("FeedAuth", "装载 \(mem.count) 条源凭据") }
    }

    func get(_ feedUrl: String) -> FeedCredential? {
        lock.lock(); defer { lock.unlock() }
        return mem[feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// 保存(覆盖)某个源的凭据。
    ///
    /// **同步落盘**,与 `AppSupport.save` 的去抖通道不同:这份文件只有几百字节,而它承载的是
    /// 用户刚输入、马上要用来重试的口令 —— 进程在 0.4 秒内被杀就丢,不值得省这一次写盘。
    func save(_ feedUrl: String, _ credential: FeedCredential) {
        let key = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !credential.username.isEmpty else { return }
        lock.lock()
        mem[key] = credential
        persistLocked()
        lock.unlock()
        Log.i("FeedAuth", "save feed=\(Log.endpoint(key))")
    }

    func forget(_ feedUrl: String) {
        let key = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        guard mem.removeValue(forKey: key) != nil else { lock.unlock(); return }
        persistLocked()
        lock.unlock()
        Log.i("FeedAuth", "forget feed=\(Log.endpoint(key))")
    }

    /// 某个源自己的凭据头(feed 请求用)。
    func headerFor(_ feedUrl: String) -> String? {
        get(feedUrl)?.defaultHeader
    }

    /// 音频 / 逐字稿:只有与某个已存源的**主机**相同(或互为子域)才给凭据。
    ///
    /// 同一主机上存了多份**不同**凭据时不给(不猜) —— 宁可让用户看到 401 再输一次,
    /// 也不要把 A 站的口令发给 B 站。
    func headerForUrl(_ url: String) -> String? {
        guard let host = Self.hostOf(url) else { return nil }
        let candidates = mem.compactMap { key, value -> FeedCredential? in
            guard let k = Self.hostOf(key), Self.hostMatches(host, k) else { return nil }
            return value
        }
        let distinct = Array(Set(candidates.map { "\($0.username)\u{0}\($0.password)" }))
        guard distinct.count == 1, let only = candidates.first else { return nil }
        return only.defaultHeader
    }

    // MARK: - 持久化

    private func persistLocked() {
        let items = mem.mapValues { Item(u: $0.username, p: $0.password) }
        guard let data = try? JSONEncoder().encode(Stored(v: 1, items: items)) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // 首次保存时文件才出现:init 那次 excludeFromBackup 对着不存在的路径是空操作。
        // 写后必须补一次,否则「第一次存凭据 → 立刻被系统备份」这条窗口里口令会进备份。
        AppSupport.excludeFromBackup(fileURL)
    }

    private static func load(_ url: URL) -> [String: FeedCredential] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        #if os(iOS)
        // 排除标记可能在重装/恢复后失效,读的时候补一次(与音频/封面目录同一个理由)。
        AppSupport.excludeFromBackup(url)
        #endif
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            Log.e("FeedAuth", "读坏,按空账本启动")
            return [:]
        }
        var out: [String: FeedCredential] = [:]
        for (feed, item) in stored.items where !item.u.isEmpty {
            out[feed] = FeedCredential(username: item.u, password: item.p)
        }
        return out
    }

    // MARK: - 主机匹配

    static func hostOf(_ url: String) -> String? {
        URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased()
    }

    /// `a.example.com` 与 `example.com` 视为同源;`other.com` 不算。
    static func hostMatches(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }
}
