import Foundation

/// 章节表的状态机与缓存。与 Android `data/local/ChapterStore.kt`、
/// 鸿蒙 `store/ChapterStore.ets` 同一种形状:切集即重置、命中缓存秒显、失败可重试。
///
/// **缓存不进备份**:章表能从 RSS 再取一遍,与逐字稿/音频缓存同待遇
/// (`AppSupport.excludeFromBackup`)。为什么还值得落盘:章节的价值恰好在
/// "已经下载好、正在离线听"的时候最大 —— 每次点开都现取一次,飞行模式下就永远只有"加载失败"。
///
/// 与逐字稿不同,**没有代次流水线**:章表只有"一次请求 → 一份列表",没有流式输出。
/// 但请求仍可能晚回来(用户中途切集、自动续播),所以回来时要再核一次 `episodeId`。
///
/// 缓存形态与 Android 一致(**一集一个文件**,`AppSupport/Chapters/<sanitize(id)>.json`);
/// 鸿蒙是单文件,那是 ArkTS 那边 `JsonFile` 的原子写更好管的缘故。格式不跨端互通 ——
/// 它是可再生的缓存,不在备份里。
@MainActor final class ChapterStore: ObservableObject {

    /// `empty` 与 `failed` 必须分开:前者是"这集确实没有章节"(界面不摆重试),
    /// 后者是"取不到"(要能再点一次)。混成一个,用户就会对一个永远重试不好的按钮点。
    enum State: Equatable {
        case idle
        case loading
        case done
        case empty
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var chapters: [Chapter] = []
    /// 当前状态属于哪一集。界面拿它判断"这份列表是不是当前这一集的" ——
    /// 切集后入口还在、列表却还是上一集的,比没入口更让人怀疑点错了。
    @Published private(set) var episodeId: String = ""

    /// 私有订阅源的 `Authorization`(章表常挂在订阅源同域下)。由 `AppEnvironment` 注入仓库的
    /// `authHeader(for:)` —— 与音频、feed、官方稿走同一个判据,不能在这里另写一套主机匹配。
    var authHeaderProvider: ((String) -> String?)?

    /// 章表缓存的口径版本。字段形状一变就 +1(硬规矩 11)—— 旧文件读出来是
    /// "能解析但缺字段"的章,那种错不会崩,只会显示一片空白。
    /// 与 Android `ChapterStore.CACHE_VERSION` / 鸿蒙同值同义。
    static let cacheVersion = 1

    /// `nonisolated`:目录只是磁盘上一个路径,别让它成为一次跨 actor 访问。
    nonisolated private static let subdir: URL = {
        let d = AppSupport.dir.appendingPathComponent("Chapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        AppSupport.excludeFromBackup(d)
        return d
    }()

    private struct Cached: Codable {
        let version: Int?
        let url: String
        /// 未 sanitize 的原始 id。文件名会把非字母数字折成 `_`,两条不同 id 可能撞同一个路径,
        /// 读回时拿这个字段核对归属(与 `TranscriptStore.Cached` 同一条)。
        let episodeId: String?
        let chapters: [Chapter]
    }

    private var job: Task<Void, Never>?

    // MARK: - 对外

    /// 切到某一集。只重置内存状态,**不自动请求** —— 章表弹层要用户点开才有意义,
    /// 冷启动时没有人看得见那份列表(与 Android / 鸿蒙同一条)。
    func prepare(episodeId: String) {
        guard episodeId != self.episodeId else { return }
        job?.cancel()
        job = nil
        self.episodeId = episodeId
        chapters = []
        state = .idle
    }

    /// 用户点开章表弹层时调用。命中缓存秒显;已成功或正在跑就不重复请求;失败过的允许再点一次。
    func load(episode: Episode) async {
        if episode.id != episodeId { prepare(episodeId: episode.id) }
        guard !episode.chaptersUrl.isEmpty else {
            chapters = []
            state = .empty
            return
        }
        if let cached = readCache(episodeId: episode.id, chaptersUrl: episode.chaptersUrl) {
            chapters = cached
            state = cached.isEmpty ? .empty : .done
            return
        }
        if state == .loading || state == .done { return }

        job?.cancel()
        state = .loading
        chapters = []
        let url = episode.chaptersUrl
        let header = authHeaderProvider?(url)
        job = Task { [weak self] in
            let list = await ChaptersFetcher.fetch(url: url, authHeader: header)
            guard let self, !Task.isCancelled else { return }
            // 请求期间用户可能已经切到别的集(自动续播),这一份不能写进当前状态
            guard self.episodeId == episode.id else { return }
            if let list {
                self.chapters = list
                self.writeCache(episodeId: episode.id, chaptersUrl: url, chapters: list)
                self.state = list.isEmpty ? .empty : .done
            } else {
                self.state = .failed
            }
        }
    }

    /// 当前播到第几章(最后一个 `startMs <= posMs`)。列表在数据出口已按 startMs 严格递增,
    /// 所以撞到第一个更大的就能停。调用方要先确认 `episodeId` 是当前这一集。
    func index(atMs posMs: Int) -> Int {
        var idx = -1
        for (i, c) in chapters.enumerated() {
            if c.startMs <= posMs { idx = i } else { break }
        }
        return idx
    }

    // MARK: - 缓存

    private func cacheURL(episodeId: String) -> URL {
        Self.subdir.appendingPathComponent("\(Self.sanitize(episodeId)).json")
    }

    /// 只认**同一条章节地址**的缓存。
    ///
    /// 判据必须带 URL:发布方换了章表地址(或同一集被重新发布),旧文件里的章节仍然"看得懂"、
    /// 时间也对得上,但它已经不是这一版节目了 —— 这种过期比读不出来更难发现。
    ///
    /// 同步读:章表是几十条标题的小 JSON(几 KB),与逐字稿那份 192 KB 不是一个量级,
    /// 不值得为它多起一个后台任务。
    private func readCache(episodeId: String, chaptersUrl: String) -> [Chapter]? {
        let url = cacheURL(episodeId: episodeId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cached = try? JSONDecoder().decode(Cached.self, from: data) else {
            Log.w("Chapters", "缓存读不了,丢弃 id=\(episodeId)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard (cached.version ?? 0) == Self.cacheVersion else { return nil }
        guard cached.url == chaptersUrl else { return nil }
        if let owner = cached.episodeId, owner != episodeId {
            Log.w("Chapters", "缓存归属不符(文件名撞车),丢弃 id=\(episodeId)")
            return nil
        }
        return cached.chapters
    }

    private func writeCache(episodeId: String, chaptersUrl: String, chapters: [Chapter]) {
        let c = Cached(version: Self.cacheVersion, url: chaptersUrl,
                       episodeId: episodeId, chapters: chapters)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: cacheURL(episodeId: episodeId), options: .atomic)
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }).prefix(120).description
    }
}
