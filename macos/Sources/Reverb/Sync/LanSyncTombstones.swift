import Foundation

/// 删除墓碑账本(iOS / macOS 共用):让「这台设备上删掉的条目」不会在下一次同步时被对端带回来。
///
/// 与 Android `sync/SyncTombstones.kt` 是同一份契约,两边必须逐字段对齐:
///  - 文件:`~/Library/Application Support/Reverb/sync_tombstones.json`
///    (`{"version":1,"items":[{"kind":…,"id":…,"deletedAt":毫秒}]}`),不进任何备份;
///  - kind 只有四个:`subscriptions` / `favorites` / `stamps` / `notes`
///    —— 历史是 LWW、收听统计按设备取 max,本来就没有"删一条"的语义;
///  - 订阅的 id 用 **feedUrl 归一化**后的串(与同步去重同一个判据);
///  - 保留 90 天;本地重新添加同一项时清掉墓碑;
///  - 全量快照里带 `tombstones` 一段,合并时两边按 key 取较晚的 `deletedAt` 再剪过期。
///
/// 已知边界(与 Android 同一条):墓碑**优先于**对端快照里的同 id 条目。订阅与收藏没有
/// `updatedAt`,无法证明"重新添加"比"删除"更晚;彻底解决要 HLC,见研究文档 §5。
@MainActor
enum LanSyncTombstones {
    static let subscriptions = "subscriptions"
    static let favorites = "favorites"
    static let stamps = "stamps"
    static let notes = "notes"

    private static let fileName = "sync_tombstones.json"
    private static let retentionMs: Double = 90 * 24 * 60 * 60 * 1000
    private static let separator = "\u{0}"

    private struct Entry: Codable {
        let kind: String
        let id: String
        let deletedAt: Double
    }

    private struct Ledger: Codable {
        var version: Int
        var items: [Entry]
    }

    /// key = kind + SEP + id,value = deletedAt(毫秒)。
    private static var entries: [String: Double]? = nil

    // MARK: - 记录 / 清除

    static func record(_ kind: String, _ id: String, at now: Double = Self.nowMs()) {
        guard !kind.isEmpty, !id.isEmpty else { return }
        var map = load()
        prune(&map, now: now)
        map[key(kind, id)] = now
        store(map)
    }

    /// 本地重新添加时调用:墓碑清掉,否则下一次同步会把这项再删一次。
    static func clear(_ kind: String, _ id: String) {
        guard !kind.isEmpty, !id.isEmpty else { return }
        var map = load()
        if map.removeValue(forKey: key(kind, id)) != nil { store(map) }
    }

    // MARK: - 合并 / 读出

    /// 并入远端快照里的 `tombstones`(可以没有),剪掉过期项并落盘。
    /// 返回后 `ids(kind)` 就是"两边合起来仍然有效的删除"。
    static func merge(_ remote: Any?, now: Double = Self.nowMs()) {
        var map = load()
        if let arr = remote as? [[String: Any]] {
            for o in arr {
                guard let kind = o["kind"] as? String, !kind.isEmpty,
                      let id = o["id"] as? String, !id.isEmpty else { continue }
                let at = (o["deletedAt"] as? NSNumber)?.doubleValue ?? 0
                guard at > 0 else { continue }
                let k = key(kind, id)
                if let prev = map[k], prev >= at { continue }
                map[k] = at
            }
        }
        prune(&map, now: now)
        store(map)
    }

    static func ids(_ kind: String, now: Double = Self.nowMs()) -> Set<String> {
        var map = load()
        prune(&map, now: now)
        var out = Set<String>()
        for k in map.keys {
            guard let (k2, id) = decode(k), k2 == kind else { continue }
            out.insert(id)
        }
        return out
    }

    /// 快照里要带的那一段。空账本也返回空数组 —— 形状固定,对端不必判空。
    static func snapshot(now: Double = Self.nowMs()) -> [[String: Any]] {
        var map = load()
        prune(&map, now: now)
        return map.compactMap { k, at in
            guard let (kind, id) = decode(k) else { return nil }
            return ["kind": kind, "id": id, "deletedAt": at]
        }
    }

    // MARK: - 键

    /// 订阅的墓碑键:`feedUrl` 归一化优先,没有可用 URL 时退回频道 id(与同步去重同一判据)。
    static func subscriptionKey(feedUrl: String, id: String) -> String {
        normalizeFeed(feedUrl) ?? id
    }

    /// 认源不认写法:尾部斜杠与**协议/主机名**大小写不该让同一个源变成两条。
    /// 路径部分大小写敏感,不能一起小写。与 `LanSyncMerge` / Android 端逐条一致。
    static func normalizeFeed(_ feedUrl: String) -> String? {
        var s = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasSuffix("/") { s.removeLast() }
        guard let sep = s.range(of: "://") else { return s }
        let scheme = s[..<sep.lowerBound].lowercased()
        let rest = s[sep.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = rest[..<end].lowercased()
        return scheme + "://" + authority + rest[end...]
    }

    // MARK: - 私有

    /// `nonisolated`:`record/merge/ids/snapshot` 的默认参数在**调用侧**求值,
    /// 编译器按非隔离上下文判它,标成主线程隔离就直接编译不过(2026-11-12 首跑)。
    nonisolated private static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    private static func key(_ kind: String, _ id: String) -> String { kind + separator + id }

    private static func decode(_ k: String) -> (String, String)? {
        guard let i = k.firstIndex(of: Character(separator)) else { return nil }
        let kind = String(k[..<i])
        let id = String(k[k.index(after: i)...])
        guard !kind.isEmpty, !id.isEmpty else { return nil }
        return (kind, id)
    }

    private static func prune(_ map: inout [String: Double], now: Double) {
        let cutoff = now - retentionMs
        map = map.filter { $0.value >= cutoff }
    }

    private static func load() -> [String: Double] {
        if let entries { return entries }
        var map: [String: Double] = [:]
        let url = AppSupport.dir.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url),
           let ledger = try? JSONDecoder().decode(Ledger.self, from: data) {
            for e in ledger.items where !e.kind.isEmpty && !e.id.isEmpty {
                map[key(e.kind, e.id)] = e.deletedAt
            }
        }
        // 读不到/读坏了都按空处理:账本是派生数据,最坏结果是这一次同步可能复活一条已删项。
        entries = map
        return map
    }

    private static func store(_ map: [String: Double]) {
        entries = map
        let items = map.compactMap { k, at -> Entry? in
            guard let (kind, id) = decode(k) else { return nil }
            return Entry(kind: kind, id: id, deletedAt: at)
        }
        let url = AppSupport.dir.appendingPathComponent(fileName)
        guard let data = try? JSONEncoder().encode(Ledger(version: 1, items: items)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
