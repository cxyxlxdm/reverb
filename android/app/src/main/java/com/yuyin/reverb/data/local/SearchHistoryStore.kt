package com.yuyin.reverb.data.local

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import java.io.File

/**
 * 搜索历史:`filesDir/search_history.json`,最近 [LIMIT] 条,新的在前。
 *
 * **只在本机留存**:不进手动备份、不进局域网同步、不进系统备份(白名单里没有它)。
 * 理由:它是"这台设备上顺手搜过什么"的快捷方式,含用户自己的关键词,换机代价远低于
 * 把它带进同步协议与备份格式的成本。删除传播因此也不需要墓碑(与 `StationStore` 同一口径)。
 *
 * 写入时机只有一个:**真正发起检索**时(见 `DiscoverViewModel.search`)。输入到一半、
 * 粘贴了却不提交都不记 —— 否则历史里会塞满半截词。
 */
class SearchHistoryStore(context: Context) {

    private val file = File(context.filesDir, "search_history.json")
    private val lock = Any()

    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<String>> = _items

    /** 记一条。去重(同词提到最前)、限长、最多留 [LIMIT] 条。 */
    fun record(raw: String) {
        val q = clean(raw)
        if (q.isEmpty()) return
        synchronized(lock) {
            val next = _items.value.filterNot { it == q }.toMutableList().apply { add(0, q) }
            val capped = if (next.size > LIMIT) next.subList(0, LIMIT).toList() else next
            _items.value = capped
            persist(capped)
        }
    }

    fun remove(query: String) {
        synchronized(lock) {
            val current = _items.value
            val next = current.filterNot { it == query }
            if (next.size == current.size) return
            _items.value = next
            persist(next)
        }
    }

    fun clear() {
        synchronized(lock) {
            if (_items.value.isEmpty()) return
            _items.value = emptyList()
            persist(emptyList())
        }
    }

    private fun load(): List<String> {
        val text = runCatching { file.readText() }.getOrNull() ?: return emptyList()
        val arr = runCatching { JSONArray(text) }.getOrNull() ?: return emptyList()
        val out = ArrayList<String>(arr.length())
        for (i in 0 until arr.length()) {
            val q = arr.optString(i, "").trim()
            if (q.isNotEmpty() && q !in out) out.add(q)
            if (out.size >= LIMIT) break
        }
        return out
    }

    private fun persist(list: List<String>) {
        runCatching {
            val arr = JSONArray()
            list.forEach { arr.put(it) }
            val tmp = File(file.parentFile, "${file.name}.tmp")
            tmp.writeText(arr.toString())
            if (!tmp.renameTo(file)) {
                file.writeText(arr.toString())
                tmp.delete()
            }
        }
    }

    private fun clean(raw: String): String =
        raw.trim().take(MAX_LENGTH)

    companion object {
        /** 与 macOS / iOS `SearchHistoryStore.limit` 一致。 */
        const val LIMIT = 20
        private const val MAX_LENGTH = 100
    }
}
