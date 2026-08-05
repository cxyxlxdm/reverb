package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.data.remote.PodcastRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * 「最新」收件箱:合并所有订阅的最新单集,按发布时间倒序,最多 100 条,持久化到 inbox.json。
 * 打开即用缓存秒显,再后台刷新替换。零后端,直接抓各订阅的 RSS。
 */
class InboxStore(context: Context) {
    private val file = File(context.filesDir, "inbox.json")
    private val lock = Any()
    private val max = 100
    private val parallelism = 4 // 有限并发,避免同时打开过多连接

    private val _episodes = MutableStateFlow(load())
    val episodes: StateFlow<List<Episode>> = _episodes

    @Volatile private var refreshing = false

    /** 抓取所有订阅的最新单集并合并。并发受限,失败的订阅跳过。 */
    suspend fun refresh(subs: List<Podcast>, repo: PodcastRepository) {
        if (subs.isEmpty()) {
            synchronized(lock) { _episodes.value = emptyList(); persist(emptyList()) }
            return
        }
        if (refreshing) return
        refreshing = true
        val log = com.yuyin.reverb.util.Logger
        log.i(TAG, "refresh start subs=${subs.size}")
        try {
            val gate = Semaphore(parallelism)
            val perFeed = coroutineScope {
                subs.map { p ->
                    async(Dispatchers.IO) {
                        gate.withPermit {
                            try {
                                repo.feed(p.feedUrl)?.episodes ?: emptyList()
                            } catch (e: Exception) {
                                log.w(TAG, "feed failed title='${p.title}' url=${p.feedUrl}")
                                emptyList()
                            }
                        }
                    }
                }.awaitAll()
            }
            val merged = perFeed.flatten()
                .distinctBy { it.id }
                .sortedByDescending { parsePubMillis(it.pubDate) }
                .take(max)
            synchronized(lock) {
                _episodes.value = merged
                persist(merged)
            }
            log.i(TAG, "refresh done episodes=${merged.size}")
        } finally {
            refreshing = false
        }
    }

    private fun load(): List<Episode> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<Episode>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(EpisodeJson.fromJson(o))
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun persist(list: List<Episode>) {
        try {
            val arr = JSONArray()
            for (e in list) arr.put(EpisodeJson.toJson(e))
            file.writeText(arr.toString())
        } catch (e: Exception) {
            // 持久化失败不影响内存态,忽略
        }
    }

    private companion object {
        const val TAG = "InboxStore"

        // RSS 发布时间常见 RFC-822,iTunes 走 ISO/日期;逐个尝试解析,失败按 0(排最后)。
        private val patterns = listOf(
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        )

        fun parsePubMillis(raw: String): Long {
            val s = raw.trim()
            if (s.isBlank()) return 0
            for (p in patterns) {
                try {
                    val fmt = SimpleDateFormat(p, Locale.ENGLISH)
                    return fmt.parse(s)?.time ?: continue
                } catch (e: Exception) {
                    // 尝试下一个格式
                }
            }
            return 0
        }
    }
}
