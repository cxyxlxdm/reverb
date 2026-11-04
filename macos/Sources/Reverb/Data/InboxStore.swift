import Foundation

/// 「追更」收件箱:合并**所有订阅的全部单集**,按发布时间倒序,持久化到 inbox.json。
/// 打开即用缓存秒显,再后台刷新替换。
///
/// **内存侧不截断,落盘侧 300 条**(与 Android `InboxStore` / 鸿蒙 `InboxStore.ets` 同口径)。
/// 2026-10-10 手机那轮之前这里是「每源只留最新 12 集 / 全局 100 条」,于是这一页只显示
/// 每个频道的头几集 —— 与"追更 = 管理我订阅的全部内容"的定位不符。桌面这一轮照搬该口径
/// (见 docs/MACOS-GAPS.md D3):`repository.feed()` 本来就整份下载并解析全量 RSS,
/// 那两道截断从不省网络也不省解析,只限制"留下多少条"。
@MainActor final class InboxStore: ObservableObject {
    @Published private(set) var episodes: [Episode]
    @Published private(set) var refreshing = false

    /// 已成功刷新过的订阅集签名。用于避免每次切到「追更」都全量重刷:
    /// 只有签名变化(订阅增删)或手动刷新才重新拉取。
    private var loadedSignature: String?

    /// 落盘只留最新 300 条,而内存留全量 —— 这是有意的分工,不是漏改:
    ///  1. 这份文件的用处只有「冷启动秒显」,几千集整份 JSON 在主线程上解码就是 H65 那个形状;
    ///  2. 体量:每条连 shownotes 原文一起存,中位 1.4–3.6 KB ⇒ 全量落盘是 10–27 MB 这一档;
    ///     Android 装机实测 300 条是 741 KB,仍在亚 MB。
    /// 因为落的是**排序后的前缀**,秒显看到的就是全量列表的开头,刷新完只做后缀追加,
    /// 不会出现"前 300 条换顺序"。代价:深滚之后杀进程,重进要从头显。
    private let persistMax = 300
    private let maxConcurrent = 8
    private let feedTimeoutSec: Double = 8

    init() {
        episodes = AppSupport.load("inbox.json", as: [Episode].self) ?? []
        Log.i("Inbox", "追更加载 \(episodes.count) 条")
    }

    /// 订阅集未变化时跳过刷新。供「追更」页 `.task` 调用,避免切 tab 重复全量刷新。
    func refreshIfStale(subscriptions: [Podcast], repository: PodcastRepository) async {
        if loadedSignature == Self.signature(subscriptions) { return }
        await refresh(subscriptions: subscriptions, repository: repository)
    }

    /// 并发(有界)拉取全部订阅源,**单源不截断**,解析完成即增量合并
    /// (按 id 去重、按发布时间倒序)并即时发布;全部完成后持久化(只落前缀 300 条)。
    ///
    /// pubDate 的解析结果按 id 记在 `keys` 里,每次合并只解析**新进来**的那些:
    /// 全量之后一轮几千集、每个源到达都重排一次,如果在比较器或排序前整表重解析,
    /// 就是硬规矩 6 那条乘法(调用次数 × 每次成本)—— Android 在 `sortedStable` 那条注释里
    /// 量过这个坑,这里同一条解法。
    func refresh(subscriptions: [Podcast], repository: PodcastRepository) async {
        guard !refreshing else { Log.d("Inbox", "刷新进行中,忽略重复请求"); return }
        let feeds = subscriptions.map { $0.feedUrl }.filter { !$0.isEmpty }
        guard !feeds.isEmpty else {
            Log.i("Inbox", "无订阅,清空追更")
            if !episodes.isEmpty { episodes = []; persist() }
            loadedSignature = ""
            return
        }

        refreshing = true
        defer { refreshing = false }
        let t0 = Date()
        Log.i("Inbox", "刷新追更 订阅=\(feeds.count) 并发=\(maxConcurrent) 单源不截断")

        // 运行列表:从空开始,按源到达增量合并。seen 用于跨源去重(保留首次出现)。
        // hasCache:已有缓存内容时,刷新期间不增量替换可见列表(否则会先坍缩再重建、产生跳动),
        // 仅在冷启动无缓存时才增量填充以提供进度反馈;有缓存则后台合完最终一次性替换。
        let hasCache = !episodes.isEmpty
        var merged: [Episode] = []
        var seen = Set<String>()
        var keys: [String: Date] = [:]
        var rawCount = 0

        let timeout = feedTimeoutSec
        await withTaskGroup(of: [Episode].self) { group in
            var index = 0
            func addNext() {
                guard index < feeds.count else { return }
                let url = feeds[index]; index += 1
                group.addTask {
                    await Self.loadAll(url, repository: repository, timeoutSec: timeout)
                }
            }
            for _ in 0..<min(maxConcurrent, feeds.count) { addNext() }
            while let eps = await group.next() {
                rawCount += eps.count
                var added = false
                for e in eps where seen.insert(e.id).inserted {
                    merged.append(e)
                    if let d = Fmt.parseDate(e.pubDate) { keys[e.id] = d }
                    added = true
                }
                if added {
                    merged = Self.sortedStable(merged, keys: keys)
                    if !hasCache {
                        let snapshot = merged
                        await MainActor.run { self.episodes = snapshot }   // 冷启动增量发布(主线程)
                    }
                }
                addNext()
            }
        }

        // 一次性原子替换(靠 id diff,已有条目位置稳定不跳动)+ 落盘。
        // 若全部源失败/超时(merged 为空)且已有缓存,则不用空列表覆盖,避免一次刷新失败把
        // 「追更」清空,并且不标记已加载,以便下次切回来时重试。
        if !merged.isEmpty {
            episodes = merged
            persist()
            loadedSignature = Self.signature(subscriptions)
        } else if !hasCache {
            episodes = merged
            loadedSignature = Self.signature(subscriptions)
        }
        Log.i("Inbox", "刷新追更 → 收集 \(rawCount) 展示 \(episodes.count) " +
                       "落盘 \(min(episodes.count, persistMax)) \(Log.ms(t0))")
    }

    /// 订阅集签名:非空 feedUrl 排序后拼接,用于判断订阅集是否变化。
    private static func signature(_ subscriptions: [Podcast]) -> String {
        subscriptions.map { $0.feedUrl }.filter { !$0.isEmpty }.sorted().joined(separator: "|")
    }

    /// 拉取单个订阅源,带 ~timeoutSec 超时。失败或超时返回空数组,不影响其他源。
    /// **不按源截断** —— 追更要能翻到订阅频道的全部节目(与两端同口径)。
    ///
    /// 非 private 是因为 iOS 的「订阅更新提醒」巡检(`UpdateReminders`)复用这一份:
    /// 它同样要「限并发 + 单源超时 + 失败不拖累其余源」,而那段判据抄第二份时一定会漏
    /// (REVIEW-2026-10-25 中-3 的同一条形状)。macOS 只有本类的追更在用。
    static func loadAll(_ url: String, repository: PodcastRepository,
                        timeoutSec: Double) async -> [Episode] {
        let result: [Episode]? = await withTaskGroup(of: [Episode]?.self) { group in
            group.addTask {
                guard let r = await repository.feed(url) else { return [] }
                return r.episodes
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                return nil   // 超时哨兵
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let episodes = result else {
            Log.w("Inbox", "feed 超时 \(url)")
            return []
        }
        return episodes
    }

    /// 稳定全序:发布时间倒序,同值按 id 升序。
    ///
    /// id 次序不是风格问题:各源并行返回的顺序不定,只按日期排序时,日期相同/无法解析的
    /// 单集相对顺序会随一次刷新的到达次序变化 —— 内容没变,列表却"闪动"。Android/Harmony
    /// 的 `sortedStable` 同一条。日期从 `keys` 查(解析在合并处做过),比较器里不再解析。
    private static func sortedStable(_ src: [Episode], keys: [String: Date]) -> [Episode] {
        src.map { ($0, keys[$0.id]) }
            .sorted { l, r in
                switch (l.1, r.1) {
                case let (a?, b?): return a != b ? a > b : l.0.id < r.0.id
                case (_?, nil): return true
                case (nil, _?): return false
                default: return l.0.id < r.0.id
                }
            }
            .map(\.0)
    }

    private func persist() {
        let keep = episodes.count > persistMax ? Array(episodes.prefix(persistMax)) : episodes
        AppSupport.save("inbox.json", keep, excludeFromBackup: true)
    }
}
