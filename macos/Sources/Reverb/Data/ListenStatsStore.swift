import Foundation

/// 按频道累计"实际播放过的内容时长"。播放时由 PlayerController 逐 tick 增量喂入,
/// 内存累加、约每 5s 节流落盘并刷新 @Published(避免高频重渲)。
/// 持久化:~/Library/Application Support/Reverb/listen_stats.json。
///
/// 时长按**设备分账**(见 ChannelListen.perDevice):本机只累加自己名下那格,
/// 展示值为各设备之和;备份恢复按设备取 max 合并,故重复恢复不会重复统计。
@MainActor final class ListenStatsStore: ObservableObject {

    /// 已按累计时长降序排列,供页面直接渲染横条。
    @Published private(set) var stats: [ChannelListen] = []

    /// 本机安装标识(首次生成后固定),用于分账。
    let deviceId: String

    private var table: [String: ChannelListen] = [:]
    private var pendingMs = 0            // 距上次落盘累计的增量
    private let flushThresholdMs = 5000  // 累计满 ~5s 才落盘一次

    init() {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: "device_id"), !existing.isEmpty {
            deviceId = existing
        } else {
            let generated = UUID().uuidString
            d.set(generated, forKey: "device_id")
            deviceId = generated
        }

        let loaded = AppSupport.load("listen_stats.json", as: [ChannelListen].self) ?? []
        var migrated = false
        for var c in loaded {
            // 旧格式(扁平 listenedMs)迁移:既有时长归入本机名下
            if c.perDevice.isEmpty && c.legacyFlatMs > 0 {
                c.perDevice = [deviceId: c.legacyFlatMs]
                migrated = true
            }
            table[c.key] = c
        }
        publish()
        if migrated { persist() }
        Log.i("Store", "收听时长加载 \(table.count) 个频道 device=\(deviceId.prefix(8)) 迁移=\(migrated)")
    }

    /// 频道键:feedUrl 非空优先,否则频道名。
    static func key(for e: Episode) -> String {
        e.feedUrl.isEmpty ? e.podcastTitle : e.feedUrl
    }

    /// 查询某频道累计毫秒(各设备之和;用于频道主页头部)。
    func listenedMs(for key: String) -> Int { table[key]?.listenedMs ?? 0 }

    /// 累加一段实际播放的内容毫秒到本机名下(delta 已由调用方校验为正且合理)。
    func add(episode e: Episode, deltaMs: Int) {
        guard deltaMs > 0 else { return }
        let k = Self.key(for: e)
        var cur = table[k] ?? ChannelListen(key: k, title: e.podcastTitle,
                                            artworkUrl: e.artworkUrl, feedUrl: e.feedUrl)
        cur.perDevice[deviceId, default: 0] += deltaMs
        // 保持展示信息为最新一次所见(封面/标题可能更新)
        if !e.podcastTitle.isEmpty { cur.title = e.podcastTitle }
        if !e.artworkUrl.isEmpty { cur.artworkUrl = e.artworkUrl }
        table[k] = cur
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

    /// 供备份导出的快照。
    func snapshot() -> [ChannelListen] { Array(table.values) }

    /// 备份恢复合并:**按设备取 max**(而非相加)。
    /// 同一份备份重复恢复得到同样结果(幂等);不同设备的分账相加,故跨设备恢复自然汇总。
    func merge(_ incoming: [ChannelListen]) {
        guard !incoming.isEmpty else { return }
        for var inc in incoming {
            // 旧格式来源:扁平时长按「来源设备未知」归入一个稳定的伪设备键,避免与本机相加出错
            if inc.perDevice.isEmpty && inc.legacyFlatMs > 0 {
                inc.perDevice = ["legacy:\(inc.key)": inc.legacyFlatMs]
            }
            guard !inc.perDevice.isEmpty else { continue }
            if var cur = table[inc.key] {
                for (dev, ms) in inc.perDevice {
                    cur.perDevice[dev] = max(cur.perDevice[dev] ?? 0, ms)
                }
                if cur.title.isEmpty { cur.title = inc.title }
                if cur.artworkUrl.isEmpty { cur.artworkUrl = inc.artworkUrl }
                if cur.feedUrl.isEmpty { cur.feedUrl = inc.feedUrl }
                table[inc.key] = cur
            } else {
                table[inc.key] = inc
            }
        }
        Log.i("Store", "收听时长合并 \(incoming.count) 个频道(按设备取 max)")
        persist()
        publish()
    }

    /// 首启种子:无既有统计时,用现有历史(每集 played?durationMs:positionMs)
    /// 按频道求和做近似初值,记在本机名下;此后按实际播放精确累加。
    func seedFromHistory(_ history: [HistoryEntry]) {
        guard table.isEmpty else { return }
        guard !history.isEmpty else { return }
        for h in history {
            let ms = h.played ? max(h.durationMs, h.positionMs) : h.positionMs
            guard ms > 0 else { continue }
            let k = Self.key(for: h.episode)
            var cur = table[k] ?? ChannelListen(key: k, title: h.episode.podcastTitle,
                                                artworkUrl: h.episode.artworkUrl,
                                                feedUrl: h.episode.feedUrl)
            cur.perDevice[deviceId, default: 0] += ms
            table[k] = cur
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
