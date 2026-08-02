package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import java.io.File

/** 单集收藏：以 JSON 文件持久化在应用私有目录,最近收藏置顶,零依赖、无需数据库。 */
class FavoriteStore(context: Context) {

    private val file = File(context.filesDir, "favorites.json")
    private val lock = Any()

    private val _favorites = MutableStateFlow(load())
    val favorites: StateFlow<List<Episode>> = _favorites

    fun isFavorite(episodeId: String): Boolean = _favorites.value.any { it.id == episodeId }

    /** 收藏 ↔ 取消收藏。收藏时置顶。 */
    fun toggle(episode: Episode) {
        synchronized(lock) {
            val current = _favorites.value.toMutableList()
            val idx = current.indexOfFirst { it.id == episode.id }
            if (idx >= 0) current.removeAt(idx) else current.add(0, episode)
            _favorites.value = current
            persist(current)
        }
    }

    /** 批量并入(恢复备份用),已存在的按 id 去重,保持原顺序。 */
    fun addAll(episodes: List<Episode>) {
        synchronized(lock) {
            val current = _favorites.value.toMutableList()
            for (e in episodes) if (current.none { it.id == e.id }) current.add(e)
            _favorites.value = current
            persist(current)
        }
    }

    private fun load(): List<Episode> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<Episode>(arr.length())
            for (i in 0 until arr.length()) {
                arr.optJSONObject(i)?.let { out.add(EpisodeJson.fromJson(it)) }
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun persist(list: List<Episode>) {
        try {
            val arr = JSONArray()
            for (e in list) arr.put(EpisodeJson.toJson(e))
            file.writeText(arr.toString())
        } catch (e: Exception) {
            // 持久化失败不影响内存态,忽略
        }
    }
}
