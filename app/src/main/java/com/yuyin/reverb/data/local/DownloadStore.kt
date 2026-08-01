package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.DownloadedEpisode
import com.yuyin.reverb.data.model.Episode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** 已下载分集的持久化列表。 */
class DownloadStore(context: Context) {
    private val file = File(context.filesDir, "downloads.json")
    private val lock = Any()

    private val _downloads = MutableStateFlow(load())
    val downloads: StateFlow<List<DownloadedEpisode>> = _downloads

    fun get(episodeId: String): DownloadedEpisode? = _downloads.value.firstOrNull { it.episode.id == episodeId }

    fun contains(episodeId: String): Boolean = _downloads.value.any { it.episode.id == episodeId }

    fun add(episode: Episode, localPath: String) {
        synchronized(lock) {
            val list = _downloads.value.toMutableList()
            list.removeAll { it.episode.id == episode.id }
            list.add(0, DownloadedEpisode(episode, localPath))
            _downloads.value = list
            persist(list)
        }
    }

    fun remove(episodeId: String) {
        synchronized(lock) {
            val list = _downloads.value.filterNot { it.episode.id == episodeId }
            _downloads.value = list
            persist(list)
        }
    }

    fun clearAll() {
        synchronized(lock) {
            _downloads.value = emptyList()
            persist(emptyList())
        }
    }

    private fun load(): List<DownloadedEpisode> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<DownloadedEpisode>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val path = o.optString("localPath")
                if (path.isBlank() || !File(path).exists()) continue // 文件已被清理则跳过
                out.add(DownloadedEpisode(EpisodeJson.fromJson(o.getJSONObject("episode")), path))
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun persist(list: List<DownloadedEpisode>) {
        try {
            val arr = JSONArray()
            for (d in list) {
                arr.put(
                    JSONObject()
                        .put("episode", EpisodeJson.toJson(d.episode))
                        .put("localPath", d.localPath)
                )
            }
            file.writeText(arr.toString())
        } catch (e: Exception) {
        }
    }
}
