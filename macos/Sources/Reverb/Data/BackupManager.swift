import Foundation

/// 备份 / 恢复(合并语义)+ OPML 导入导出。
enum BackupManager {
    /// 可备份的数据分区。
    ///
    /// **顺序与 Android `BackupManager.Section` / 鸿蒙那份一一对应**(notes 都紧跟 stamps):
    /// 恢复弹窗按这个顺序列勾选框,两端同一份 `reverb-backup.json` 时用户看到的次序才一致。
    enum Section: String, CaseIterable, Identifiable {
        case subscriptions, favorites, stamps, notes, downloads, history, listenStats, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .subscriptions: return "订阅"
            case .favorites: return "收藏"
            case .stamps: return "听觉印记"
            case .notes: return "批注"
            case .downloads: return "下载"
            case .history: return "历史"
            case .listenStats: return "收听时长"
            case .settings: return "设置"
            }
        }
    }

    // MARK: - 序列化载荷

    /// 各字段全部可选:备份 JSON 是跨端边界,三端 settings 的 schema 各有增删
    /// (Android 带 allowCellularDownload/updatesEnabled/categoryOrder,
    ///  鸿蒙带 fontIndex/language/subsGrid,macOS 带 regionOverride/contextualRadio),
    /// 且旧版导出可能缺键 —— 任何一个非可选键缺失都会让**整份备份**解码失败
    /// (H86),恢复就静默无效。缺的键在 applySettings 里保持现值不动。
    private struct SettingsPayload: Codable {
        var themeMode: Int?
        var accentIndex: Int?
        var fontScale: Double?
        var regionOverride: String?
        var defaultSpeed: Double?
        var skipBackSec: Int?
        var skipForwardSec: Int?
        var contextualRadio: Bool?
    }

    private struct Payload: Codable {
        var version: Int = 1
        var subscriptions: [Podcast]?
        var favorites: [Episode]?
        var stamps: [Stamp]?
        var notes: [EpisodeNote]?
        var downloads: [Episode]?   // 仅保存单集元信息,恢复时重新下载
        var history: [HistoryEntry]?
        var listenStats: [ChannelListen]?   // 按设备分账,恢复时按设备取 max(幂等)
        var settings: SettingsPayload?
    }

    // MARK: - 构建 / 探测

    @MainActor
    static func build(_ env: AppEnvironment, _ include: Set<Section>) -> String {
        var p = Payload()
        if include.contains(.subscriptions) { p.subscriptions = env.subscriptions.subscriptions }
        if include.contains(.favorites) { p.favorites = env.favorites.favorites }
        if include.contains(.stamps) { p.stamps = env.stamps.stamps }
        if include.contains(.notes) { p.notes = env.notes.notes }
        if include.contains(.downloads) { p.downloads = env.downloads.downloads.map { $0.episode } }
        if include.contains(.history) { p.history = env.history.history }
        if include.contains(.listenStats) { p.listenStats = env.listenStats.snapshot() }
        if include.contains(.settings) {
            let s = env.settings
            p.settings = SettingsPayload(
                themeMode: s.themeMode, accentIndex: s.accentIndex, fontScale: s.fontScale,
                regionOverride: s.regionOverride, defaultSpeed: s.defaultSpeed,
                skipBackSec: s.skipBackSec, skipForwardSec: s.skipForwardSec,
                contextualRadio: s.contextualRadio)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(p), let str = String(data: data, encoding: .utf8) else {
            Log.e("Backup", "导出编码失败")
            return "{}"
        }
        Log.i("Backup", "导出备份 分区=[\(include.map { $0.rawValue }.sorted().joined(separator: ","))] 订阅=\(p.subscriptions?.count ?? 0) 收藏=\(p.favorites?.count ?? 0) 印记=\(p.stamps?.count ?? 0) 批注=\(p.notes?.count ?? 0) 下载=\(p.downloads?.count ?? 0) 历史=\(p.history?.count ?? 0)")
        return str
    }

    /// 探测备份 JSON 中含有哪些非空分区。
    static func sectionsIn(_ json: String) -> Set<Section> {
        guard let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        var s = Set<Section>()
        if let v = p.subscriptions, !v.isEmpty { s.insert(.subscriptions) }
        if let v = p.favorites, !v.isEmpty { s.insert(.favorites) }
        if let v = p.stamps, !v.isEmpty { s.insert(.stamps) }
        if let v = p.notes, !v.isEmpty { s.insert(.notes) }
        if let v = p.downloads, !v.isEmpty { s.insert(.downloads) }
        if let v = p.history, !v.isEmpty { s.insert(.history) }
        if let v = p.listenStats, !v.isEmpty { s.insert(.listenStats) }
        if p.settings != nil { s.insert(.settings) }
        return s
    }

    // MARK: - 应用(合并,不覆盖)

    @MainActor
    static func apply(_ env: AppEnvironment, _ json: String, _ include: Set<Section>) {
        guard let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else {
            Log.e("Backup", "恢复解析失败")
            return
        }
        Log.i("Backup", "恢复备份 分区=[\(include.map { $0.rawValue }.sorted().joined(separator: ","))]")
        if include.contains(.subscriptions), let v = p.subscriptions { Log.i("Backup", "恢复订阅 \(v.count) 条"); env.subscriptions.addAll(v) }
        if include.contains(.favorites), let v = p.favorites { Log.i("Backup", "恢复收藏 \(v.count) 条"); env.favorites.addAll(v) }
        if include.contains(.stamps), let v = p.stamps { Log.i("Backup", "恢复印记 \(v.count) 条"); env.stamps.addAll(v) }
        if include.contains(.notes), let v = p.notes { Log.i("Backup", "恢复批注 \(v.count) 条"); env.notes.addAll(v) }
        if include.contains(.downloads), let v = p.downloads {
            let toDownload = v.filter { !env.downloads.contains($0.id) }
            Log.i("Backup", "恢复下载 需重新下载 \(toDownload.count) 集")
            for ep in toDownload { env.downloadManager.download(ep) }
        }
        if include.contains(.history), let v = p.history { Log.i("Backup", "恢复历史 \(v.count) 条"); mergeHistory(env, v) }
        if include.contains(.listenStats), let v = p.listenStats {
            Log.i("Backup", "恢复收听时长 \(v.count) 个频道")
            env.listenStats.merge(v)
        }
        if include.contains(.settings), let s = p.settings { Log.i("Backup", "恢复设置"); applySettings(env, s) }
    }

    /// 历史合并:同集冲突保留 updatedAt 更新者,不回退进度。
    @MainActor
    private static func mergeHistory(_ env: AppEnvironment, _ incoming: [HistoryEntry]) {
        // 从旧到新处理,使最近更新的条目最终置顶。
        for entry in incoming.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let existing = env.history.history.first { $0.episode.id == entry.episode.id }
            if let existing, entry.updatedAt <= existing.updatedAt { continue }
            env.history.record(entry.episode, at: entry.updatedAt)
            env.history.updatePosition(entry.episode.id, positionMs: entry.positionMs, durationMs: entry.durationMs)
            // record() 会把 played 重置为 false,备份里带 true 的要补回(H86)
            if entry.played { env.history.markPlayed(entry.episode.id, true) }
        }
    }

    @MainActor
    private static func applySettings(_ env: AppEnvironment, _ s: SettingsPayload) {
        let st = env.settings
        if let v = s.themeMode { st.themeMode = v }
        if let v = s.accentIndex { st.accentIndex = v }
        if let v = s.fontScale { st.fontScale = v }
        if let v = s.regionOverride { st.regionOverride = v }
        if let v = s.defaultSpeed {
            st.defaultSpeed = v
            env.player.setSpeed(v)
        }
        if let v = s.skipBackSec { st.skipBackSec = v }
        if let v = s.skipForwardSec { st.skipForwardSec = v }
        if let v = s.contextualRadio { st.contextualRadio = v }
        // 日志拼平写,别在插值里叠 .map(String.init):Swift 类型检查器会被嵌套可选表达式噎死(H86)
        let restored = "theme=\(s.themeMode ?? -1) speed=\(s.defaultSpeed ?? -1) region=\(s.regionOverride ?? "-")"
        Log.i("Backup", "恢复设置 \(restored)")
    }

    // MARK: - OPML

    @MainActor
    static func exportOPML(_ env: AppEnvironment) -> String {
        var body = ""
        for p in env.subscriptions.subscriptions {
            let title = xmlEscape(p.title)
            let feed = xmlEscape(p.feedUrl)
            body += "    <outline type=\"rss\" text=\"\(title)\" title=\"\(title)\" xmlUrl=\"\(feed)\"/>\n"
        }
        Log.i("Backup", "导出 OPML \(env.subscriptions.subscriptions.count) 个订阅")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>余音订阅</title></head>
          <body>
        \(body)  </body>
        </opml>
        """
    }

    @MainActor
    static func importOPML(_ env: AppEnvironment, _ xml: String) {
        guard let data = xml.data(using: .utf8) else {
            Log.e("Backup", "导入 OPML 编码失败")
            return
        }
        let collector = OPMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        let podcasts = collector.items.map {
            Podcast(id: $0.feedUrl, title: $0.text, author: "", artworkUrl: "", feedUrl: $0.feedUrl)
        }
        Log.i("Backup", "导入 OPML 解析到 \(podcasts.count) 个订阅")
        env.subscriptions.addAll(podcasts)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// OPML outline 收集器。同步解析,不触及主线程隔离状态。
private final class OPMLCollector: NSObject, XMLParserDelegate {
    struct Item { var text: String; var feedUrl: String }
    var items: [Item] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName == "outline" else { return }
        let xmlUrl = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"] ?? ""
        guard !xmlUrl.isEmpty else { return }
        let text = attributeDict["text"] ?? attributeDict["title"] ?? xmlUrl
        items.append(Item(text: text, feedUrl: xmlUrl))
    }
}
