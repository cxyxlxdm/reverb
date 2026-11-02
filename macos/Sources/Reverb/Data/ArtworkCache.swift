import Foundation
import ImageIO

/// 封面的磁盘缓存 `Application Support/Reverb/artwork_cache/`。
///
/// **为什么自研**:`RemoteImage` 此前靠 `URLSession.shared` 的 `URLCache`,那是系统级的黑盒 ——
/// 容量由系统按磁盘余量决定、既不计数也无法在设置里清空,用户在「清除缓存」里看到的那一行
/// 永远漏掉图片这一大块。而本端不许引第三方库,所以照鸿蒙 `ArtworkCache.ets` 自己落一份文件:
/// 20 MB 预算、按 mtime 淘汰、最多 4 张并发。
///
/// **没有账本文件**:文件名由 URL 哈希直接算得出,目录本身就是账。音频那边要账本是因为
/// 要按集数做 LRU 与预算;图片不需要访问时间(见下),就别引入第三种不一致。
///
/// 淘汰按**下载时间(mtime)**,不按访问时间:图片是可重取的小对象,淘汰只影响"再看一遍
/// 要不要联网",不值得为它在渲染路径上写盘(硬规矩 6:每屏几十张,每张都 touch 一次
/// 等于给滚动加一轮 IO)。
///
/// **不走蜂窝闸门**:一张封面几十 KB,手机两端也都不为此停写。桌面更没有蜂窝基带,
/// 理由与 `AudioCacheManager` 顶部那段同一条。
actor ArtworkCache {
    static let shared = ArtworkCache()

    /// 缓存总字节预算。按 30 KB/张算约容 700 张,足够覆盖"最近翻过的所有频道"。
    static let budgetBytes: Int64 = 20 * 1024 * 1024
    /// 同时在飞的下载上限:一屏宫格就可能出现 30 张没缓存过的封面,
    /// 各开一条流会把带宽和 fd 一起打满,而首屏要的这几张反而被自己挤慢。
    private static let maxConcurrent = 4
    /// 失败冷却:断网浏览正是要支持的场景,一屏 30 张 miss 会各自等一次超时;
    /// 没有冷却时把列表滚下去再滚回来又是一整轮注定失败的请求。
    /// 必须有出口 —— 过了这个时限允许再试,网络恢复后不用重启应用就能补齐。
    private static let retryInterval: TimeInterval = 60
    private static let category = "Artwork"

    private struct Entry {
        var bytes: Int64
        var mtime: Date
        var file: URL
    }

    private let dir: URL
    /// 文件名 → 条目。界面每次命中都先查它,所以这一层**不能有同步 IO**(见 data(for:))。
    private var entries: [String: Entry] = [:]
    private var totalBytes: Int64 = 0
    /// 正在传的那些。同一张封面被十几个格子同时要时只发一次请求。
    private var inflight: [String: Task<Data?, Never>] = [:]
    /// 失败冷却表:文件名 → 失败时刻。
    private var failedAt: [String: Date] = [:]
    /// 清理代号:每清一次 +1,在途下载落盘前比对,不一致就丢弃。
    ///
    /// 没有这一格的后果是「清除缓存」**看起来没生效**:按下时正好有几张在传,
    /// 它们会在目录清空之后把文件写回来,设置页那个字节数当场又非 0。
    /// 与 `AudioCacheManager.generation` 是同一个形状。
    private var generation = 0
    /// 并发闸门(见 acquireSlot / releaseSlot)。
    private var active = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        dir = AppSupport.dir.appendingPathComponent("artwork_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppSupport.excludeFromBackup(dir)
        // 扫目录要一次磁盘往返;晚到几毫秒只意味着首屏走远程,不影响正确性。
        Task.detached(priority: .utility) { [weak self] in await self?.scan() }
    }

    // MARK: - 对外

    /// 有本地副本就给本地字节,否则联网取一份顺手落盘。**失败一律返回 nil,绝不抛**。
    ///
    /// 返回值是 `Data` 而不是本地 URL:调用方(`RemoteImage`)本来就要用 `NSImage(data:)` 解码,
    /// 让它在自己的后台任务里做;这里只保证"字节是完整的、可解码的"。
    func data(for urlString: String) async -> Data? {
        guard !urlString.isEmpty else { return nil }
        let name = Self.fileName(urlString)

        if let e = entries[name] {
            if let data = try? Data(contentsOf: e.file), !data.isEmpty { return data }
            // 目录被外部清过:当作没有,顺手把账抹掉(下一次写会重新落)。
            entries.removeValue(forKey: name)
            totalBytes -= e.bytes
            try? FileManager.default.removeItem(at: e.file)
        }
        if let t = inflight[name] { return await t.value }
        if let at = failedAt[name], Date().timeIntervalSince(at) < Self.retryInterval { return nil }

        let gen = generation
        // **detached**:`Task {}` 会继承本 actor 的隔离,四张图就被串成一张一张下。
        let task = Task.detached(priority: .utility) { [weak self] () -> Data? in
            guard let self else { return nil }
            return await self.fetchAndStore(urlString: urlString, name: name, gen: gen)
        }
        inflight[name] = task
        return await task.value
    }

    /// 磁盘上的真实占用(含 `.part` 之外的都算)。设置页「清除缓存」那一行读它。
    ///
    /// 不读内存里的 `totalBytes`:设置页可能在扫描完成之前打开,而且用户手删过目录时
    /// 内存值会偏大。目录扫一遍是几十到几百个 stat,只在打开设置与清完后各跑一次。
    func usageBytes() -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        for n in names where !n.hasSuffix(".part") {
            let p = dir.appendingPathComponent(n).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    func count() -> Int { entries.count }

    /// 「清除缓存」:整目录清空 + 内存表作废。
    ///
    /// **先抬代号**再删文件:在途那些落盘前会比对代号,不一致就丢弃自己那份 `.part`。
    /// 队列里尚未开始的不必单独取消 —— 它们也走同一个比对。
    func clear() {
        generation += 1
        entries.removeAll()
        failedAt.removeAll()
        totalBytes = 0
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
        Log.i(Self.category, "clearAll files=\(names.count)")
    }

    // MARK: - 下载与落盘

    private func fetchAndStore(urlString: String, name: String, gen: Int) async -> Data? {
        defer {
            inflight.removeValue(forKey: name)
            releaseSlot()
        }
        await acquireSlot()
        guard let url = URL(string: urlString) else {
            Log.w(Self.category, "非法 URL")
            return nil
        }
        do {
            let (data, response) = try await HTTP.session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.w(Self.category, "http \(code) \(Log.endpoint(urlString))")
                markFailed(name)
                return nil
            }
            // **验一遍能解码才认**:扩展名是从 URL 猜的,而 CDN 常把 webp 挂在 .jpg 上。
            // 猜错的后果不是"缓存没用上",而是界面从此显示一张空白 —— 本地文件被判成坏图,
            // 比没有缓存更糟。判不过就丢掉,继续走远程。
            guard Self.decodable(data) else {
                Log.w(Self.category, "解码校验未过,丢弃 \(name)")
                markFailed(name)
                return nil
            }
            // 传输期间用户按了「清除缓存」:目录已经空了,这张不能再写回去(见 generation)。
            // 这一次传输本身是好的,所以**不记失败冷却**。
            guard gen == generation else {
                Log.i(Self.category, "clear during fetch, discard \(name)")
                return nil
            }
            let target = dir.appendingPathComponent(name)
            let part = dir.appendingPathComponent(name + ".part")
            do {
                try data.write(to: part, options: .atomic)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: part, to: target)
            } catch {
                try? FileManager.default.removeItem(at: part)
                Log.w(Self.category, "写盘失败 \(name): \(error.localizedDescription)")
                markFailed(name)
                return nil
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
            if let old = entries[name] { totalBytes -= old.bytes }
            entries[name] = Entry(
                bytes: bytes,
                mtime: (attrs?[.modificationDate] as? Date) ?? Date(),
                file: target
            )
            totalBytes += bytes
            failedAt.removeValue(forKey: name)
            evict()
            Log.i(Self.category, "cached \(name) \(bytes / 1024)KB")
            return data
        } catch is CancellationError {
            return nil
        } catch {
            Log.w(Self.category, "缓存失败 \(Log.endpoint(urlString)): \(error.localizedDescription)")
            markFailed(name)
            return nil
        }
    }

    /// 这一张没取成:记下时刻,让 `retryInterval` 内的重复请求直接跳过。
    private func markFailed(_ name: String) {
        failedAt[name] = Date()
    }

    /// 启动时把目录里已有的副本装进内存表(异步,不在启动路径上;晚到只是首屏走远程)。
    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        var total: Int64 = 0
        for n in names {
            let p = dir.appendingPathComponent(n)
            // 半截文件按定义是不完整的,留着只会占预算
            if n.hasSuffix(".part") {
                try? fm.removeItem(at: p)
                continue
            }
            guard let attrs = try? fm.attributesOfItem(atPath: p.path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size <= 0 {
                try? fm.removeItem(at: p)
                continue
            }
            entries[n] = Entry(bytes: size, mtime: (attrs[.modificationDate] as? Date) ?? .distantPast, file: p)
            total += size
        }
        totalBytes = total
        Log.i(Self.category, "本地封面 \(entries.count) 张 \(total / 1024)KB")
        evict()
    }

    /// 超预算按 mtime 从旧到新删。当前正在显示的那张是最新的,排在末尾;
    /// 20 MB 远大于单张封面,正常路径删到低于预算就停,轮不到它。
    private func evict() {
        guard totalBytes > Self.budgetBytes else { return }
        for (name, e) in entries.sorted(by: { $0.value.mtime < $1.value.mtime }) {
            if totalBytes <= Self.budgetBytes { break }
            try? FileManager.default.removeItem(at: e.file)
            entries.removeValue(forKey: name)
            totalBytes -= e.bytes
        }
        Log.i(Self.category, "预算淘汰后 \(entries.count) 张 \(totalBytes / 1024)KB")
    }

    // MARK: - 并发闸门

    private func acquireSlot() async {
        if active < Self.maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
        active += 1
    }

    private func releaseSlot() {
        active -= 1
        if !slotWaiters.isEmpty {
            // 被唤醒的一方在上面那句 `active += 1` 里补回来,净值不变
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: - 文件名

    /// 文件名:`art_<url 的 FNV-1a 64 位十六进制><猜的扩展名>`。哈希必须**跨进程稳定** ——
    /// Swift 的 `hashValue` 每次启动换种子,不能用来当文件名。扩展名只给解码器一个提示,
    /// 真判据是上面那次解码校验。
    static func fileName(_ url: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in url.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16)
        let lower = url.lowercased()
        let ext: String
        if lower.contains(".png") { ext = ".png" }
        else if lower.contains(".webp") { ext = ".webp" }
        else if lower.contains(".gif") { ext = ".gif" }
        else if lower.contains(".avif") { ext = ".avif" }
        else { ext = ".jpg" }
        return "art_\(hex)\(ext)"
    }

    /// 图片头能解析出正宽度才算"可解码"。用 ImageIO 而不是 `NSImage`:
    /// 前者不依赖 AppKit,在 actor 的后台上下文里跑没有主线程方面的顾虑。
    static func decodable(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        return w > 0
    }
}
