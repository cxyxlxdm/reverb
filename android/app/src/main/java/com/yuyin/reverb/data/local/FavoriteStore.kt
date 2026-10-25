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
            val removed = idx >= 0
            if (removed) current.removeAt(idx) else current.add(0, episode)
            _favorites.value = current
            persist(current)
            com.yuyin.reverb.util.Logger.i("FavStore", "${if (removed) "remove" else "add"} id=${episode.id} total=${current.size}")
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
                val o = arr.optJSONObject(i) ?: continue
                // 一条坏元素只丢那一条,不要把整份收藏毒成"空列表"再让空态落盘(REVIEW-2026-10-25 高-3)
                runCatching { EpisodeJson.fromJson(o) }.onSuccess { out.add(it) }
            }
            out
        } catch (e: Exception) {
            // 收藏是用户点出来的,读坏 ≠ 没有:标记 + 留证,空态整份写回由 JsonWriter 挡下
            JsonWriter.markLoadFailed(file)
            com.yuyin.reverb.util.Logger.e("FavStore", "favorites.json 读取失败,按空处理", e)
            emptyList()
        }
    }

    private fun persist(list: List<Episode>) {
        try {
            val arr = JSONArray()
            for (e in list) arr.put(EpisodeJson.toJson(e))
            // 原子写:.part → rename,见 JsonWriter.writeAtomically(REVIEW-2026-10-25 高-3 A 步)
            JsonWriter.writeAtomically(file, arr.toString())
        } catch (e: Exception) {
            // 持久化失败不影响内存态,忽略
        }
    }
}
