package com.yuyin.reverb.sync

import android.content.Context
import com.yuyin.reverb.util.Logger
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 删除墓碑账本:让「这台设备上删掉的条目」不会在下一次同步时被对端带回来。
 *
 * 为什么需要它:备份 v1 的六段是**并集**语义,合并只看"现在有什么",没有"什么时候被删掉"。
 * 单人换机场景下这不是问题(旧备份本来就有),但两台设备日常同步时,甲退订的节目会被乙原样带回来,
 * 而且永远删不掉 —— 这是集合同步的硬伤,见 `docs/research/2026-11-11-lan-sync.md` §5。
 *
 * 形状只有一个:按 `kind + id` 记 `deletedAt`(毫秒),保留 90 天:
 *  - 只记**可删除的集合**:订阅 / 收藏 / 印章 / 批注。历史是 LWW、收听统计按设备取 max,
 *    它们本来就不是"删一条"的语义;
 *  - 订阅的 id 用 **feedUrl 归一化**后的串(与同步去重同一个判据),因为同一频道在不同端
 *    可能一个用 `collectionId`、一个用 `feedUrl` 当 `id`;
 *  - 本地**重新添加**同一项时清掉墓碑(用户改主意了,不能还被自己 90 天前的删除压着)。
 *
 * 账本随全量快照一起传(键名 `tombstones`),否则新设备从对端快照恢复后仍会把旧条目带回来。
 * 合并 = 两边按 key 取较晚的 `deletedAt`,再剪掉过期的。
 *
 * 已知边界(与 Apple 端同一条):墓碑**优先于**对端快照里的同 id 条目。A 删除、B 在同步前
 * 重新订阅,下一次同步仍会被墓碑压掉 —— 订阅与收藏没有 `updatedAt`,"重新添加"无法证明
 * 自己比删除更晚。要彻底解决得给每条记录带 HLC(见研究文档),这一版先按墓碑优先。
 */
object SyncTombstones {
    const val SUBSCRIPTIONS = "subscriptions"
    const val FAVORITES = "favorites"
    const val STAMPS = "stamps"
    const val NOTES = "notes"

    private const val FILE_NAME = "sync_tombstones.json"
    private const val RETENTION_MS = 90L * 24 * 60 * 60 * 1000L
    private const val SEP = "\u0000"

    private val lock = Any()
    private var file: File? = null
    /** key = kind + SEP + id,value = deletedAt(毫秒)。 */
    private val entries = HashMap<String, Long>()

    /** 由 `AppContainer` 在启动时调一次;没配置过时所有操作都是空转(单测里直接 new store 不会碰盘)。 */
    fun configure(context: Context) {
        synchronized(lock) {
            file = File(context.filesDir, FILE_NAME)
            load()
        }
    }

    fun record(kind: String, id: String, now: Long = System.currentTimeMillis()) {
        if (kind.isBlank() || id.isBlank()) return
        synchronized(lock) {
            prune(now)
            entries[key(kind, id)] = now
            save()
        }
    }

    /** 本地重新添加时调用:墓碑清掉,否则下一次同步会把这项再删一次。 */
    fun clear(kind: String, id: String) {
        if (kind.isBlank() || id.isBlank()) return
        synchronized(lock) {
            if (entries.remove(key(kind, id)) != null) save()
        }
    }

    /**
     * 并入远端快照里的 `tombstones`(可以没有),剪掉过期项并落盘。
     * 返回后 `ids(kind)` 就是"两边合起来仍然有效的删除"。
     */
    fun merge(remote: JSONArray?, now: Long = System.currentTimeMillis()) {
        synchronized(lock) {
            if (remote != null) {
                for (i in 0 until remote.length()) {
                    val o = remote.optJSONObject(i) ?: continue
                    val kind = o.optString("kind")
                    val id = o.optString("id")
                    val at = o.optLong("deletedAt", 0L)
                    if (kind.isBlank() || id.isBlank() || at <= 0L) continue
                    val k = key(kind, id)
                    val prev = entries[k]
                    if (prev == null || at > prev) entries[k] = at
                }
            }
            prune(now)
            save()
        }
    }

    fun ids(kind: String, now: Long = System.currentTimeMillis()): Set<String> {
        synchronized(lock) {
            prune(now)
            return entries.keys.mapNotNull { decode(it) }
                .filter { it.first == kind }
                .map { it.second }
                .toSet()
        }
    }

    /** 快照里要带的那一段。空账本也返回空数组 —— 形状固定,对端不必判空。 */
    fun snapshot(now: Long = System.currentTimeMillis()): JSONArray {
        synchronized(lock) {
            prune(now)
            val arr = JSONArray()
            for ((k, at) in entries) {
                val (kind, id) = decode(k) ?: continue
                arr.put(JSONObject().put("kind", kind).put("id", id).put("deletedAt", at))
            }
            return arr
        }
    }

    /** 订阅的墓碑键:`feedUrl` 归一化优先,没有可用 URL 时退回频道 id(与同步去重同一判据)。 */
    fun subscriptionKey(feedUrl: String, fallbackId: String): String =
        normalizeFeed(feedUrl) ?: fallbackId

    /**
     * 认源不认写法:尾部斜杠与**协议/主机名**大小写不该让同一个源变成两条。
     * 路径部分大小写敏感,不能一起小写。与 `LanSyncMerge` / Apple 端逐条一致。
     */
    fun normalizeFeed(feedUrl: String): String? {
        val t = feedUrl.trim()
        if (t.isEmpty()) return null
        val stripped = t.removeSuffix("/")
        val m = Regex("^([a-zA-Z][a-zA-Z0-9+.\\-]*://)([^/?#]*)").find(stripped)
        return if (m != null) {
            val rest = stripped.substring(m.range.last + 1)
            m.groupValues[1].lowercase() + m.groupValues[2].lowercase() + rest
        } else {
            stripped
        }
    }

    private fun key(kind: String, id: String) = kind + SEP + id

    private fun decode(k: String): Pair<String, String>? {
        val i = k.indexOf(SEP)
        if (i <= 0 || i == k.lastIndex) return null
        return k.substring(0, i) to k.substring(i + 1)
    }

    private fun prune(now: Long) {
        val cutoff = now - RETENTION_MS
        entries.entries.removeAll { it.value < cutoff }
    }

    private fun load() {
        entries.clear()
        val f = file ?: return
        if (!f.exists()) return
        try {
            val root = JSONObject(f.readText())
            val arr = root.optJSONArray("items") ?: return
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val kind = o.optString("kind")
                val id = o.optString("id")
                val at = o.optLong("deletedAt", 0L)
                if (kind.isBlank() || id.isBlank() || at <= 0L) continue
                entries[key(kind, id)] = at
            }
            prune(System.currentTimeMillis())
        } catch (e: Exception) {
            // 账本是派生数据:读坏了按空处理,最坏结果是"这一次同步可能复活一条已删项",
            // 不值得像订阅那样留证与服务降级。
            Logger.w("Sync", "墓碑账本读取失败,按空处理:${e.message}")
        }
    }

    private fun save() {
        val f = file ?: return
        val out = JSONObject()
        val arr = JSONArray()
        for ((k, at) in entries) {
            val (kind, id) = decode(k) ?: continue
            arr.put(JSONObject().put("kind", kind).put("id", id).put("deletedAt", at))
        }
        out.put("version", 1).put("items", arr)
        try {
            val tmp = File(f.parentFile, f.name + ".part")
            tmp.writeText(out.toString())
            if (!tmp.renameTo(f)) {
                f.writeText(out.toString())
                tmp.delete()
            }
        } catch (e: Exception) {
            Logger.w("Sync", "墓碑账本写入失败:${e.message}")
        }
    }
}
