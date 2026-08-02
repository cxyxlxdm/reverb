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
    enum class Section { SUBSCRIPTIONS, FAVORITES, DOWNLOADS, HISTORY, SETTINGS }

    fun build(container: AppContainer, include: Set<Section>): String {
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
                )
            }
            root.put("history", arr)
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
        return root.toString(2)
    }

    fun sectionsIn(json: String): Set<Section> = try {
        val root = JSONObject(json)
        buildSet {
            if (root.has("subscriptions")) add(Section.SUBSCRIPTIONS)
            if (root.has("favorites")) add(Section.FAVORITES)
            if (root.has("downloads")) add(Section.DOWNLOADS)
            if (root.has("history")) add(Section.HISTORY)
            if (root.has("settings")) add(Section.SETTINGS)
        }
    } catch (e: Exception) {
        emptySet()
    }

    /** 应用导入。返回 true 表示导入了「设置」(调用方可据此重排更新任务)。 */
    fun apply(container: AppContainer, json: String, include: Set<Section>): Boolean {
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
        if (Section.DOWNLOADS in include) root.optJSONArray("downloads")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val ep = EpisodeJson.fromJson(o)
                if (ep.audioUrl.isNotBlank()) DownloadManager.download(ep) // 按链接重新下载
            }
        }
        if (Section.HISTORY in include) root.optJSONArray("history")?.let { arr ->
            // 倒序导入，使原本较新的记录最终位于前列
            for (i in arr.length() - 1 downTo 0) {
                val o = arr.optJSONObject(i) ?: continue
                val epObj = o.optJSONObject("episode") ?: continue
                val ep = EpisodeJson.fromJson(epObj)
                container.historyStore.record(ep, o.optLong("updatedAt"))
                container.historyStore.updatePosition(ep.id, o.optLong("positionMs"), o.optLong("durationMs"))
            }
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
        return importedSettings
    }
}
