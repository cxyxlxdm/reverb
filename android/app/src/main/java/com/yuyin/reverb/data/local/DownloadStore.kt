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
                // `getJSONObject("episode")` → `optJSONObject` + 逐条 runCatching:
                // 原先缺 episode 键会抛 JSONException,跳出整个循环 ⇒ **一份好端端的下载账本
                // 因为一条坏记录被当成"零下载"**,而那个空态紧接着就会被 persist 落回盘上
                // (REVIEW-2026-10-25 高-3 附带条,与 HistoryStore 同型)
                val epObj = o.optJSONObject("episode") ?: continue
                val d = runCatching { DownloadedEpisode(EpisodeJson.fromJson(epObj), path) }.getOrNull()
                if (d != null) out.add(d)
                else com.yuyin.reverb.util.Logger.w("DownloadStore", "downloads.json 第 $i 条读坏了,跳过")
            }
            out
        } catch (e: Exception) {
            // 读坏 ≠ 一个下载都没有:标记 + 留证(见 JsonWriter)
            JsonWriter.markLoadFailed(file)
            com.yuyin.reverb.util.Logger.e("DownloadStore", "downloads.json 读取失败,按空处理", e)
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
            // 原子写:.part → rename,见 JsonWriter.writeAtomically(REVIEW-2026-10-25 高-3 A 步)
            JsonWriter.writeAtomically(file, arr.toString())
        } catch (e: Exception) {
        }
    }
}
