package com.yuyin.reverb.data.local

import com.yuyin.reverb.AppContainer
import com.yuyin.reverb.playback.DownloadManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * 备份/恢复：把订阅、下载(仅节目链接，不含音频文件)、历史、设置导出为一个 JSON，
 * 或从 JSON 选择性导入。每一项都可单独选择是否备份/恢复。
 */
object BackupManager {
    enum class Section { SUBSCRIPTIONS, FAVORITES, STAMPS, NOTES, DOWNLOADS, HISTORY, LISTEN_STATS, SETTINGS }

    private const val TAG = "Backup"

    fun build(container: AppContainer, include: Set<Section>): String {
        com.yuyin.reverb.util.Logger.i(TAG, "export sections=${include.joinToString(",")}")
        val root = JSONObject().put("version", 1)

        if (Section.SUBSCRIPTIONS in include) {
            val arr = JSONArray()
            container.subscriptionStore.subscriptions.value.forEach { arr.put(PodcastJson.toJson(it)) }
            root.put("subscriptions", arr)
        }
        if (Section.FAVORITES in include) {
            val arr = JSONArray()
            container.favoriteStore.favorites.value.forEach { arr.put(EpisodeJson.toJson(it)) }
            root.put("favorites", arr)
        }
        if (Section.STAMPS in include) {
            val arr = JSONArray()
            container.stampStore.stamps.value.forEach { s ->
                arr.put(
                    JSONObject()
                        .put("episodeId", s.episodeId).put("seal", s.seal)
                        .put("title", s.title).put("podcastTitle", s.podcastTitle).put("createdAt", s.createdAt)
                )
            }
            root.put("stamps", arr)
        }
        if (Section.NOTES in include) {
            // 批注是**用户写出来的字**,丢了没有任何东西能补回来,所以必须进默认导出。
            // episode 整条嵌进去(与 history 同构),否则换机后那些被发布方删掉的旧集无法定位。
            val arr = JSONArray()
            container.noteStore.notes.value.forEach { n ->
                arr.put(
                    JSONObject()
                        .put("noteId", n.id)
                        .put("positionMs", n.positionMs)
                        .put("text", n.text)
                        .put("createdAt", n.createdAt)
                        .put("episode", EpisodeJson.toJson(n.episode))
                )
            }
            root.put("notes", arr)
        }
        if (Section.DOWNLOADS in include) {
            // 只备份节目元数据/链接，不含音频文件
            val arr = JSONArray()
            container.downloadStore.downloads.value.forEach { arr.put(EpisodeJson.toJson(it.episode)) }
            root.put("downloads", arr)
        }
        if (Section.HISTORY in include) {
            val arr = JSONArray()
            container.historyStore.history.value.forEach { h ->
                arr.put(
                    JSONObject()
                        .put("episode", EpisodeJson.toJson(h.episode))
                        .put("positionMs", h.positionMs)
                        .put("durationMs", h.durationMs)
                        .put("updatedAt", h.updatedAt)
                        .put("played", h.played)
                )
            }
            root.put("history", arr)
        }
        if (Section.LISTEN_STATS in include) {
            // 按设备分账导出;恢复时按设备取 max,故重复恢复不会重复统计
            val arr = JSONArray()
            container.listenStatsStore.snapshot().forEach { arr.put(ChannelListenJson.toJson(it)) }
            root.put("listenStats", arr)
        }
        if (Section.SETTINGS in include) {
            val s = container.settingsStore
            val obj = JSONObject()
                .put("themeMode", s.themeMode.value)
                .put("fontScale", s.fontScale.value.toDouble())
                .put("accentIndex", s.accentIndex.value)
                .put("allowCellularDownload", s.allowCellularDownload.value)
                .put("updatesEnabled", s.updatesEnabled.value)
                .put("defaultSpeed", s.defaultSpeed.value.toDouble())
                .put("skipBackSec", s.skipBackSec.value)
                .put("skipForwardSec", s.skipForwardSec.value)
                .put("regionOverride", container.regionStore.override.value ?: JSONObject.NULL)
                .put("categoryOrder", JSONArray(container.categoryStore.loadOrder()))
            root.put("settings", obj)
        }
        com.yuyin.reverb.util.Logger.i(
            TAG,
            "export built subs=${root.optJSONArray("subscriptions")?.length() ?: 0} " +
                "favs=${root.optJSONArray("favorites")?.length() ?: 0} " +
                "stamps=${root.optJSONArray("stamps")?.length() ?: 0} " +
                "notes=${root.optJSONArray("notes")?.length() ?: 0} " +
                "downloads=${root.optJSONArray("downloads")?.length() ?: 0} " +
                "history=${root.optJSONArray("history")?.length() ?: 0}"
        )
        return root.toString(2)
    }

    fun sectionsIn(json: String): Set<Section> = try {
        val root = JSONObject(json)
        buildSet {
            if (root.has("subscriptions")) add(Section.SUBSCRIPTIONS)
            if (root.has("favorites")) add(Section.FAVORITES)
            if (root.has("stamps")) add(Section.STAMPS)
            if (root.has("notes")) add(Section.NOTES)
            if (root.has("downloads")) add(Section.DOWNLOADS)
            if (root.has("history")) add(Section.HISTORY)
            if (root.has("listenStats")) add(Section.LISTEN_STATS)
            if (root.has("settings")) add(Section.SETTINGS)
        }
    } catch (e: Exception) {
        emptySet()
    }

    /** 应用导入。返回 true 表示导入了「设置」(调用方可据此重排更新任务)。 */
    fun apply(container: AppContainer, json: String, include: Set<Section>): Boolean {
        com.yuyin.reverb.util.Logger.i(TAG, "restore sections=${include.joinToString(",")}")
        val root = JSONObject(json)

        if (Section.SUBSCRIPTIONS in include) root.optJSONArray("subscriptions")?.let { arr ->
            val list = (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.let(PodcastJson::fromJson) }
            if (list.isNotEmpty()) container.subscriptionStore.addAll(list)
        }
        if (Section.FAVORITES in include) root.optJSONArray("favorites")?.let { arr ->
            // 备份即「新在前」顺序;addAll 尾部追加,按原序并入即可保持该顺序
            val list = (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.let(EpisodeJson::fromJson) }
            if (list.isNotEmpty()) container.favoriteStore.addAll(list)
        }
        if (Section.STAMPS in include) root.optJSONArray("stamps")?.let { arr ->
            val list = (0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.let {
                    Stamp(it.optString("episodeId"), it.optString("seal"), it.optString("title"), it.optString("podcastTitle"), it.optLong("createdAt"))
                }
            }
            if (list.isNotEmpty()) container.stampStore.addAll(list)
        }
        if (Section.NOTES in include) root.optJSONArray("notes")?.let { arr ->
            val list = (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                val epObj = o.optJSONObject("episode") ?: return@mapNotNull null
                val ep = EpisodeJson.fromJson(epObj)
                if (ep.audioUrl.isBlank() || o.optString("text").isBlank()) return@mapNotNull null
                // **只有 `createdAt` 这个 epoch 字段**要做秒/毫秒归一(H86:macOS 侧写的是秒)。
                // `positionMs` 绝不能套同一条阈值 —— 那是给「Unix 时间戳」设计的,
                // 播放位置恒落在 1..1e11 之间,套上去会把 66 分钟(4.0e6 ms)误判成秒、乘一千变成
                // 40 亿毫秒,跳过去直接超出时长而落回开头,且列表显示的时间戳看着还是"合理"的。
                val raw = o.optLong("createdAt")
                val createdAt = if (raw in 1 until 100_000_000_000) raw * 1000 else raw
                EpisodeNote(
                    // 缺 `noteId` 时用**确定值**兜底,不用随机 UUID:恢复按 id 去重,
                    // 随机 id 等于让同一份备份恢复两次就把批注**翻倍**(破坏幂等)。
                    // 格式照鸿蒙 `${createdAt}-${i}` —— 确定值本身是免费的,没理由不这么做。
                    id = o.optString("noteId").ifBlank { "$createdAt-$i" },
                    episode = ep,
                    positionMs = o.optLong("positionMs").coerceAtLeast(0L),
                    text = o.optString("text"),
                    createdAt = createdAt
                )
            }
            if (list.isNotEmpty()) container.noteStore.addAll(list)
        }
        if (Section.DOWNLOADS in include) root.optJSONArray("downloads")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val ep = EpisodeJson.fromJson(o)
                if (ep.audioUrl.isNotBlank()) DownloadManager.download(ep) // 按链接重新下载
            }
        }
        if (Section.HISTORY in include) root.optJSONArray("history")?.let { arr ->
            // 合并策略:同一集在两边都存在时,按 updatedAt 取更新的那条,避免用旧备份把当前进度倒退。
            // 快照恢复前的状态用于比较(边并入边比较会失真)。
            val existing = container.historyStore.history.value.associateBy { it.episode.id }
            // 倒序导入，使原本较新的记录最终位于前列
            for (i in arr.length() - 1 downTo 0) {
                val o = arr.optJSONObject(i) ?: continue
                val epObj = o.optJSONObject("episode") ?: continue
                val ep = EpisodeJson.fromJson(epObj)
                // 时间戳口径归一(H86):本端是毫秒,macOS 备份是秒 —— 1e11 以下按秒×1000
                // (现时秒级时间戳 ~1.8e9,毫秒级 ~1.8e12,阈值两侧都有足够余量)
                val raw = o.optLong("updatedAt")
                val updatedAt = if (raw in 1 until 100_000_000_000) raw * 1000 else raw
                val cur = existing[ep.id]
                if (cur != null && cur.updatedAt >= updatedAt) continue // 当前记录更新,保留不覆盖
                container.historyStore.record(ep, updatedAt)
                container.historyStore.updatePosition(ep.id, o.optLong("positionMs"), o.optLong("durationMs"))
                // record() 会把 played 重置为 false,备份里带 true 的要补回
                if (o.optBoolean("played", false)) container.historyStore.markPlayed(ep.id, true)
            }
        }
        if (Section.LISTEN_STATS in include) root.optJSONArray("listenStats")?.let { arr ->
            // 按设备取 max 合并(幂等):重复恢复同一份备份不会重复累加,跨设备则自然汇总
            val list = ArrayList<com.yuyin.reverb.data.model.ChannelListen>(arr.length())
            val legacy = HashMap<String, Long>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val (c, legacyMs) = ChannelListenJson.parse(o)
                list.add(c)
                if (legacyMs > 0) legacy[c.key] = legacyMs
            }
            if (list.isNotEmpty()) container.listenStatsStore.merge(list, legacy)
        }
        var importedSettings = false
        if (Section.SETTINGS in include) root.optJSONObject("settings")?.let { s ->
            val st = container.settingsStore
            if (s.has("themeMode")) st.setThemeMode(s.getInt("themeMode"))
            if (s.has("fontScale")) st.setFontScale(s.getDouble("fontScale").toFloat())
            if (s.has("accentIndex")) st.setAccentIndex(s.getInt("accentIndex"))
            if (s.has("allowCellularDownload")) st.setAllowCellularDownload(s.getBoolean("allowCellularDownload"))
            if (s.has("updatesEnabled")) st.setUpdatesEnabled(s.getBoolean("updatesEnabled"))
            if (s.has("defaultSpeed")) st.setDefaultSpeed(s.getDouble("defaultSpeed").toFloat())
            if (s.has("skipBackSec")) st.setSkipBackSec(s.getInt("skipBackSec"))
            if (s.has("skipForwardSec")) st.setSkipForwardSec(s.getInt("skipForwardSec"))
            val region = if (s.isNull("regionOverride")) null else s.optString("regionOverride").ifBlank { null }
            container.regionStore.setOverride(region)
            s.optJSONArray("categoryOrder")?.let { ca ->
                val order = (0 until ca.length()).map { ca.optString(it) }.filter { it.isNotBlank() }
                if (order.isNotEmpty()) container.categoryStore.saveOrder(order)
            }
            importedSettings = true
        }
        com.yuyin.reverb.util.Logger.i(TAG, "restore done importedSettings=$importedSettings")
        return importedSettings
    }
}
