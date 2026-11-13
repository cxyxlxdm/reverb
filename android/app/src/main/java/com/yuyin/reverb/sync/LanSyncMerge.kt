package com.yuyin.reverb.sync

import com.yuyin.reverb.AppContainer
import com.yuyin.reverb.data.local.BackupManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * 同步用的合并策略 = **备份 v1 的合并语义 + 一道订阅去重**。
 *
 * 为什么不另发明一套数据结构:备份 v1 的六个分区本来就在四端之间互通,且 `BackupManager.apply`
 * 里已经有冲突解法的成文规则(历史按 `updatedAt` 取新、收听统计按设备取 max)。
 * 同步传的就是同一份 JSON —— 少一套格式,就少一处"两端对同一件事有两套理解"。
 *
 * 唯一补的一步:`BackupManager` 的订阅去重按 **Podcast.id**,而同一个 RSS 源从 Apple 目录加进来
 * 时 id 是 `collectionId`、从 OPML/RSS 直接加进来时 id 是 `feedUrl`。两边各自加过这个频道时,
 * id 不同但其实是同一个源 —— 不先去重,一次同步就会出现两条一模一样的频道。所以这里按
 * **feedUrl** 先挡一遍(本地已有的优先保留,远端同源的条目丢弃),再交给 `apply`。
 *
 * **删除会传播**:快照里另带一段 `tombstones`(见 `SyncTombstones`),四个可删除的集合
 * (订阅 / 收藏 / 印章 / 批注)删除后保留 90 天。合并时先把两边墓碑并起来,再:
 *  ① 删掉本端还被墓碑指着的条目;② 把远端快照里同 id 的条目剔掉;③ 才交给 `apply` 取并集。
 *
 * 已知边界:墓碑**优先于**对端快照里的同 id 条目 —— 订阅与收藏没有 `updatedAt`,
 * 无法证明"重新添加"比"删除"更晚。彻底解决要 HLC,见研究文档 §5。
 */
object LanSyncMerge {

    val SECTIONS: Set<BackupManager.Section> = setOf(
        BackupManager.Section.SUBSCRIPTIONS,
        BackupManager.Section.FAVORITES,
        BackupManager.Section.STAMPS,
        BackupManager.Section.NOTES,
        BackupManager.Section.HISTORY,
        BackupManager.Section.LISTEN_STATS
    )

    /** 本端参与同步的分区快照(下载与设置**不在其中**:下载是这台设备的选择,设置是这台设备的偏好)。 */
    fun build(container: AppContainer): String {
        val base = BackupManager.build(container, SECTIONS)
        return try {
            // 全量快照必须带墓碑:对端拿这份恢复/合并时,没有墓碑就仍会把旧条目带回来。
            JSONObject(base).put("tombstones", SyncTombstones.snapshot()).toString()
        } catch (e: Exception) {
            base
        }
    }

    /**
     * 把远端快照并入本端,返回**各分区新增的条数**。
     *
     * 新增数按"合并前后集合大小之差"算,不是按远端条数算 —— 远端带 100 条而本端已有 90 条时,
     * 界面上写"新增 100"就是在说假话。
     */
    fun apply(container: AppContainer, remoteJson: String): IntArray {
        val root = runCatching { JSONObject(remoteJson) }.getOrElse {
            throw LanSyncException(LanSyncFail.PROTOCOL, "远端快照不是合法 JSON", it)
        }
        // ① 两边墓碑取并集(同时也把过期的剪掉)。
        SyncTombstones.merge(root.optJSONArray("tombstones"))
        val deadSubs = SyncTombstones.ids(SyncTombstones.SUBSCRIPTIONS)
        val deadFavs = SyncTombstones.ids(SyncTombstones.FAVORITES)
        val deadStamps = SyncTombstones.ids(SyncTombstones.STAMPS)
        val deadNotes = SyncTombstones.ids(SyncTombstones.NOTES)

        // ② 本端还被墓碑指着的条目先删掉(这可能是一次早先同步留下的"复活",在这次同步里对上)。
        pruneLocal(container, deadSubs, deadFavs, deadStamps, deadNotes)

        // ③ 远端快照里同 id 的条目剔掉,剩下的才参与并集。
        filterSection(root, "subscriptions", deadSubs) { o ->
            SyncTombstones.subscriptionKey(o.optString("feedUrl"), o.optString("id"))
        }
        filterSection(root, "favorites", deadFavs) { it.optString("id") }
        filterSection(root, "stamps", deadStamps) { it.optString("episodeId") }
        filterSection(root, "notes", deadNotes) { it.optString("noteId") }

        // 新增数从"删掉本地复活条目之后"起算,否则会报一个负数再被夹成 0。
        val before = counts(container)
        val prepared = dedupeSubscriptions(container, root.toString())
        BackupManager.apply(container, prepared, SECTIONS)
        val after = counts(container)
        return IntArray(before.size) { i -> (after[i] - before[i]).coerceAtLeast(0) }
    }

    /**
     * 删掉本端仍存在、但两边墓碑已经判死的条目。
     * 走各 store 自己的删除入口 —— 它们会顺手把墓碑补记一次(同 kind/id),不会丢信息。
     */
    private fun pruneLocal(
        container: AppContainer,
        deadSubs: Set<String>,
        deadFavs: Set<String>,
        deadStamps: Set<String>,
        deadNotes: Set<String>
    ) {
        if (deadSubs.isNotEmpty()) {
            val victims = container.subscriptionStore.subscriptions.value.filter {
                deadSubs.contains(SyncTombstones.subscriptionKey(it.feedUrl, it.id))
            }
            victims.forEach { container.subscriptionStore.toggle(it) }
        }
        if (deadFavs.isNotEmpty()) {
            val victims = container.favoriteStore.favorites.value.filter { deadFavs.contains(it.id) }
            victims.forEach { container.favoriteStore.toggle(it) }
        }
        if (deadStamps.isNotEmpty()) {
            container.stampStore.stamps.value
                .filter { deadStamps.contains(it.episodeId) }
                .forEach { container.stampStore.remove(it.episodeId) }
        }
        if (deadNotes.isNotEmpty()) {
            container.noteStore.notes.value
                .filter { deadNotes.contains(it.id) }
                .forEach { container.noteStore.remove(it.id) }
        }
    }

    /** 只保留"墓碑没判死"的条目;剔空了就整段删掉(与 dedupe 的空段处理一致)。 */
    private fun filterSection(
        root: JSONObject,
        name: String,
        dead: Set<String>,
        keyOf: (JSONObject) -> String?
    ) {
        val arr = root.optJSONArray(name) ?: return
        if (dead.isEmpty()) return
        val kept = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val k = keyOf(o)
            if (k != null && dead.contains(k)) continue
            kept.put(o)
        }
        if (kept.length() == 0) root.remove(name) else root.put(name, kept)
    }

    fun counts(container: AppContainer): IntArray = intArrayOf(
        container.subscriptionStore.subscriptions.value.size,
        container.favoriteStore.favorites.value.size,
        container.stampStore.stamps.value.size,
        container.noteStore.notes.value.size,
        container.historyStore.history.value.size,
        container.listenStatsStore.snapshot().size
    )

    /**
     * 订阅按 feedUrl 去重。远端 JSON 里**只保留本端没有的源**,以及远端自身第一次出现的源。
     * 其余分区原样带回 —— 这一步只解决"A 端用 collectionId、B 端用 feedUrl"这一种重复。
     */
    private fun dedupeSubscriptions(container: AppContainer, json: String): String {
        val root = runCatching { JSONObject(json) }.getOrElse {
            throw LanSyncException(LanSyncFail.PROTOCOL, "远端快照不是合法 JSON", it)
        }
        val arr = root.optJSONArray("subscriptions") ?: return json
        val seen = HashSet<String>()
        for (p in container.subscriptionStore.subscriptions.value) {
            normalize(p.feedUrl)?.let { seen.add(it) }
        }
        val kept = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val feed = normalize(o.optString("feedUrl"))
            if (feed != null && !seen.add(feed)) continue
            kept.put(o)
        }
        if (kept.length() == 0) root.remove("subscriptions") else root.put("subscriptions", kept)
        return root.toString()
    }

    /** 认源不认写法。实现只留一份在 `SyncTombstones`(墓碑键与去重键必须是同一个判据)。 */
    private fun normalize(feedUrl: String): String? = SyncTombstones.normalizeFeed(feedUrl)
}
