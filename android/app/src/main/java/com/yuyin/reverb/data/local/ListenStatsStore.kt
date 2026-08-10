package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.ChannelListen
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.HistoryEntry
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 按频道累计“实际播放过的内容时长”。播放时由 PlayerController 逐 tick 增量喂入，
 * 内存累加、约每 5s 节流落盘并刷新 StateFlow（避免高频写与重渲）。
 * 持久化：filesDir/listen_stats.json。
 */
class ListenStatsStore(context: Context) {
    private val file = File(context.filesDir, "listen_stats.json")
    private val lock = Any()
    private val table = LinkedHashMap<String, ChannelListen>()
    private var pendingMs = 0L
    private val flushThresholdMs = 5_000L

    private val _stats = MutableStateFlow<List<ChannelListen>>(emptyList())
    /** 已按累计时长降序排列，供页面直接渲染横条。 */
    val stats: StateFlow<List<ChannelListen>> = _stats

    init {
        synchronized(lock) {
            for (c in load()) table[c.key] = c
            publish()
        }
    }

    companion object {
        /** 频道键：feedUrl 非空优先，否则频道名。 */
        fun keyFor(e: Episode): String = e.feedUrl.ifBlank { e.podcastTitle }
    }

    /** 查询某频道累计毫秒（频道主页头部用）。 */
    fun listenedMsFor(key: String): Long = synchronized(lock) { table[key]?.listenedMs ?: 0L }

    /** 累加一段实际播放的内容毫秒（delta 已由调用方校验为正且合理）。 */
    fun add(episode: Episode, deltaMs: Long) {
        if (deltaMs <= 0) return
        synchronized(lock) {
            val k = keyFor(episode)
            val cur = table[k]
            table[k] = if (cur != null) {
                cur.copy(
                    title = episode.podcastTitle.ifBlank { cur.title },
                    artworkUrl = episode.artworkUrl.ifBlank { cur.artworkUrl },
                    listenedMs = cur.listenedMs + deltaMs
                )
            } else {
                ChannelListen(k, episode.podcastTitle, episode.artworkUrl, episode.feedUrl, deltaMs)
            }
            pendingMs += deltaMs
            if (pendingMs >= flushThresholdMs) commit()
        }
    }

    /** 立即落盘并刷新（暂停/播完/切集时调用）。 */
    fun flush() {
        synchronized(lock) { if (pendingMs > 0) commit() }
    }

    /**
     * 首启种子：listen_stats.json 不存在时，用现有历史（每集 played?durationMs:positionMs）
     * 按频道求和做近似初值，避免老用户全为 0；此后按实际播放精确累加。
     */
    fun seedFromHistory(history: List<HistoryEntry>) {
        synchronized(lock) {
            if (table.isNotEmpty()) return
            if (history.isEmpty()) return
            for (h in history) {
                val ms = if (h.played) maxOf(h.durationMs, h.positionMs) else h.positionMs
                if (ms <= 0) continue
                val k = keyFor(h.episode)
                val cur = table[k]
                table[k] = if (cur != null) cur.copy(listenedMs = cur.listenedMs + ms)
                else ChannelListen(k, h.episode.podcastTitle, h.episode.artworkUrl, h.episode.feedUrl, ms)
            }
            com.yuyin.reverb.util.Logger.i("ListenStats", "seed ${table.size} channels")
            persist()
            publish()
        }
    }

    // 需在 lock 内调用
    private fun commit() {
        pendingMs = 0L
        persist()
        publish()
    }

    private fun publish() {
        _stats.value = table.values.sortedByDescending { it.listenedMs }
    }

    private fun load(): List<ChannelListen> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<ChannelListen>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(
                    ChannelListen(
                        key = o.optString("key"),
                        title = o.optString("title"),
                        artworkUrl = o.optString("artworkUrl"),
                        feedUrl = o.optString("feedUrl"),
                        listenedMs = o.optLong("listenedMs")
                    )
                )
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun persist() {
        try {
            val arr = JSONArray()
            for (c in table.values) {
                arr.put(
                    JSONObject()
                        .put("key", c.key)
                        .put("title", c.title)
                        .put("artworkUrl", c.artworkUrl)
                        .put("feedUrl", c.feedUrl)
                        .put("listenedMs", c.listenedMs)
                )
            }
            file.writeText(arr.toString())
        } catch (e: Exception) {
        }
    }
}
