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
import java.util.UUID

/** 频道时长 JSON 编解码。perDevice 为分账映射；listenedMs 同时写出，便于人读与旧版本读取。 */
object ChannelListenJson {
    fun toJson(c: ChannelListen): JSONObject {
        val pd = JSONObject()
        for ((dev, ms) in c.perDevice) pd.put(dev, ms)
        return JSONObject()
            .put("key", c.key)
            .put("title", c.title)
            .put("artworkUrl", c.artworkUrl)
            .put("feedUrl", c.feedUrl)
            .put("perDevice", pd)
            .put("listenedMs", c.listenedMs)
    }

    /** 返回 (频道, 旧格式扁平毫秒)；新格式的扁平值为 0。 */
    fun parse(o: JSONObject): Pair<ChannelListen, Long> {
        val pdObj = o.optJSONObject("perDevice")
        val pd = HashMap<String, Long>()
        if (pdObj != null) {
            val keys = pdObj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                pd[k] = pdObj.optLong(k)
            }
        }
        val c = ChannelListen(
            key = o.optString("key"),
            title = o.optString("title"),
            artworkUrl = o.optString("artworkUrl"),
            feedUrl = o.optString("feedUrl"),
            perDevice = pd
        )
        val legacy = if (pd.isEmpty()) o.optLong("listenedMs") else 0L
        return c to legacy
    }
}

/**
 * 按频道累计“实际播放过的内容时长”。播放时由 PlayerController 逐 tick 增量喂入，
 * 内存累加、约每 5s 节流落盘并刷新 StateFlow（避免高频写与重渲）。
 * 持久化：filesDir/listen_stats.json。
 *
 * 时长按**设备分账**（见 ChannelListen.perDevice）：本机只累加自己名下那格，
 * 展示值为各设备之和；备份恢复按设备取 max 合并，故重复恢复不会重复统计。
 */
class ListenStatsStore(context: Context) {
    private val file = File(context.filesDir, "listen_stats.json")
    private val lock = Any()
    private val table = LinkedHashMap<String, ChannelListen>()
    private var pendingMs = 0L
    private val flushThresholdMs = 5_000L

    /** 本机安装标识（首次生成后固定），用于分账。 */
    val deviceId: String

    private val _stats = MutableStateFlow<List<ChannelListen>>(emptyList())
    /** 已按累计时长降序排列，供页面直接渲染横条。 */
    val stats: StateFlow<List<ChannelListen>> = _stats

    init {
        val prefs = context.getSharedPreferences("reverb_settings", Context.MODE_PRIVATE)
        val existing = prefs.getString("device_id", null)
        deviceId = if (!existing.isNullOrBlank()) existing else {
            val generated = UUID.randomUUID().toString()
            prefs.edit().putString("device_id", generated).apply()
            generated
        }
        synchronized(lock) {
            var migrated = false
            for ((c, legacyMs) in load()) {
                // 旧格式（扁平 listenedMs）迁移：既有时长归入本机名下
                table[c.key] = if (c.perDevice.isEmpty() && legacyMs > 0) {
                    migrated = true
                    c.copy(perDevice = mapOf(deviceId to legacyMs))
                } else c
            }
            publish()
            if (migrated) persist()
            com.yuyin.reverb.util.Logger.i(
                "ListenStats",
                "load ${table.size} channels device=${deviceId.take(8)} migrated=$migrated"
            )
        }
    }

    companion object {
        /** 历史估算种子的分账键（所有设备共用一格，合并取 max ⇒ 估算不会跨设备翻倍）。 */
        const val SEED_KEY = "seed"

        /** 频道键：feedUrl 非空优先，否则频道名。 */
        fun keyFor(e: Episode): String = e.feedUrl.ifBlank { e.podcastTitle }
    }

    /** 查询某频道累计毫秒（各设备之和；频道主页头部用）。 */
    fun listenedMsFor(key: String): Long = synchronized(lock) { table[key]?.listenedMs ?: 0L }

    /** 累加一段实际播放的内容毫秒到本机名下（delta 已由调用方校验为正且合理）。 */
    fun add(episode: Episode, deltaMs: Long) {
        if (deltaMs <= 0) return
        synchronized(lock) {
            val k = keyFor(episode)
            val cur = table[k] ?: ChannelListen(k, episode.podcastTitle, episode.artworkUrl, episode.feedUrl)
            val pd = HashMap(cur.perDevice)
            pd[deviceId] = (pd[deviceId] ?: 0L) + deltaMs
            table[k] = cur.copy(
                title = episode.podcastTitle.ifBlank { cur.title },
                artworkUrl = episode.artworkUrl.ifBlank { cur.artworkUrl },
                perDevice = pd
            )
            pendingMs += deltaMs
            if (pendingMs >= flushThresholdMs) commit()
        }
    }

    /** 立即落盘并刷新（暂停/播完/切集时调用）。 */
    fun flush() {
        synchronized(lock) { if (pendingMs > 0) commit() }
    }

    /** 供备份导出的快照。 */
    fun snapshot(): List<ChannelListen> = synchronized(lock) { table.values.toList() }

    /**
     * 备份恢复合并：**按设备取 max**（而非相加）。
     * 同一份备份重复恢复得到同样结果（幂等）；不同设备的分账相加，故跨设备恢复自然汇总。
     * legacyMsByKey 承载旧格式备份的扁平时长（归入稳定的伪设备键，避免与本机相加出错）。
     */
    fun merge(incoming: List<ChannelListen>, legacyMsByKey: Map<String, Long> = emptyMap()) {
        if (incoming.isEmpty()) return
        synchronized(lock) {
            for (raw in incoming) {
                val incPerDevice = if (raw.perDevice.isEmpty()) {
                    val legacy = legacyMsByKey[raw.key] ?: 0L
                    if (legacy <= 0) continue else mapOf("legacy:${raw.key}" to legacy)
                } else raw.perDevice
                val cur = table[raw.key]
                if (cur == null) {
                    table[raw.key] = raw.copy(perDevice = incPerDevice)
                } else {
                    val pd = HashMap(cur.perDevice)
                    for ((dev, ms) in incPerDevice) pd[dev] = maxOf(pd[dev] ?: 0L, ms)
                    table[raw.key] = cur.copy(
                        title = cur.title.ifBlank { raw.title },
                        artworkUrl = cur.artworkUrl.ifBlank { raw.artworkUrl },
                        feedUrl = cur.feedUrl.ifBlank { raw.feedUrl },
                        perDevice = pd
                    )
                }
            }
            com.yuyin.reverb.util.Logger.i("ListenStats", "merge ${incoming.size} channels (per-device max)")
            persist()
            publish()
        }
    }

    /**
     * 首启种子：无既有统计时，用现有历史（每集 played?durationMs:positionMs）按频道求和做近似初值。
     *
     * 注意：种子记在**固定的 SEED_KEY 格**而非本机格。因为历史本身会被备份合并，两台设备可能
     * 从同一份历史各自种子；若记在各自名下就会相加翻倍。共用一格 + 合并取 max ⇒ 取较大的估算值，
     * 不会重复统计（代价：两台设备听的是完全不同的旧内容时，估算会偏保守）。
     */
    fun seedFromHistory(history: List<HistoryEntry>) {
        synchronized(lock) {
            if (table.isNotEmpty()) return
            if (history.isEmpty()) return
            for (h in history) {
                val ms = if (h.played) maxOf(h.durationMs, h.positionMs) else h.positionMs
                if (ms <= 0) continue
                val k = keyFor(h.episode)
                val cur = table[k] ?: ChannelListen(k, h.episode.podcastTitle, h.episode.artworkUrl, h.episode.feedUrl)
                val pd = HashMap(cur.perDevice)
                pd[SEED_KEY] = (pd[SEED_KEY] ?: 0L) + ms
                table[k] = cur.copy(perDevice = pd)
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

    private fun load(): List<Pair<ChannelListen, Long>> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<Pair<ChannelListen, Long>>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(ChannelListenJson.parse(o))
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun persist() {
        try {
            val arr = JSONArray()
            for (c in table.values) arr.put(ChannelListenJson.toJson(c))
            file.writeText(arr.toString())
        } catch (e: Exception) {
        }
    }
}
