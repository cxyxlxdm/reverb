package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.FeedResult
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 频道详情（解析后的 RSS）的磁盘缓存，按 feedUrl。
 *
 * 解决两件事：
 *  1. **断网可看**：此前进频道详情只能等网络，失败即"加载失败"整页空 —— 哪怕是自己订阅、
 *     刚看过的频道也一样。现在先出缓存内容，再后台刷新。
 *  2. **秒开**：详情页原本每次都从 Loading 开始（RSS 动辄几百 KB，慢的要两三秒）。
 *
 * 容量有意收紧（RSS 是这个 App 里最大的数据）：最多 [MAX_FEEDS] 个频道，每个频道最多
 * [MAX_EPISODES] 集，超出按最近访问时间淘汰。整体量级 ~1-2MB，计入设置页的缓存大小。
 */
class FeedCacheStore(context: Context) {

    /** 一条缓存：解析结果 + 落缓存的时刻（用于"上次更新于"提示与淘汰排序）。 */
    class Entry(val result: FeedResult, val fetchedAt: Long)

    private val file = File(context.filesDir, "feed_cache.json")
    private val lock = Any()
    private val mem: LinkedHashMap<String, Entry> = load()

    fun get(feedUrl: String): Entry? = mem[feedUrl]

    /** 写入并按容量淘汰。episodes 超量时只留最前面的（RSS 本身按时间倒序）。 */
    fun put(feedUrl: String, result: FeedResult) {
        if (feedUrl.isBlank() || result.episodes.isEmpty()) return
        synchronized(lock) {
            val trimmed = if (result.episodes.size <= MAX_EPISODES) result
            else FeedResult(result.podcast, result.episodes.take(MAX_EPISODES))
            mem.remove(feedUrl)   // 重新插入到尾部，使迭代顺序即"最近写入"顺序
            mem[feedUrl] = Entry(trimmed, System.currentTimeMillis())
            while (mem.size > MAX_FEEDS) {
                val oldest = mem.keys.firstOrNull() ?: break
                mem.remove(oldest)
            }
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

    private fun load(): LinkedHashMap<String, Entry> {
        val out = LinkedHashMap<String, Entry>()
        if (!file.exists()) return out
        try {
            val root = JSONObject(file.readText())
            // 按 fetchedAt 升序装载，让内存里的迭代顺序与淘汰顺序一致（最旧在前）
            val items = ArrayList<Pair<String, Entry>>()
            val keys = root.keys()
            while (keys.hasNext()) {
                val url = keys.next()
                val o = root.optJSONObject(url) ?: continue
                val podcastObj = o.optJSONObject("podcast") ?: continue
                val arr = o.optJSONArray("episodes") ?: JSONArray()
                val episodes = ArrayList<Episode>(arr.length())
                for (i in 0 until arr.length()) {
                    arr.optJSONObject(i)?.let { episodes.add(EpisodeJson.fromJson(it)) }
                }
                if (episodes.isEmpty()) continue
                items.add(
                    url to Entry(
                        FeedResult(PodcastJson.fromJson(podcastObj), episodes),
                        o.optLong("fetchedAt", 0L)
                    )
                )
            }
            items.sortBy { it.second.fetchedAt }
            for ((url, entry) in items) out[url] = entry
            com.yuyin.reverb.util.Logger.i(TAG, "feed cache loaded feeds=${out.size}")
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "feed cache load failed: ${e.message}")
            out.clear()
        }
        return out
    }

    /**
     * 去抖异步写。**先取快照**:mem 是可变 Map,而一轮「最新」刷新会逐源 put 十几次,
     * 把遍历推迟到 IO 线程会撞上并发修改(鸿蒙那边同样的地方也是这么处理的)。
     * 快照是浅拷贝,真正贵的是后面的 JSON 构造 —— 那部分才是要挪走的。
     */
    private fun persist() {
        val snapshot = mem.toList()
        JsonWriter.write(file) {
            val root = JSONObject()
            for ((url, entry) in snapshot) {
                val eps = JSONArray()
                for (e in entry.result.episodes) eps.put(EpisodeJson.toJson(e))
                root.put(
                    url,
                    JSONObject()
                        .put("fetchedAt", entry.fetchedAt)
                        .put("podcast", PodcastJson.toJson(entry.result.podcast))
                        .put("episodes", eps)
                )
            }
            root.toString()
        }
    }

    private companion object {
        const val MAX_FEEDS = 30
        const val MAX_EPISODES = 60
        const val TAG = "FeedCache"
    }
}
