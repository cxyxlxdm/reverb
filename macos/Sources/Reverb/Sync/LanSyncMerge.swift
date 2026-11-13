import Foundation

/// 同步用的合并策略 = **备份 v1 的合并语义 + 一道订阅去重**。
///
/// 为什么不另发明一套数据结构:备份 v1 的六个分区本来就在四端之间互通,且 `BackupManager.apply`
/// 里已经有冲突解法的成文规则(历史按 `updatedAt` 取新、收听统计按设备取 max)。
/// 同步传的就是同一份 JSON —— 少一套格式,就少一处"两端对同一件事有两套理解"。
///
/// 唯一补的一步:`BackupManager` 的订阅去重按 **Podcast.id**,而同一个 RSS 源从 Apple 目录加进来
/// 时 id 是 `collectionId`、从 OPML/RSS 直接加进来时 id 是 `feedUrl`。两边各自加过这个频道时,
/// id 不同但其实是同一个源 —— 不先去重,一次同步就会出现两条一模一样的频道。所以这里按
/// **feedUrl** 先挡一遍(本地已有的优先保留,远端同源的条目丢弃),再交给 `apply`。
///
/// **删除会传播**:快照里另带一段 `tombstones`(见 `LanSyncTombstones`),四个可删除的集合
/// (订阅 / 收藏 / 印章 / 批注)删除后保留 90 天。合并时先把两边墓碑并起来,再:
///  ① 删掉本端还被墓碑指着的条目;② 把远端快照里同 id 的条目剔掉;③ 才交给 `apply` 取并集。
///
/// 已知边界:墓碑**优先于**对端快照里的同 id 条目 —— 订阅与收藏没有 `updatedAt`,
/// 无法证明"重新添加"比"删除"更晚。彻底解决要 HLC,见研究文档 §5。
@MainActor
enum LanSyncMerge {
    static let sections: Set<BackupManager.Section> = [
        .subscriptions, .favorites, .stamps, .notes, .history, .listenStats
    ]

    /// 本端参与同步的分区快照(下载与设置**不在其中**:下载是这台设备的选择,设置是这台设备的偏好)。
    static func build(_ env: AppEnvironment) -> String {
        let base = BackupManager.build(env, sections)
        guard let data = base.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return base
        }
        // 全量快照必须带墓碑:对端拿这份恢复/合并时,没有墓碑就仍会把旧条目带回来。
        root["tombstones"] = LanSyncTombstones.snapshot()
        guard let out = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: out, encoding: .utf8) else { return base }
        return text
    }

    /// 把远端快照并入本端,返回**各分区新增的条数**。
    ///
    /// 新增数按"合并前后集合大小之差"算,不是按远端条数算 —— 远端带 100 条而本端已有 90 条时,
    /// 界面上写"新增 100"就是在说假话。
    static func apply(_ env: AppEnvironment, remoteJson: String) throws -> [Int] {
        guard let data = remoteJson.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanSyncException(.protocolProblem, "远端快照不是合法 JSON")
        }
        // ① 两边墓碑取并集(同时也把过期的剪掉)。
        LanSyncTombstones.merge(root["tombstones"])
        let deadSubs = LanSyncTombstones.ids(LanSyncTombstones.subscriptions)
        let deadFavs = LanSyncTombstones.ids(LanSyncTombstones.favorites)
        let deadStamps = LanSyncTombstones.ids(LanSyncTombstones.stamps)
        let deadNotes = LanSyncTombstones.ids(LanSyncTombstones.notes)

        // ② 本端还被墓碑指着的条目先删掉(可能是早先同步留下的"复活",在这次同步里对上)。
        pruneLocal(env, deadSubs: deadSubs, deadFavs: deadFavs,
                   deadStamps: deadStamps, deadNotes: deadNotes)

        // ③ 远端快照里同 id 的条目剔掉,剩下的才参与并集。
        filter(&root, "subscriptions", deadSubs) { o in
            LanSyncTombstones.subscriptionKey(feedUrl: o["feedUrl"] as? String ?? "",
                                              id: o["id"] as? String ?? "")
        }
        filter(&root, "favorites", deadFavs) { $0["id"] as? String }
        filter(&root, "stamps", deadStamps) { $0["episodeId"] as? String }
        filter(&root, "notes", deadNotes) { $0["noteId"] as? String }

        guard let filtered = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: filtered, encoding: .utf8) else {
            throw LanSyncException(.protocolProblem, "远端快照无法重新编码")
        }
        // 新增数从"删掉本地复活条目之后"起算,否则会报一个负数再被夹成 0。
        let before = counts(env)
        let prepared = try dedupeSubscriptions(env, text)
        BackupManager.apply(env, prepared, sections)
        let after = counts(env)
        return zip(before, after).map { max(0, $1 - $0) }
    }

    /// 删掉本端仍存在、但两边墓碑已经判死的条目。
    /// 走各 store 自己的删除入口 —— 它们会顺手把墓碑补记一次(同 kind/id),不会丢信息。
    private static func pruneLocal(
        _ env: AppEnvironment,
        deadSubs: Set<String>,
        deadFavs: Set<String>,
        deadStamps: Set<String>,
        deadNotes: Set<String>
    ) {
        if !deadSubs.isEmpty {
            let victims = env.subscriptions.subscriptions.filter {
                deadSubs.contains(LanSyncTombstones.subscriptionKey(feedUrl: $0.feedUrl, id: $0.id))
            }
            for p in victims { env.subscriptions.toggle(p) }
        }
        if !deadFavs.isEmpty {
            let victims = env.favorites.favorites.filter { deadFavs.contains($0.id) }
            for e in victims { env.favorites.toggle(e) }
        }
        if !deadStamps.isEmpty {
            for id in env.stamps.stamps.map(\.episodeId) where deadStamps.contains(id) {
                env.stamps.remove(id)
            }
        }
        if !deadNotes.isEmpty {
            for id in env.notes.notes.map(\.noteId) where deadNotes.contains(id) {
                env.notes.remove(id)
            }
        }
    }

    /// 只保留"墓碑没判死"的条目;剔空了就整段删掉(与 dedupe 的空段处理一致)。
    private static func filter(
        _ root: inout [String: Any],
        _ name: String,
        _ dead: Set<String>,
        key: ([String: Any]) -> String?
    ) {
        guard !dead.isEmpty, let arr = root[name] as? [[String: Any]] else { return }
        let kept = arr.filter { o in
            guard let k = key(o) else { return true }
            return !dead.contains(k)
        }
        if kept.isEmpty { root.removeValue(forKey: name) } else { root[name] = kept }
    }

    static func counts(_ env: AppEnvironment) -> [Int] {
        [
            env.subscriptions.subscriptions.count,
            env.favorites.favorites.count,
            env.stamps.stamps.count,
            env.notes.notes.count,
            env.history.history.count,
            env.listenStats.snapshot().count
        ]
    }

    /// 订阅按 feedUrl 去重。远端 JSON 里**只保留本端没有的源**,以及远端自身第一次出现的源。
    /// 其余分区原样带回 —— 这一步只解决"A 端用 collectionId、B 端用 feedUrl"这一种重复。
    private static func dedupeSubscriptions(_ env: AppEnvironment, _ json: String) throws -> String {
        guard let data = json.data(using: .utf8) else {
            throw LanSyncException(.protocolProblem, "远端快照不是合法 JSON")
        }
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanSyncException(.protocolProblem, "远端快照不是合法 JSON")
        }
        guard let arr = root["subscriptions"] as? [[String: Any]] else {
            // 没有订阅分区(或形状不是数组):原样带回。BackupManager.apply 自己会忽略解不出的分区。
            return json
        }
        var seen = Set<String>()
        for p in env.subscriptions.subscriptions {
            if let key = normalize(p.feedUrl) { seen.insert(key) }
        }
        var kept: [[String: Any]] = []
        for o in arr {
            let feed = normalize(o["feedUrl"] as? String ?? "")
            if let feed, !seen.insert(feed).inserted { continue }
            kept.append(o)
        }
        if kept.isEmpty { root.removeValue(forKey: "subscriptions") } else { root["subscriptions"] = kept }
        guard let out = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: out, encoding: .utf8) else {
            throw LanSyncException(.protocolProblem, "远端快照无法重新编码")
        }
        return text
    }

    /// 认源不认写法。实现只留一份在 `LanSyncTombstones`(墓碑键与去重键必须是同一个判据)。
    static func normalize(_ feedUrl: String) -> String? {
        LanSyncTombstones.normalizeFeed(feedUrl)
    }
}
