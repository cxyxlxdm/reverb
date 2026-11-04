import Foundation

/// 播放过的整集音频落到 `Application Support/Reverb/audio_cache/`,下次直接本地起播、不再联网。
///
/// 三条实现上的硬要求(与 Android `AudioCacheManager` / 鸿蒙同名类逐条对齐):
///  1. **写完才认账** —— 先落到 `.part`,成功再 rename 成正式名并记账。
///     否则进程被杀留下的半截文件会被当成完整缓存,表现是「这集播到一半就没声」,
///     而用户看到的是一条完全正常的历史记录。
///  2. **单飞、最新优先** —— 用户连着点开三集,只有最后一集值得下。同时下三集会在
///     几十 MB 的量级上把带宽和磁盘打满,而前两集大概率不会再听。
///  3. **字节预算 + LRU** —— 缓存无上限等于把用户硬盘当网盘;超预算挤掉最久没听的。
///
/// 与 `DownloadManager` 完全分开:不同目录、不同账本、不同清理入口。用户点名下载的那份
/// 永远不该被预算挤掉,所以本类**从不读写** `Downloads/`;反过来「清空下载」也删不到这里。
///
/// **桌面不接网络闸门**:手机两端拦的是「计费蜂窝上擅自跑几十 MB」。桌面没有蜂窝基带,
/// Mac 上唯一算"按量计费"的是给 iPhone 开热点,而本端 Downloads 与 RSS 也从不做这类拦截;
/// `SettingsStore.allowCellularDownload` 在 Mac 上没有界面、只为备份互通而存在
/// (见那一格的长注释)。只给音频缓存单独加一道看不见的闸门,症状会比问题更难排查。
///
/// **iOS 不同**:那一端「仅在 Wi-Fi 下载」是有界面的真开关,而首播落缓存正是三条大流量
/// 路径之一(另两条见 `DownloadManager` 与 `TranscriptStore`)。所以闸门做成可选的
/// `allowsTransfer`(nil = 不拦,macOS 保持原样),由 iOS 在 `AppEnvironment` 里接上
/// `CellularGate.blocked()`。判据本体不在本层 —— 本层不引 Network 框架。
final class AudioCacheManager: @unchecked Sendable {
    /// 缓存总字节预算。整集 mp3 约 30–60 MB,300 MB 大约容下最近听过的 6–8 集。
    static let budgetBytes: Int64 = 300 * 1024 * 1024

    private static let category = "AudioCache"

    private let store: AudioCacheStore
    private let dir: URL
    private let lock = NSLock()
    /// 正在拉的那一集(单飞的判据)。下载任务每一段落盘前都要看它还算不算自己。
    private var inFlightId = ""
    private var inFlightTask: Task<Void, Never>?
    /// 清理代号:每清一次 +1。在途下载落名之前比对,不一致就丢弃。
    /// 没有这一格,「清除缓存」按下时正好在传的那几张会在目录清空之后 rename 回来,
    /// 设置页的数字当场又变成非 0 —— 与鸿蒙 `ArtworkCache.gen` 同一个形状。
    private var generation = 0

    /// 「这次落缓存该不该放行」的闸门,nil = 不拦(macOS 的取值)。见类注释。
    /// 闭包必须**同步、线程安全**:它会在 `Task.detached` 起的下载路径上被调用。
    var allowsTransfer: (() -> Bool)?

    init(store: AudioCacheStore = AudioCacheStore()) {
        self.store = store
        dir = AppSupport.dir.appendingPathComponent(AudioCacheStore.dirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppSupport.excludeFromBackup(dir)
        // 对账要扫目录、要删孤儿,是 IO;放主线程就是给启动加一次磁盘往返。
        // 晚几毫秒不影响任何东西 —— 起播时的判定只看文件是否存在(见 localURL)。
        Task.detached(priority: .utility) { [weak self] in self?.reconcile() }
    }

    /// 本地缓存文件,**只在文件真存在且非空时**返回。
    ///
    /// 刻意不返回「账本说有」的路径:账可能比文件新(系统清理过目录、用户手删过)。
    /// 把不存在的路径交给播放器 = 一集点了没反应,而界面上没有任何东西能解释。
    func localURL(_ episodeId: String) -> URL? {
        guard let item = store.get(episodeId) else { return nil }
        let url = dir.appendingPathComponent(item.fileName)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return (size?.int64Value ?? 0) > 0 ? url : nil
    }

    /// 从缓存起播时记一次访问 —— LRU 的依据(见 `AudioCacheStore.touch`)。
    func touch(_ episodeId: String) {
        store.touch(episodeId)
    }

    /// 首播走流式时排一次「整集落缓存」。幂等且**不排队**:
    /// 已缓存 / 正在下这一集 / 内置引导音频一律直接返回。
    ///
    /// - Parameter headers: 取流要带的请求头。只有视频源那一族用得上(CDN 要 UA + `Referer`,
    ///   缺了 403),普通 RSS 单集传空即走会话默认头。
    func cache(_ episode: Episode, headers: [String: String] = [:]) {
        let id = episode.id
        let urlText = episode.audioUrl
        guard !id.isEmpty, !urlText.isEmpty else { return }
        // 引导音频指向包内资源,不是 HTTP enclosure,没什么可缓存
        guard !GuideEpisode.isGuide(id) else { return }
        guard store.get(id) == nil else { return }
        if let allowsTransfer, !allowsTransfer() {
            Log.i(Self.category, "cache 被计费链路闸门拦下 id=\(id)(未允许蜂窝下载,本次不落缓存)")
            return
        }

        lock.lock()
        if inFlightId == id {
            lock.unlock()
            return
        }
        inFlightTask?.cancel()          // 挤掉上一个:它会在下一段落盘前自检时停住
        let gen = generation
        inFlightId = id
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.fetch(id: id, urlText: urlText, headers: headers, gen: gen)
        }
        inFlightTask = task
        lock.unlock()
        Log.i(Self.category, "cache start id=\(id) endpoint=\(Log.endpoint(urlText))")
    }

    /// 磁盘上的真实占用(不是账本字节数之和 —— 账可能旧,而 `.part` 根本不算缓存)。
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

    func count() -> Int { store.count() }

    /// 「清除缓存」:目录整个清空(含中途取消留下的 `.part`),账本一并作废。
    ///
    /// 顺序是硬的:**先**抬代号并取消在途任务,**再**清账、删文件。
    /// 在途那次是在 rename 前比对自己还算不算数 —— 不清掉认领,它会在目录已空之后
    /// 把文件写回来,用户点了「清除缓存」却看到数字没怎么变。
    func clearAll() {
        lock.lock()
        generation += 1
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightId = ""
        lock.unlock()

        let names = store.clearAll()
        Log.i(Self.category, "clearAll entries=\(names.count)")
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    // MARK: - 下载

    /// 0 = 成功;被取消/失败都走同一批收尾(`.part` 删掉、认领清掉)。
    private func fetch(id: String, urlText: String, headers: [String: String], gen: Int) async {
        defer {
            clearInFlight(id)
            // 正常路径 rename 之后 `.part` 已不存在,这是空操作;失败/取消都靠它收尾。
            try? FileManager.default.removeItem(at: partURL(for: id, urlText: urlText))
        }
        let name = Self.fileName(id: id, url: urlText)
        let target = dir.appendingPathComponent(name)
        let part = dir.appendingPathComponent(name + ".part")
        try? FileManager.default.removeItem(at: part)
        do {
            // 先下到系统临时文件:整个传输期间正式名与 `.part` 都不存在,
            // 所以"半截文件冒充完整缓存"这件事在结构上不可能发生。
            guard let (tmp, response) = await HTTP.download(urlText, headers: headers) else {
                if Task.isCancelled {
                    Log.i(Self.category, "cache cancelled id=\(id)")
                } else {
                    Log.w(Self.category, "cache 传输失败 id=\(id)")
                }
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.w(Self.category, "cache http \(code) id=\(id)")
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber
            guard (bytes?.int64Value ?? 0) > 0 else {
                Log.w(Self.category, "cache empty body id=\(id)")
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            // 收完最后一块与落名之间用户可能正好换集/按了「清除缓存」:认一次领再往下走
            if isStale(id: id, gen: gen) {
                Log.i(Self.category, "cache cancelled before rename id=\(id)")
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            // **先 rename 再记账**:反过来的话,一次进程被杀就留下「账上有、文件没落地」。
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: tmp, to: part)
            if isStale(id: id, gen: gen) {
                try? FileManager.default.removeItem(at: part)
                Log.i(Self.category, "cache cancelled before final rename id=\(id)")
                return
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: part, to: target)
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber
            let now = AudioCacheStore.nowMs()
            store.put(AudioCacheEntry(
                episodeId: id,
                audioUrl: urlText,
                fileName: name,
                bytes: size?.int64Value ?? 0,
                cachedAt: now,
                lastAccess: now
            ))
            Log.i(Self.category, "cache done id=\(id) bytes=\(size?.int64Value ?? 0)")
            evict(keepId: id)
        } catch is CancellationError {
            Log.i(Self.category, "cache cancelled id=\(id)")
        } catch {
            Log.w(Self.category, "cache failed id=\(id): \(error.localizedDescription)")
        }
    }

    /// 超预算就按「最久没听」依次删。[keepId] 是刚下完的这集(大概率正在播,绝不能删)。
    private func evict(keepId: String) {
        var usage = usageBytes()
        guard usage > Self.budgetBytes else { return }
        for item in store.byLeastRecent() {
            if usage <= Self.budgetBytes { break }
            if item.episodeId == keepId { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.fileName))
            store.remove(item.episodeId)
            usage -= item.bytes
            Log.i(Self.category, "evicted id=\(item.episodeId) bytes=\(item.bytes)")
        }
    }

    /// 目录与账本互相校正:账指不到文件的删账,文件没人认领的删文件(含半截 `.part` 与空文件)。
    ///
    /// 两边都可能单独变:系统可以清理缓存目录,崩溃会留下 `.part`。不一致的后果不是脏文件
    /// 那么温和 —— 账上有一条就意味着 `localURL` 可能交出播不了的路径。
    ///
    /// 与本类其余方法一样在后台任务里跑;即使与刚起步的一次下载撞上,最坏也只是这次缓存白下
    /// (`localURL` 仍按文件存在判定,不会把坏路径交给播放器)。
    private func reconcile() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let known = store.fileNameToId()
        for n in names {
            let p = dir.appendingPathComponent(n)
            guard let owner = known[n] else {
                try? fm.removeItem(at: p)   // 不认识的文件(含 .part)
                continue
            }
            let size = (try? fm.attributesOfItem(atPath: p.path))?[.size] as? NSNumber
            if (size?.int64Value ?? 0) <= 0 {
                try? fm.removeItem(at: p)
                store.remove(owner)
            }
        }
        for item in store.all() {
            if !fm.fileExists(atPath: dir.appendingPathComponent(item.fileName).path) {
                store.remove(item.episodeId)
            }
        }
        evict(keepId: "")
        Log.i(Self.category, "reconcile 后 \(store.count()) 集 \(usageBytes() / 1024)KB")
    }

    // MARK: - 认领

    private func isStale(id: String, gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen != generation || inFlightId != id
    }

    private func clearInFlight(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if inFlightId == id {
            inFlightId = ""
            inFlightTask = nil
        }
    }

    private func partURL(for id: String, urlText: String) -> URL {
        dir.appendingPathComponent(Self.fileName(id: id, url: urlText) + ".part")
    }

    /// 文件名:`ca_<id 的 FNV-1a 64 位十六进制><扩展名>`。
    /// 前缀与下载分开,便于进目录看一眼就知道这个文件归谁管。哈希必须**跨进程稳定** ——
    /// Swift 的 `hashValue` 每次启动换种子,不能用。
    private static func fileName(id: String, url: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16)
        let lower = url.lowercased()
        let ext: String
        // 视频源的音频流是 `.m4s`(分片 MP4)。**落盘必须改名成 `.m4a`**:
        // 2026-10-28 本机实测同一份内容,`.m4s` 交给 AVPlayer 是 `Cannot Open`,
        // 换成 `.m4a` / `.mp4` 立刻可播(dur 174.1s)—— AVFoundation 按扩展名认容器,
        // 不认识就直接放弃。所以这里存的是「它就是 MP4 音频」这个事实,不是原始后缀。
        if lower.contains(".m4s") { ext = ".m4a" }
        else if lower.contains(".m4a") { ext = ".m4a" }
        else if lower.contains(".aac") { ext = ".aac" }
        else if lower.contains(".ogg") { ext = ".ogg" }
        else if lower.contains(".wav") { ext = ".wav" }
        else { ext = ".mp3" }
        return "ca_\(hex)\(ext)"
    }
}
