import Foundation

/// 「最新」收件箱:跨全部订阅合并的最新单集。持久化到 inbox.json 以便秒开,
/// 再异步刷新。与 Android 版行为对齐。
///
/// 为提升「感知速度」,刷新采用:
/// - 每源限量:每个订阅只取该源最新 ~12 集,降低体量与内存;
/// - 增量渲染:每个源解析完成即合并进运行列表并即时发布,界面随源到达逐步填充,
///   而非等所有源都拉完再一次性刷新;
/// - 有界并发 + 每源超时,单源失败/超时不影响整体。
@MainActor final class InboxStore: ObservableObject {
    @Published private(set) var episodes: [Episode]
    @Published private(set) var refreshing = false

    /// 已成功刷新过的订阅集签名。用于避免每次切到「最新」分段都全量重刷:
    /// 只有签名变化(订阅增删)或手动刷新才重新拉取。
    private var loadedSignature: String?

    private let maxCount = 100
    private let maxConcurrent = 8
    private let perFeedCap = 12
    private let feedTimeoutSec: Double = 8

    init() {
        episodes = AppSupport.load("inbox.json", as: [Episode].self) ?? []
        Log.i("Inbox", "最新加载 \(episodes.count) 条")
    }

    /// 订阅集未变化时跳过刷新。供「最新」分段 .task 调用,避免切 tab 重复全量刷新。
    func refreshIfStale(subscriptions: [Podcast], repository: PodcastRepository) async {
        if loadedSignature == Self.signature(subscriptions) { return }
        await refresh(subscriptions: subscriptions, repository: repository)
    }

    /// 并发(有界)拉取全部订阅源。每个源只取最新 ~12 集,解析完成即增量合并
    /// (按 id 去重、按发布时间倒序、截断 100)并即时发布;全部完成后持久化。
    func refresh(subscriptions: [Podcast], repository: PodcastRepository) async {
        guard !refreshing else { Log.d("Inbox", "刷新进行中,忽略重复请求"); return }
        let feeds = subscriptions.map { $0.feedUrl }.filter { !$0.isEmpty }
        guard !feeds.isEmpty else {
            Log.i("Inbox", "无订阅,清空最新")
            if !episodes.isEmpty { episodes = []; persist() }
            loadedSignature = ""
            return
        }

        refreshing = true
        defer { refreshing = false }
        let t0 = Date()
        Log.i("Inbox", "刷新最新 订阅=\(feeds.count) 并发=\(maxConcurrent) 每源=\(perFeedCap)")

        // 运行列表:从空开始,按源到达增量合并。seen 用于跨源去重(保留首次出现)。
        // hasCache:已有缓存内容时,刷新期间不增量替换可见列表(否则会先坍缩再重建、产生跳动),
        // 仅在冷启动无缓存时才增量填充以提供进度反馈;有缓存则后台build完最终一次性替换。
        let hasCache = !episodes.isEmpty
        var merged: [Episode] = []
        var seen = Set<String>()
        var rawCount = 0

        let cap = perFeedCap
        let timeout = feedTimeoutSec
        await withTaskGroup(of: [Episode].self) { group in
            var index = 0
            func addNext() {
                guard index < feeds.count else { return }
                let url = feeds[index]; index += 1
                group.addTask {
                    await Self.loadCapped(url, repository: repository, cap: cap, timeoutSec: timeout)
                }
            }
            for _ in 0..<min(maxConcurrent, feeds.count) { addNext() }
            while let eps = await group.next() {
                rawCount += eps.count
                var added = false
                for e in eps where seen.insert(e.id).inserted {
                    merged.append(e); added = true
                }
                if added {
                    merged = Self.sortedByDateDesc(merged)
                    if merged.count > maxCount { merged.removeLast(merged.count - maxCount) }
                    if !hasCache {
                        let snapshot = merged
                        await MainActor.run { self.episodes = snapshot }   // 冷启动增量发布(主线程)
                    }
                }
                addNext()
            }
        }

        episodes = merged   // 最终一次性替换:靠 id diff,已有条目位置稳定,不跳动
        persist()
        loadedSignature = Self.signature(subscriptions)
        Log.i("Inbox", "刷新最新 → 收集 \(rawCount) 展示 \(episodes.count) \(Log.ms(t0))")
    }

    /// 订阅集签名:非空 feedUrl 排序后拼接,用于判断订阅集是否变化。
    private static func signature(_ subscriptions: [Podcast]) -> String {
        subscriptions.map { $0.feedUrl }.filter { !$0.isEmpty }.sorted().joined(separator: "|")
    }

    /// 拉取单个订阅源,带 ~timeoutSec 超时;成功后取该源最新 cap 集(按发布时间倒序)。
    /// 失败或超时返回空数组,不影响其他源。
    private static func loadCapped(_ url: String, repository: PodcastRepository,
                                   cap: Int, timeoutSec: Double) async -> [Episode] {
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
        // 每源限量:该源最新 ~cap 集。
        return Array(Self.sortedByDateDesc(episodes).prefix(cap))
    }

    /// 按发布时间倒序;无法解析日期者保持相对顺序垫底。
    private static func sortedByDateDesc(_ eps: [Episode]) -> [Episode] {
        let indexed = eps.enumerated().map { ($0.offset, $0.element, Fmt.parseDate($0.element.pubDate)) }
        return indexed.sorted { l, r in
            switch (l.2, r.2) {
            case let (a?, b?): return a != b ? a > b : l.0 < r.0
            case (_?, nil): return true
            case (nil, _?): return false
            default: return l.0 < r.0
            }
        }.map { $0.1 }
    }

    private func persist() { AppSupport.save("inbox.json", episodes) }
}
