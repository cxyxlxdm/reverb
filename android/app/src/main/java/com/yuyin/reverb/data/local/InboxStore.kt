package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.data.remote.PodcastRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
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
    private val perFeedMax = 12 // 每个订阅只取最新 ~12 集,避免大源刷屏、加速合并
    private val parallelism = 8 // 有限并发,兼顾速度与连接数
    private val perFeedTimeoutMs = 8_000L // 单个 feed 超时:避免一个慢源拖垮整体刷新

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
            // 有缓存时:刷新期间不做增量替换(否则可见列表会先坍缩到几条再重建,既跳闪,又会把
            // 下拉刷新的 verticalOffset 顶起、灰色指示器滞留在顶部),后台 build 完在末尾一次性
            // 原子替换(LazyColumn 按 id diff,已有条目位置稳定不跳)。冷启动无缓存时才逐源增量填充。
            val hasCache = _episodes.value.isNotEmpty()
            // 按 id 去重的累积池,每有一个 feed 到位即重排。
            val accumulated = LinkedHashMap<String, Episode>()
            var latest: List<Episode> = emptyList()
            coroutineScope {
                subs.forEach { p ->
                    launch(Dispatchers.IO) {
                        gate.withPermit {
                            val eps = try {
                                // 单源超时兜底:慢源到点即放弃,不阻塞其余订阅的合并
                                withTimeoutOrNull(perFeedTimeoutMs) {
                                    repo.feed(p.feedUrl)?.episodes
                                } ?: emptyList<Episode>().also {
                                    log.w(TAG, "feed timeout title='${p.title}' url=${p.feedUrl}")
                                }
                            } catch (e: Exception) {
                                log.w(TAG, "feed failed title='${p.title}' url=${p.feedUrl}")
                                emptyList()
                            }
                            // 单源限量:只取该订阅最新 ~12 集再并入
                            val capped = eps
                                .sortedByDescending { parsePubMillis(it.pubDate) }
                                .take(perFeedMax)
                            if (capped.isEmpty()) return@withPermit
                            // 统一在 lock 内合并 + 更新 StateFlow,保证线程一致
                            synchronized(lock) {
                                for (e in capped) accumulated[e.id] = e
                                // 稳定排序:日期倒序 + id 次序。各源并行返回顺序不定,若仅按日期排序,
                                // 日期相同/无法解析(=0)的单集相对顺序会随刷新变动,导致内容没变却"闪动"
                                // (StateFlow 判不相等而重排)。加 id 次序使结果确定 → 内容不变即不重渲。
                                latest = accumulated.values
                                    .sortedWith(compareByDescending<Episode> { parsePubMillis(it.pubDate) }
                                        .thenBy { it.id })
                                    .take(max)
                                if (!hasCache) _episodes.value = latest // 冷启动才逐源刷 UI
                            }
                        }
                    }
                }
            }
            // 全部到位后:一次性原子替换 + 落盘。若全部源失败/超时(latest 为空)且已有缓存,
            // 则不用空列表覆盖,避免一次刷新失败把「最新」清空。
            synchronized(lock) {
                if (latest.isNotEmpty() || !hasCache) _episodes.value = latest
                if (latest.isNotEmpty()) persist(latest)
            }
            log.i(TAG, "refresh done episodes=${latest.size}")
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
