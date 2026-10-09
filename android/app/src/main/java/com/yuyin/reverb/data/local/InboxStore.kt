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
 * 「追更」收件箱:合并**所有订阅的全部单集**,按发布时间倒序,持久化到 inbox.json。
 * 打开即用缓存秒显,再后台刷新替换。零后端,直接抓各订阅的 RSS。
 *
 * **内存侧不截断,落盘侧有界**(见 [persist] 那条分工的理由)。
 * 2026-10-10 之前这里是「每源只留最新 12 集 / 全局 100 条」,于是这一页只显示
 * 每个频道的头几集 —— 与"追更 = 管理我订阅的全部内容"的定位不符,用户反馈的正是这个。
 * 顺带一句省不掉的钱:`repo.feed()` 本来就整份下载并解析全量 RSS(`RssParser` 没有条目上限),
 * 那两道截断从来只限制"留下多少条",不省网络也不省解析。实测 20 个订阅源共 7,464 集
 * (中位数 ~200,最大 2,828),所以真正要重新算的是**排序成本**与**落盘体量**,不是流量。
 */
class InboxStore(context: Context) {
    private val file = File(context.filesDir, "inbox.json")
    private val lock = Any()
    private val persistMax = 300 // 落盘只留最新 300 条(内存留全量),理由见 persist
    private val parallelism = 8 // 有限并发,兼顾速度与连接数
    private val perFeedTimeoutMs = 8_000L // 单个 feed 超时:避免一个慢源拖垮整体刷新

    private val _episodes = MutableStateFlow(load())
    val episodes: StateFlow<List<Episode>> = _episodes

    @Volatile private var refreshing = false

    /** 抓取所有订阅的全部单集并合并。并发受限,失败的订阅跳过。 */
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
            // pubDate → 毫秒的**本次刷新**的键表:每集只解析一次,排序比较器只查表。
            // 不这么写的代价见 sortedStable 那条(七千集 × 十万次比较 × 每次构造 SimpleDateFormat)。
            val keys = HashMap<String, Long>()
            var latest: List<Episode> = emptyList()
            // 全量之后的两笔成本,打在日志里让装机能读到(这套数字本机造不出来,要真订阅 + 真网络)。
            // 它们都在 IO 线程 + lock 内,不占主线程;写在这儿是因为**规模刚从 100 条变成几千条**,
            // 不量就不知道哪天它又变成用户口中的"卡"。
            var parseMs = 0L
            var sortMs = 0L
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
                            // 单源**不截断**:这一页要能翻到订阅频道的全部节目(旧口径只留最新 12 集)
                            if (eps.isEmpty()) return@withPermit
                            val tParse = System.currentTimeMillis()
                            val parsed = HashMap<String, Long>(eps.size)
                            for (e in eps) parsed[e.id] = parsePubMillis(e.pubDate)
                            val costParse = System.currentTimeMillis() - tParse
                            // 统一在 lock 内合并 + 更新 StateFlow,保证线程一致
                            synchronized(lock) {
                                for (e in eps) {
                                    accumulated[e.id] = e
                                    val k = parsed[e.id]
                                    if (k != null) keys[e.id] = k
                                }
                                // 稳定排序:日期倒序 + id 次序。各源并行返回顺序不定,若仅按日期排序,
                                // 日期相同/无法解析(=0)的单集相对顺序会随刷新变动,导致内容没变却"闪动"
                                // (StateFlow 判不相等而重排)。加 id 次序使结果确定 → 内容不变即不重渲。
                                val tSort = System.currentTimeMillis()
                                latest = sortedStable(accumulated.values, keys)
                                parseMs += costParse
                                sortMs += System.currentTimeMillis() - tSort
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
            log.i(
                TAG,
                "refresh done episodes=${latest.size} persisted=${minOf(latest.size, persistMax)} " +
                    "parse=${parseMs}ms sort=${sortMs}ms"
            )
        } finally {
            refreshing = false
        }
    }

    /**
     * 稳定全序:发布时间倒序,同值按 id 升序(消闪动,理由见调用处)。
     *
     * 毫秒从 [keys] 查,**不在比较器里调 [parsePubMillis]**:全量之后一轮约七千集,
     * 一次排序的比较次数是十万量级,而 `parsePubMillis` 每次都要 new 一个 `SimpleDateFormat`
     * 再逐个模板试 —— 那是硬规矩 6 那条乘法(调用次数 × 每次成本)炸掉的形状,
     * 原先 100 条时看不出来。查表是 O(1) 且无分配。
     */
    private fun sortedStable(src: Collection<Episode>, keys: Map<String, Long>): List<Episode> {
        val out = ArrayList<Episode>(src.size)
        out.addAll(src)
        out.sortWith(compareByDescending<Episode> { keys[it.id] ?: 0L }.thenBy { it.id })
        return out
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

    /// 去抖异步写(冷启动逐源填充时会连着调多次,只落最后一次);失败静默,不影响内存态。
    ///
    /// **只落最新 [persistMax] 条,而内存里是全量** —— 这是有意的分工,不是漏改:
    ///  1. 这份文件的用处只有「冷启动秒显」,而 [load] 跑在 Application 主线程上
    ///     (`ReverbApp` 构造里 new 出来),七千集整份 JSON 解析就是 H65 那个形状的主线程卡顿;
    ///  2. 体量:每条连 `description`(shownotes 原文)一起存,单条约 7 KB ——
    ///     macOS 那边旧包实测过 `inbox.json` = 747 KB / 100 条,本机 RSS 侧 48.6 MB / 7,464 集
    ///     是同一个量级(见 H168)。**所以全量落盘是几十 MB,不是几 MB。**
    ///     300 条 ≈ 2 MB,是旧那 100 条的三倍 —— 这一倍数是本轮唯一一处"明知变差仍选它"的取舍:
    ///     秒显要覆盖得住"当天打开就往下翻"的深度,而 2 MB 仍在启动路径的几十毫秒量级。
    ///     **装机要盯的就是这一条**:若 `am start -W` 或首帧明显变慢,先降到 100,再谈给冷启动那份裁掉 description。
    ///     另外它排在设置页「清空缓存」与手动备份的旁边,体量要能被那一屏解释。
    /// 因为落的是**排序后的前缀**,秒显阶段看到的就是全量列表的开头,刷新完只做后缀追加,
    /// 不会出现"前 300 条换顺序"。
    /// 代价(如实写在这里):深滚之后杀进程,重进要从头显;要找回那一集得等刷新完再翻,
    /// 或去频道主页(那边本来就是全量)。
    private fun persist(list: List<Episode>) {
        val keep = if (list.size > persistMax) list.subList(0, persistMax) else list
        JsonWriter.write(file) {
            val arr = JSONArray()
            for (e in keep) arr.put(EpisodeJson.toJson(e))
            arr.toString()
        }
    }

    // 非 private:`parsePubDate` 的展示格式化(ui/components/Components.kt)要用这里的
    // parsePubMillis —— 解析 RSS 日期的模板表只该有一份,不要在 UI 层再抄一遍。
    internal companion object {
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
