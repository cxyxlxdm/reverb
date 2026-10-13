package com.yuyin.reverb.data.local

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 「播过即缓存」的账本:哪一集的音频落在缓存目录里、多大、最后一次被用过是什么时候。
 *
 * 与 [DownloadStore] 是**两份独立的账**,这是需求里明确要区分的一件事:
 *  - 下载 = 用户**点名**要留的,永久有效、进备份、由「清除下载」负责;
 *  - 缓存 = App **自己**为「下次别联网」攒的,可被预算挤掉、**不进备份**、由「清除缓存」负责。
 * 两者连目录都不同(`downloads/` 与 `audio_cache/`),所以任何一侧的清理不可能误删另一侧的文件。
 *
 * 只存 id/url/文件名/字节数,**不整份抄 [com.yuyin.reverb.data.model.Episode]**:
 * 缓存条目唯一用途是「这一集的音频在不在本地、在哪个文件」,起播时那一集的元数据本来就来自列表
 * (而列表另有 feed_cache / inbox 两份缓存)。抄整份 Episode 只会让这个文件随集数线性膨胀。
 *
 * 记的是**文件名而不是绝对路径**:路径随 `filesDir` 变(备份恢复、多用户),而存相对名让账本和
 * 目录能一起搬。缓存本来就只在本机本次安装内有意义,搬不过来时重下一遍即可。
 *
 * **带版本号**(硬规矩 11):这份账的口径以后会变。旧账在新版本里**照样能解析成功**、只是每条
 * 都指不到文件 —— 界面上就是"缓存莫名其妙空了",而用户没有自救入口。版本不符时整体作废,不猜。
 */
class AudioCacheStore(context: Context) {

    /** 一条缓存记录。[fileName] 相对缓存目录(见 [AudioCacheManager] 侧的目录拼接)。 */
    class Item(
        val episodeId: String,
        val audioUrl: String,
        val fileName: String,
        val bytes: Long,
        val cachedAt: Long,
        var lastAccessMs: Long
    )

    private val file = File(context.filesDir, FILE_NAME)
    private val lock = Any()
    private val mem: LinkedHashMap<String, Item> = load()

    private val _items = MutableStateFlow<List<Item>>(emptyList())
    /** 供设置页与启动日志读当前条目数(装载时已剔除解析失败的记录,数字与账本一致)。 */
    val items: StateFlow<List<Item>> = _items

    init { _items.value = mem.values.toList() }

    fun get(episodeId: String): Item? = synchronized(lock) { mem[episodeId] }

    /** 落一条新账(同一集重复落时覆盖旧记录,访问时间重置到现在)。 */
    fun put(item: Item) {
        synchronized(lock) {
            mem[item.episodeId] = item
            persist()
        }
    }

    /**
     * 记一次「这一集真的从缓存里起播了」。
     *
     * 单独存在是因为 **LRU 的那个 L 全靠它**:淘汰只看 lastAccessMs,而"用过"只发生在起播那一刻。
     * 只在写入时更新的话,一条反复听的集会因 cachedAt 太旧而被优先挤掉,预算就白设了。
     */
    fun touch(episodeId: String) {
        synchronized(lock) {
            val item = mem[episodeId] ?: return
            item.lastAccessMs = System.currentTimeMillis()
            persist()
        }
    }

    /** 删账并返回待删的文件名(账与文件必须一次调用一起处理,否则孤儿文件清不掉)。 */
    fun remove(episodeId: String): String? {
        synchronized(lock) {
            val gone = mem.remove(episodeId) ?: return null
            persist()
            return gone.fileName
        }
    }

    /** 清空账本并返回所有待删的文件名。 */
    fun clearAll(): List<String> {
        synchronized(lock) {
            val names = mem.values.map { it.fileName }
            mem.clear()
            persist()
            return names
        }
    }

    /** 当前账目的拷贝,按最后一次访问**升序**(淘汰从头部开始)。 */
    fun byLeastRecent(): List<Item> = synchronized(lock) { mem.values.sortedBy { it.lastAccessMs } }

    fun sizeBytes(): Long = if (file.exists()) file.length() else 0L

    private fun persist() {
        val snapshot = mem.values.toList()
        _items.value = snapshot
        JsonWriter.write(file) {
            val arr = JSONArray()
            for (it in snapshot) {
                arr.put(
                    JSONObject()
                        .put("id", it.episodeId)
                        .put("url", it.audioUrl)
                        .put("f", it.fileName)
                        .put("bytes", it.bytes)
                        .put("cachedAt", it.cachedAt)
                        .put("lastAccess", it.lastAccessMs)
                )
            }
            JSONObject().put("v", VERSION).put("items", arr).toString()
        }
    }

    private fun load(): LinkedHashMap<String, Item> {
        val out = LinkedHashMap<String, Item>()
        if (!file.exists()) return out
        try {
            val root = JSONObject(file.readText())
            if (root.optInt("v", 0) != VERSION) {
                com.yuyin.reverb.util.Logger.w(TAG, "cache ledger v=${root.optInt("v", 0)} != $VERSION, discard")
                return out
            }
            val arr = root.optJSONArray("items") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val id = o.optString("id")
                val name = o.optString("f")
                if (id.isBlank() || name.isBlank()) continue
                out[id] = Item(
                    episodeId = id,
                    audioUrl = o.optString("url"),
                    fileName = name,
                    bytes = o.optLong("bytes", 0L),
                    cachedAt = o.optLong("cachedAt", 0L),
                    lastAccessMs = o.optLong("lastAccess", 0L)
                )
            }
            com.yuyin.reverb.util.Logger.i(TAG, "cache ledger loaded items=${out.size}")
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "cache ledger load failed: ${e.message}")
            out.clear()
        }
        return out
    }

    companion object {
        /** 缓存目录名(与 `downloads` 物理分开 —— 「缓存与下载分开存储」这条要求的落地处)。 */
        const val DIR_NAME = "audio_cache"
        private const val FILE_NAME = "audio_cache.json"
        /** 账本格式版本。口径变了就 +1,旧账整体作废。 */
        private const val VERSION = 1
        private const val TAG = "AudioCache"
    }
}
