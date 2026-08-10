import Foundation

/// 按频道累计"实际播放过的内容时长"。播放时由 PlayerController 逐 tick 增量喂入,
/// 内存累加、约每 5s 节流落盘并刷新 @Published(避免高频重渲)。
/// 持久化:~/Library/Application Support/Reverb/listen_stats.json。
@MainActor final class ListenStatsStore: ObservableObject {

    /// 已按累计时长降序排列,供页面直接渲染横条。
    @Published private(set) var stats: [ChannelListen] = []

    private var table: [String: ChannelListen] = [:]
    private var pendingMs = 0            // 距上次落盘累计的增量
    private let flushThresholdMs = 5000  // 累计满 ~5s 才落盘一次

    init() {
        let loaded = AppSupport.load("listen_stats.json", as: [ChannelListen].self) ?? []
        for c in loaded { table[c.key] = c }
        publish()
        Log.i("Store", "收听时长加载 \(table.count) 个频道")
    }

    /// 频道键:feedUrl 非空优先,否则频道名。
    static func key(for e: Episode) -> String {
        e.feedUrl.isEmpty ? e.podcastTitle : e.feedUrl
    }

    /// 查询某频道累计毫秒(用于频道主页头部)。
    func listenedMs(for key: String) -> Int { table[key]?.listenedMs ?? 0 }

    /// 累加一段实际播放的内容毫秒(delta 已由调用方校验为正且合理)。
    func add(episode e: Episode, deltaMs: Int) {
        guard deltaMs > 0 else { return }
        let k = Self.key(for: e)
        if var cur = table[k] {
            cur.listenedMs += deltaMs
            // 保持展示信息为最新一次所见(封面/标题可能更新)
            cur.title = e.podcastTitle.isEmpty ? cur.title : e.podcastTitle
            cur.artworkUrl = e.artworkUrl.isEmpty ? cur.artworkUrl : e.artworkUrl
            table[k] = cur
        } else {
            table[k] = ChannelListen(key: k, title: e.podcastTitle, artworkUrl: e.artworkUrl,
                                     feedUrl: e.feedUrl, listenedMs: deltaMs)
        }
        pendingMs += deltaMs
        if pendingMs >= flushThresholdMs { flush() }
    }

    /// 立即落盘并刷新 @Published(暂停/播完/切集时调用)。
    func flush() {
        guard pendingMs > 0 else { return }
        pendingMs = 0
        persist()
        publish()
    }

    /// 首启种子:listen_stats.json 不存在时,用现有历史(每集 played?durationMs:positionMs)
    /// 按频道求和做近似初值,避免老用户全为 0;此后按实际播放精确累加。
    func seedFromHistory(_ history: [HistoryEntry]) {
        guard table.isEmpty else { return }
        guard !history.isEmpty else { return }
        for h in history {
            let ms = h.played ? max(h.durationMs, h.positionMs) : h.positionMs
            guard ms > 0 else { continue }
            let k = Self.key(for: h.episode)
            if var cur = table[k] {
                cur.listenedMs += ms
                table[k] = cur
            } else {
                table[k] = ChannelListen(key: k, title: h.episode.podcastTitle,
                                         artworkUrl: h.episode.artworkUrl,
                                         feedUrl: h.episode.feedUrl, listenedMs: ms)
            }
        }
        Log.i("Store", "收听时长种子 \(table.count) 个频道")
        persist()
        publish()
    }

    private func publish() {
        stats = table.values.sorted { $0.listenedMs > $1.listenedMs }
    }
    private func persist() {
        AppSupport.save("listen_stats.json", Array(table.values))
    }
}
