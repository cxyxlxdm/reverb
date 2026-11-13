package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.sync.SyncTombstones
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** 一枚听觉印记:为某一集盖下的水墨印章(印字 + 单集信息 + 时间)。 */
data class Stamp(
    val episodeId: String,
    val seal: String,          // 印章字,如 静/思/暖/燃/悟
    val title: String,
    val podcastTitle: String,
    val createdAt: Long
)

/** 听觉印记:每集最多一枚,最近置顶,JSON 持久化。 */
class StampStore(context: Context) {
    private val file = File(context.filesDir, "stamps.json")
    private val lock = Any()

    private val _stamps = MutableStateFlow(load())
    val stamps: StateFlow<List<Stamp>> = _stamps

    fun sealFor(episodeId: String): String? = _stamps.value.firstOrNull { it.episodeId == episodeId }?.seal

    /** 盖章 / 改章:为该集写入印记(替换同集旧章),置顶。 */
    fun set(episodeId: String, seal: String, title: String, podcastTitle: String, now: Long) {
        synchronized(lock) {
            val list = _stamps.value.filterNot { it.episodeId == episodeId }.toMutableList()
            list.add(0, Stamp(episodeId, seal, title, podcastTitle, now))
            _stamps.value = list
            persist(list)
            com.yuyin.reverb.util.Logger.i("StampStore", "set seal='$seal' id=$episodeId total=${list.size}")
            // 盖章=重新添加:清掉删除墓碑,否则同步时会被另一端的旧删除压回去。
            SyncTombstones.clear(SyncTombstones.STAMPS, episodeId)
        }
    }

    fun remove(episodeId: String) {
        synchronized(lock) {
            val list = _stamps.value.filterNot { it.episodeId == episodeId }
            _stamps.value = list
            persist(list)
            com.yuyin.reverb.util.Logger.i("StampStore", "remove id=$episodeId total=${list.size}")
            SyncTombstones.record(SyncTombstones.STAMPS, episodeId)
        }
    }

    fun addAll(items: List<Stamp>) {
        synchronized(lock) {
            val list = _stamps.value.toMutableList()
            for (s in items) if (list.none { it.episodeId == s.episodeId }) list.add(s)
            _stamps.value = list
            persist(list)
            // 恢复/同步并入 = 重新盖章,清掉墓碑(理由同 SubscriptionStore.addAll)。
            items.forEach { SyncTombstones.clear(SyncTombstones.STAMPS, it.episodeId) }
        }
    }

    private fun load(): List<Stamp> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<Stamp>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(
                    Stamp(
                        episodeId = o.optString("episodeId"),
                        seal = o.optString("seal"),
                        title = o.optString("title"),
                        podcastTitle = o.optString("podcastTitle"),
                        createdAt = o.optLong("createdAt")
                    )
                )
            }
            out
        } catch (e: Exception) {
            // 印记同样是用户盖出来的:读坏 ≠ 没有,标记 + 留证(见 JsonWriter,REVIEW-2026-10-25 高-3)
            JsonWriter.markLoadFailed(file)
            com.yuyin.reverb.util.Logger.e("StampStore", "stamps.json 读取失败,按空处理", e)
            emptyList()
        }
    }

    private fun persist(list: List<Stamp>) {
        try {
            val arr = JSONArray()
            for (s in list) {
                arr.put(
                    JSONObject()
                        .put("episodeId", s.episodeId)
                        .put("seal", s.seal)
                        .put("title", s.title)
                        .put("podcastTitle", s.podcastTitle)
                        .put("createdAt", s.createdAt)
                )
            }
            // 原子写:.part → rename,见 JsonWriter.writeAtomically(REVIEW-2026-10-25 高-3 A 步)
            JsonWriter.writeAtomically(file, arr.toString())
        } catch (e: Exception) {
        }
    }
}
