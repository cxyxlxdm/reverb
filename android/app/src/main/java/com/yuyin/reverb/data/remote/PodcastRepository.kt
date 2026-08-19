package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.FeedResult
import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 源获取的编排层：全链路 **零配置、无需任何 Key、无需登录**，打开即用。
 *
 * 检索降级链（每一层都免费且无鉴权）：
 *   0. 输入本身是 http(s)/RSS 地址 → 直接解析该 RSS（用户手动导入）
 *   1. 默认：Apple iTunes Search API（最稳、中文覆盖好）
 *   2. 兜底①：fyyd.de
 *   3. 兜底②：gpodder.net
 * 发现页推荐：Apple 每日热门榜（换取 feedUrl），失败回退 fyyd 热门。
 * 分集与播放：统一走发布方 RSS 的 enclosure 原始直链。
 */
class PodcastRepository(
    client: okhttp3.OkHttpClient,
    private val cache: com.yuyin.reverb.data.local.PopularCacheStore,
    private val seed: com.yuyin.reverb.data.local.SeedCatalog,
    private val feedCache: com.yuyin.reverb.data.local.FeedCacheStore
) {
    private val itunes = ITunesSource(client)
    private val fyyd = FyydSource(client)
    private val gpodder = GpodderSource(client)
    private val charts = AppleChartsSource(client, itunes)
    private val rss = RssParser(client)

    private val log = com.yuyin.reverb.util.Logger
    private val TAG = "Repo"

    data class SearchOutcome(
        val podcasts: List<Podcast>,
        val sourceLabel: String,
        val failed: Boolean = false
    )

    suspend fun search(query: String, region: String = ""): SearchOutcome {
        val q = query.trim()
        if (q.isBlank()) return SearchOutcome(emptyList(), "")
        log.i(TAG, "search query='$q' region='$region'")

        // 0) 直接是订阅源地址
        if (q.startsWith("http://", true) || q.startsWith("https://", true)) {
            rss.fetch(q)?.let {
                log.i(TAG, "search via RSS ok title='${it.podcast.title}'")
                return SearchOutcome(listOf(it.podcast), "RSS")
            }
        }

        // 1) 默认源 Apple（按地区）
        itunes.search(q, region).let {
            if (it.isNotEmpty()) { log.i(TAG, "search via Apple count=${it.size}"); return SearchOutcome(it, "Apple Podcasts") }
        }

        // 2) 兜底 fyyd.de（无需 Key）
        fyyd.search(q).let {
            if (it.isNotEmpty()) { log.i(TAG, "search via fyyd count=${it.size}"); return SearchOutcome(it, "fyyd.de") }
        }

        // 3) 兜底 gpodder.net（无需 Key）
        gpodder.search(q).let {
            if (it.isNotEmpty()) { log.i(TAG, "search via gpodder count=${it.size}"); return SearchOutcome(it, "gpodder.net") }
        }

        log.w(TAG, "search failed, no result for '$q'")
        return SearchOutcome(emptyList(), "", failed = true)
    }

    /** 按关键字检索单集（可直接播放）。URL 输入直接指向频道，不参与单集检索。 */
    suspend fun searchEpisodes(query: String, region: String = ""): List<Episode> {
        val q = query.trim()
        if (q.isBlank() || q.startsWith("http", true)) return emptyList()
        log.i(TAG, "searchEpisodes query='$q' region='$region'")
        return itunes.searchEpisodes(q, region).also { log.i(TAG, "searchEpisodes count=${it.size}") }
    }

    // 发现页热门推荐：磁盘缓存(按 地区+分类) + 每日刷新。cachedPopular 立即返回上次结果，refreshPopular 走网络并回写。
    private fun cacheKey(genreId: Int?, region: String) = "$region:${genreId ?: "default"}"

    /**
     * 立即返回可展示的列表，供进入页面时秒开。优先真实缓存；缓存为空（首装/清过缓存/一直无网）
     * 则回退到随包内置清单，保证首屏不空。种子**只读不写缓存**，联网刷新成功即被真数据取代。
     */
    fun cachedPopular(genreId: Int? = null, region: String = "us"): List<Podcast> {
        val real = cache.get(cacheKey(genreId, region))
        if (real.isNotEmpty()) return real
        return seed.get(genreId, region)
    }

    /** 当前展示的是内置清单（而非联网取回的真榜单）——UI 据此把标题标成「内置精选」。 */
    fun isSeedList(genreId: Int? = null, region: String = "us"): Boolean =
        cache.get(cacheKey(genreId, region)).isEmpty() && seed.get(genreId, region).isNotEmpty()

    /** 内置清单的生成日期（yyyy-MM-dd）。 */
    fun seedGeneratedAt(): String = seed.generatedAt()

    /** 拉取最新榜单，成功则回写磁盘缓存并返回；失败返回空（保留旧缓存）。 */
    suspend fun refreshPopular(genreId: Int? = null, region: String = "us"): List<Podcast> {
        log.i(TAG, "refreshPopular genre=${genreId ?: "all"} region='$region'")
        var list = if (genreId == null) charts.top(region, 30) else charts.topByGenre(region, genreId, 30)
        if (list.isEmpty() && genreId == null) {
            if (region != "us") list = charts.top("us", 30)
            if (list.isEmpty()) list = fyyd.hot(30)
        }
        if (list.isNotEmpty()) cache.put(cacheKey(genreId, region), list)
        log.i(TAG, "refreshPopular result count=${list.size} genre=${genreId ?: "all"} region='$region'")
        return list
    }

    /**
     * 解析某个 feed。成功则回写磁盘缓存；失败返回 null（旧缓存保留，由调用方决定是否用）。
     * 与 [cachedFeed] 配合成「先缓存秒开、再后台刷新、刷新失败退回缓存」。
     */
    suspend fun feed(feedUrl: String): FeedResult? =
        rss.fetch(feedUrl).also {
            if (it == null) log.w(TAG, "feed empty/failed url=$feedUrl")
            else {
                log.i(TAG, "feed ok episodes=${it.episodes.size} title='${it.podcast.title}' url=$feedUrl")
                feedCache.put(feedUrl, it)
            }
        }

    /** 立即返回上次解析结果（可能过时，可能为 null），供进入详情页时秒开、断网时兜底。 */
    fun cachedFeed(feedUrl: String): FeedResult? = feedCache.get(feedUrl)?.result

    /** 该 feed 缓存的落盘时刻（毫秒）；无缓存返回 0。用于「上次更新于 X」提示。 */
    fun feedCachedAt(feedUrl: String): Long = feedCache.get(feedUrl)?.fetchedAt ?: 0L

    /**
     * 随机电台：从热门榜单节目池里随机挑一档 → 解析其 RSS → 随机取一集可播放单集。
     * 池子优先复用各分类已缓存的榜单(秒取、免联网);不足则补拉一次综合热门榜(冷启动亦可用)。
     * @param genreIds 参与组池的分类(含 null 表示综合榜),一般取用户发现页的分类。
     * @param exclude  最近已播过的单集 id,避免立刻重复。
     */
    suspend fun randomEpisode(
        region: String,
        genreIds: List<Int?>,
        exclude: Set<String> = emptySet()
    ): Episode? = withContext(Dispatchers.IO) {
        // 1) 组建候选节目池:各分类榜单去重(按 feedUrl)。
        //    走 cachedPopular 而非裸缓存 —— 首次安装时缓存为空,内置清单能直接组出池子,
        //    省掉一次榜单往返,冷启动点「随机」不必先等榜单。
        val pool = LinkedHashMap<String, Podcast>()
        for (g in genreIds.distinct()) {
            cachedPopular(g, region).forEach { if (it.feedUrl.isNotBlank()) pool.putIfAbsent(it.feedUrl, it) }
        }
        // 2) 池子太小 → 补拉综合热门榜
        if (pool.size < 10) {
            refreshPopular(null, region).forEach { if (it.feedUrl.isNotBlank()) pool.putIfAbsent(it.feedUrl, it) }
        }
        // 付费节目分集常为会员专享、拉不到直链,优先排除;全付费时再放开兜底
        val all = pool.values.toList()
        val candidates = all.filterNot { it.isPaid }.ifEmpty { all }
        log.i(TAG, "randomEpisode pool=${all.size} candidates=${candidates.size} region='$region'")
        if (candidates.isEmpty()) { log.w(TAG, "randomEpisode empty pool"); return@withContext null }

        // 3) 随机挑节目 → 解析 RSS → 随机取一集,重试若干档兜底(某档拉不到就换下一档)
        for (p in candidates.shuffled().take(6)) {
            val feed = feed(p.feedUrl) ?: continue
            val playable = feed.episodes.filter { it.audioUrl.isNotBlank() && it.id !in exclude }
            if (playable.isNotEmpty()) {
                val picked = playable.random()
                log.i(TAG, "randomEpisode picked podcast='${p.title}' episode='${picked.title}' id=${picked.id}")
                return@withContext picked
            }
        }
        log.w(TAG, "randomEpisode none playable after retries")
        null
    }
}
