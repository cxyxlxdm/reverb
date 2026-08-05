import Foundation

/// 「最新」收件箱:跨全部订阅合并的最新单集。持久化到 inbox.json 以便秒开,
/// 再异步刷新。与 Android 版行为对齐。
@MainActor final class InboxStore: ObservableObject {
    @Published private(set) var episodes: [Episode]
    @Published private(set) var refreshing = false

    private let maxCount = 100
    private let maxConcurrent = 6

    init() {
        episodes = AppSupport.load("inbox.json", as: [Episode].self) ?? []
        Log.i("Inbox", "最新加载 \(episodes.count) 条")
    }

    /// 并发(有界)拉取全部订阅源,合并去重、按发布时间倒序、截断 100,发布并持久化。
    func refresh(subscriptions: [Podcast], repository: PodcastRepository) async {
        guard !refreshing else { Log.d("Inbox", "刷新进行中,忽略重复请求"); return }
        let feeds = subscriptions.map { $0.feedUrl }.filter { !$0.isEmpty }
        guard !feeds.isEmpty else {
            Log.i("Inbox", "无订阅,清空最新")
            if !episodes.isEmpty { episodes = []; persist() }
            return
        }

        refreshing = true
        let t0 = Date()
        Log.i("Inbox", "刷新最新 订阅=\(feeds.count) 并发=\(maxConcurrent)")

        var collected: [Episode] = []
        let bound = maxConcurrent
        await withTaskGroup(of: [Episode].self) { group in
            var index = 0
            func addNext() {
                guard index < feeds.count else { return }
                let url = feeds[index]; index += 1
                group.addTask {
                    guard let r = await repository.feed(url) else { return [] }
                    return r.episodes
                }
            }
            for _ in 0..<min(bound, feeds.count) { addNext() }
            while let eps = await group.next() {
                collected.append(contentsOf: eps)
                addNext()
            }
        }

        // 去重(按 id 保留首次出现),再按发布时间倒序;无法解析日期者保持相对顺序垫底。
        var seen = Set<String>()
        let deduped = collected.filter { seen.insert($0.id).inserted }
        let indexed = deduped.enumerated().map { ($0.offset, $0.element, Fmt.parseDate($0.element.pubDate)) }
        let sorted = indexed.sorted { l, r in
            switch (l.2, r.2) {
            case let (a?, b?): return a != b ? a > b : l.0 < r.0
            case (_?, nil): return true
            case (nil, _?): return false
            default: return l.0 < r.0
            }
        }.map { $0.1 }

        episodes = Array(sorted.prefix(maxCount))
        refreshing = false
        persist()
        Log.i("Inbox", "刷新最新 → 收集 \(collected.count) 去重 \(deduped.count) 展示 \(episodes.count) \(Log.ms(t0))")
    }

    private func persist() { AppSupport.save("inbox.json", episodes) }
}
