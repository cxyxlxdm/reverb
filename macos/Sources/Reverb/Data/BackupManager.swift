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

    // MARK: - 字号换算(跨端备份的档位 ↔ 倍率)

    /// 四档字号**倍率**,与 Android `SettingsStore.FONT_SCALES` / 鸿蒙 `Theme.ets` 那组**逐项相同**。
    ///
    /// 桌面界面是连续滑杆(`UI/SettingsView.swift` 0.85–1.3 step 0.05),没有"档位"这个概念 ——
    /// 这张表只在备份边界上用(D2):导出时把滑杆值就近折成下标写给旧鸿蒙,恢复时把下标换回倍率。
    /// **就近取整的方向必须与 Android 的同名函数一致**(严格小于才替换,平局取靠前那档),
    /// 否则同一个滑杆值在两端会落到相邻两档,而两边都不会报错。
    private static let fontScales: [Double] = [0.85, 1.0, 1.15, 1.3]

    private static func fontIndex(for scale: Double) -> Int {
        var best = 1
        var diff = Double.greatestFiniteMagnitude
        for (i, s) in fontScales.enumerated() {
            let d = abs(s - scale)
            if d < diff { diff = d; best = i }
        }
        return best
    }

    /// 下标 → 倍率,越界夹到端点(备份是外部输入,不能信任它的范围)。
    private static func fontScale(forIndex index: Int) -> Double {
        fontScales[min(max(index, 0), fontScales.count - 1)]
    }

    // MARK: - 序列化载荷

    /// 各字段全部可选:备份 JSON 是跨端边界,三端 settings 的 schema 各有增删
    /// (Android 带 allowCellularDownload/updatesEnabled/categoryOrder,
    ///  鸿蒙带 fontIndex/language/subsGrid,macOS 带 fontIndex/regionOverride/contextualRadio),
    /// 且旧版导出可能缺键 —— 任何一个非可选键缺失都会让**整份备份**解码失败
    /// (H86),恢复就静默无效。缺的键在 applySettings 里保持现值不动。
    private struct SettingsPayload: Codable {
        var themeMode: Int?
        var accentIndex: Int?
        var fontScale: Double?
        /// 字号档位下标。**桌面没有"档位"这个界面概念**(它是连续滑杆),这一格纯为跨端(D2):
        /// 导出时把滑杆值就近折成下标给只认它的旧鸿蒙,恢复时作为 `fontScale` 缺失后的兜底。
        /// 两端都写、读时倍率优先 —— 与 Android `BackupManager.kt` 同一套次序。
        var fontIndex: Int?
        var regionOverride: String?
        var defaultSpeed: Double?
        var skipBackSec: Int?
        var skipForwardSec: Int?
        var contextualRadio: Bool?
        /// 两格"桌面没有对应功能"的键(M3)。带它们不是为了在 Mac 上生效,
        /// 而是为了让「手机 → Mac → 手机」这条路不把手机那侧的设置抹掉 ——
        /// 缺了它们的后果是:用户在手机上没动过的开关,绕一趟 Mac 回来就变了,
        /// 而三端都会说"我是从备份里读的"。语义与取舍见 `Stores.swift` `SettingsStore` 同段注释。
        /// `categoryOrder` 不在这一档:1.0.6 起本端也有排序界面,它是**真的读写**(见 M12)。
        var allowCellularDownload: Bool?
        var updatesEnabled: Bool?
        var categoryOrder: [String]?
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
                themeMode: s.themeMode, accentIndex: s.accentIndex,
                fontScale: s.fontScale, fontIndex: Self.fontIndex(for: s.fontScale),
                regionOverride: s.regionOverride, defaultSpeed: s.defaultSpeed,
                skipBackSec: s.skipBackSec, skipForwardSec: s.skipForwardSec,
                contextualRadio: s.contextualRadio,
                allowCellularDownload: s.allowCellularDownload,
                updatesEnabled: s.updatesEnabled,
                categoryOrder: s.categoryOrder)
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
        // 字号:**优先 `fontScale`(倍率,跨端契约键),读不到才退 `fontIndex`(下标)**。
        // 先后与 Android `BackupManager.kt` 同一条理由:新版两端导出的备份两个键都写,
        // 且由同一个值派生,正常情况下取哪个都一样;但手改过、或只改了另一侧那一格的备份里
        // 两者可能不一致,必须有一个确定性的胜出者,否则同一份文件在两台机器上恢复出两档字号。
        if let v = s.fontScale {
            st.fontScale = v
        } else if let v = s.fontIndex {
            st.fontScale = Self.fontScale(forIndex: v)
        }
        if let v = s.regionOverride { st.regionOverride = v }
        if let v = s.defaultSpeed {
            st.defaultSpeed = v
            env.player.setSpeed(v)
        }
        if let v = s.skipBackSec { st.skipBackSec = v }
        if let v = s.skipForwardSec { st.skipForwardSec = v }
        if let v = s.contextualRadio { st.contextualRadio = v }
        // 只存不生效的两格:本端读进来是为了下次导出原样写回去(见 SettingsPayload 注释)。
        if let v = s.allowCellularDownload { st.allowCellularDownload = v }
        if let v = s.updatesEnabled { st.updatesEnabled = v }
        // 分类顺序**空数组不覆盖**:空表示"那份备份从没排过",不是"恢复默认序"
        // (Android `saveOrder` 的早退、鸿蒙 `CategoryStore.save` 同一条)。
        // 少了这个 guard,拿一台没排过序的手机备份恢复,会静默抹掉本机排好的顺序。
        if let v = s.categoryOrder, !v.isEmpty { st.categoryOrder = v }
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
