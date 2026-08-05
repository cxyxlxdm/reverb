package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.HistoryEntry
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** 播放历史：最近播放置顶，记录续播进度，最多保留 100 条。 */
class HistoryStore(context: Context) {
    private val file = File(context.filesDir, "history.json")
    private val lock = Any()
    private val max = 100

    private val _history = MutableStateFlow(load())
    val history: StateFlow<List<HistoryEntry>> = _history

    fun positionFor(episodeId: String): Long =
        _history.value.firstOrNull { it.episode.id == episodeId }?.positionMs ?: 0L

    /** 开始播放某集：置顶，保留已有进度。 */
    fun record(episode: Episode, now: Long) {
        synchronized(lock) {
            val existing = _history.value.firstOrNull { it.episode.id == episode.id }
            val list = _history.value.filterNot { it.episode.id == episode.id }.toMutableList()
            list.add(
                0,
                HistoryEntry(
                    episode = episode,
                    positionMs = existing?.positionMs ?: 0L,
                    durationMs = existing?.durationMs ?: 0L,
                    updatedAt = now
                )
            )
            val trimmed = if (list.size > max) list.subList(0, max).toList() else list
            _history.value = trimmed
            persist(trimmed)
        }
    }

    /** 更新当前集进度（不改变顺序，避免频繁写导致抖动）。 */
    fun updatePosition(episodeId: String, positionMs: Long, durationMs: Long) {
        synchronized(lock) {
            val list = _history.value.map {
                if (it.episode.id == episodeId) it.copy(positionMs = positionMs, durationMs = durationMs) else it
            }
            _history.value = list
            persist(list)
        }
    }

    fun isPlayed(episodeId: String): Boolean =
        _history.value.firstOrNull { it.episode.id == episodeId }?.played ?: false

    /** 标记某集是否已播完（不改变顺序）。 */
    fun markPlayed(episodeId: String, played: Boolean) {
        synchronized(lock) {
            if (_history.value.none { it.episode.id == episodeId }) return
            val list = _history.value.map {
                if (it.episode.id == episodeId) it.copy(played = played) else it
            }
            _history.value = list
            persist(list)
            com.yuyin.reverb.util.Logger.i("HistoryStore", "markPlayed id=$episodeId played=$played")
        }
    }

    fun clear() {
        synchronized(lock) {
            com.yuyin.reverb.util.Logger.i("HistoryStore", "clear (was ${_history.value.size})")
            _history.value = emptyList()
            persist(emptyList())
        }
    }

    private fun load(): List<HistoryEntry> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<HistoryEntry>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(
                    HistoryEntry(
                        episode = EpisodeJson.fromJson(o.getJSONObject("episode")),
                        positionMs = o.optLong("positionMs"),
                        durationMs = o.optLong("durationMs"),
                        updatedAt = o.optLong("updatedAt"),
                        played = o.optBoolean("played", false)
                    )
                )
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun persist(list: List<HistoryEntry>) {
        try {
            val arr = JSONArray()
            for (h in list) {
                arr.put(
                    JSONObject()
                        .put("episode", EpisodeJson.toJson(h.episode))
                        .put("positionMs", h.positionMs)
                        .put("durationMs", h.durationMs)
                        .put("updatedAt", h.updatedAt)
                        .put("played", h.played)
                )
            }
            file.writeText(arr.toString())
        } catch (e: Exception) {
        }
    }
}
