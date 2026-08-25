package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Podcast
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 发现页热门列表的磁盘缓存（按分类 key）。用于「先展示缓存、再后台刷新」：
 * 进 App 立即拿到上次结果，网络回来后再替换，避免每次都空等。
 * 启动时一次性读入内存，之后读取零 IO。
 */
class PopularCacheStore(context: Context) {

    private val file = File(context.filesDir, "popular_cache.json")
    private val lock = Any()
    private val mem: MutableMap<String, List<Podcast>> = load()

    fun get(key: String): List<Podcast> = mem[key] ?: emptyList()

    fun put(key: String, list: List<Podcast>) {
        if (list.isEmpty()) return
        synchronized(lock) {
            mem[key] = list
            persist()
        }
    }

    fun clear() {
        synchronized(lock) {
            mem.clear()
            runCatching { file.delete() }
        }
    }

    fun sizeBytes(): Long = if (file.exists()) file.length() else 0L

    private fun load(): MutableMap<String, List<Podcast>> {
        if (!file.exists()) return mutableMapOf()
        return try {
            val root = JSONObject(file.readText())
            val map = mutableMapOf<String, List<Podcast>>()
            val keys = root.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val arr = root.optJSONArray(k) ?: continue
                map[k] = arr.toPodcasts()
            }
            map
        } catch (e: Exception) {
            mutableMapOf()
        }
    }

    /// 去抖异步写;先取快照(理由同 FeedCacheStore.persist)
    private fun persist() {
        val snapshot = mem.toList()
        JsonWriter.write(file) {
            val root = JSONObject()
            for ((k, list) in snapshot) root.put(k, list.toJsonArray())
            root.toString()
        }
    }

    private fun JSONArray.toPodcasts(): List<Podcast> {
        val out = ArrayList<Podcast>(length())
        for (i in 0 until length()) {
            val o = optJSONObject(i) ?: continue
            out.add(
                Podcast(
                    id = o.optString("id"),
                    title = o.optString("title"),
                    author = o.optString("author"),
                    artworkUrl = o.optString("artworkUrl"),
                    feedUrl = o.optString("feedUrl"),
                    description = o.optString("description"),
                    genre = o.optString("genre"),
                    isPaid = o.optBoolean("isPaid", false),
                    fundingUrl = o.optString("fundingUrl"),
                    fundingLabel = o.optString("fundingLabel")
                )
            )
        }
        return out
    }

    private fun List<Podcast>.toJsonArray(): JSONArray {
        val arr = JSONArray()
        for (p in this) {
            arr.put(
                JSONObject()
                    .put("id", p.id)
                    .put("title", p.title)
                    .put("author", p.author)
                    .put("artworkUrl", p.artworkUrl)
                    .put("feedUrl", p.feedUrl)
                    .put("description", p.description)
                    .put("genre", p.genre)
                    .put("isPaid", p.isPaid)
                    .put("fundingUrl", p.fundingUrl)
                    .put("fundingLabel", p.fundingLabel)
            )
        }
        return arr
    }
}
