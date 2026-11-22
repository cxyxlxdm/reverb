package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Station
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 用户自己的直播电台账本:`filesDir/stations.json`,与 `subscriptions.json` 同一形状
 * (零依赖 JSON、单进程内存态 + 原子写)。
 *
 * **为什么不参与局域网同步**(与订阅 / 收藏不同):电台是"这台设备上的快捷方式",
 * 而同步的删除传播要靠墓碑账本(`SyncTombstones`)。给电台也开一套墓碑会让本轮改动
 * 跨进同步协议与两端 UI;当前口径是**只进手动备份**(`stations` 段),换机靠恢复 JSON。
 * 真要做日常同步时再按 `SyncTombstones` 的现有形状补,不要在 `LanSyncMerge` 里
 * 直接塞分区 —— 那会得到"删了又被带回来"的已知问题。
 *
 * 随包精选清单([seedStations])是**只读**的:界面点「+」时复制一条进本账本,
 * 用户随后改名字/删掉都不影响清单本身。
 */
class StationStore(context: Context) {

    private val appContext = context.applicationContext
    private val file = File(context.filesDir, "stations.json")
    private val lock = Any()

    private val _stations = MutableStateFlow(load())
    val stations: StateFlow<List<Station>> = _stations

    private var seedCache: List<Station>? = null

    fun containsUrl(url: String): Boolean =
        _stations.value.any { it.key() == url.trim() }

    fun containsUrlExcept(url: String, exceptId: String): Boolean =
        _stations.value.any { it.id != exceptId && it.key() == url.trim() }

    /** 新增一条;地址或 id 已存在时返回 false(调用方据此提示"已在列表里")。 */
    fun add(station: Station): Boolean {
        synchronized(lock) {
            val current = _stations.value
            if (current.any { it.id == station.id || it.key() == station.key() }) return false
            val next = ArrayList<Station>(current.size + 1).apply {
                add(station)
                addAll(current)
            }
            _stations.value = next
            persist(next)
            com.yuyin.reverb.util.Logger.i("StationStore", "add id=${station.id} total=${next.size}")
            return true
        }
    }

    /** 按 id 原位替换;id 不存在时什么也不做。地址冲突由调用方先判(见 RadioViewModel)。 */
    fun update(station: Station) {
        synchronized(lock) {
            val current = _stations.value
            val idx = current.indexOfFirst { it.id == station.id }
            if (idx < 0) return
            val next = current.toMutableList()
            next[idx] = station
            _stations.value = next
            persist(next)
            com.yuyin.reverb.util.Logger.i("StationStore", "update id=${station.id} total=${next.size}")
        }
    }

    fun remove(id: String) {
        synchronized(lock) {
            val current = _stations.value
            val next = current.filterNot { it.id == id }
            if (next.size == current.size) return
            _stations.value = next
            persist(next)
            com.yuyin.reverb.util.Logger.i("StationStore", "remove id=$id total=${next.size}")
        }
    }

    /**
     * 备份恢复 / 同步并入:按 **id 或 url** 去重,本端已有的保留。
     * 不做删除传播 —— stations 分区不在 `LanSyncMerge.SECTIONS` 里(见类注释)。
     */
    fun addAll(list: List<Station>) {
        synchronized(lock) {
            val current = _stations.value
            val ids = current.mapTo(HashSet()) { it.id }
            val urls = current.mapTo(HashSet()) { it.key() }
            val merged = current.toMutableList()
            for (s in list) {
                if (s.id in ids || s.key() in urls) continue
                ids.add(s.id)
                urls.add(s.key())
                merged.add(s)
            }
            if (merged.size == current.size) return
            _stations.value = merged
            persist(merged)
            com.yuyin.reverb.util.Logger.i("StationStore", "addAll +${merged.size - current.size} total=${merged.size}")
        }
    }

    /**
     * 随包精选(`assets/radio_stations.json`,由 `shared/radio/sync.sh` 分发)。
     * 解析一次、进程内复用;文件缺失或损坏退化为空列表(等同没有这个区块)。
     * id 用 `seed:<url>` 是确定值:同一台设备两次启动得到同一批 id,收藏后不会重复。
     */
    fun seedStations(): List<Station> {
        seedCache?.let { return it }
        synchronized(lock) {
            seedCache?.let { return it }
            seedCache = parseSeed()
            return seedCache!!
        }
    }

    private fun parseSeed(): List<Station> = try {
        val text = appContext.assets.open(SEED_ASSET).bufferedReader().use { it.readText() }
        val arr = JSONObject(text).optJSONArray("stations") ?: JSONArray()
        val out = ArrayList<Station>(arr.length())
        val seen = HashSet<String>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val url = o.optString("url").trim()
            val name = o.optString("name").trim()
            if (url.isBlank() || name.isBlank() || !seen.add(url)) continue
            out.add(
                Station(
                    id = "seed:$url",
                    name = name,
                    url = url,
                    logo = o.optString("logo").trim(),
                    group = Station.normalizeGroup(o.optString("group")),
                    country = o.optString("country").trim().ifBlank { "CN" },
                    source = Station.SOURCE_SEED
                )
            )
        }
        com.yuyin.reverb.util.Logger.i("StationStore", "seed loaded n=${out.size}")
        out
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.w("StationStore", "电台精选清单读取失败,按空处理: ${e.javaClass.simpleName}")
        emptyList()
    }

    private fun load(): List<Station> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<Station>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                // 与订阅同一条:逐条 runCatching,一条坏元素只丢那一条
                val s = runCatching { StationJson.fromJson(o) }.getOrNull()
                if (s != null) out.add(s)
                else com.yuyin.reverb.util.Logger.w("StationStore", "stations.json 第 $i 条读坏了,跳过")
            }
            out
        } catch (e: Exception) {
            JsonWriter.markLoadFailed(file)
            com.yuyin.reverb.util.Logger.e("StationStore", "stations.json 读取失败,按空处理", e)
            emptyList()
        }
    }

    private fun persist(list: List<Station>) {
        try {
            val arr = JSONArray()
            for (s in list) arr.put(StationJson.toJson(s))
            // 与订阅同一档:单次用户动作触发的小数据走同步原子写,不去抖
            JsonWriter.writeAtomically(file, arr.toString())
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.e("StationStore", "stations.json 落盘失败", e)
        }
    }

    companion object {
        private const val SEED_ASSET = "radio_stations.json"
    }
}
