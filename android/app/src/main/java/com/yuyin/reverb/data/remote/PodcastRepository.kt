package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.FeedCredential
import com.yuyin.reverb.data.model.FeedResult
import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

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
    private val client: okhttp3.OkHttpClient,
    private val cache: com.yuyin.reverb.data.local.PopularCacheStore,
    private val seed: com.yuyin.reverb.data.local.SeedCatalog,
    private val feedCache: com.yuyin.reverb.data.local.FeedCacheStore,
    private val authStore: com.yuyin.reverb.data.local.FeedAuthStore,
    private val thirdPartyContentEnabled: () -> Boolean = { false }
) {
    private val itunes = ITunesSource(client)
    private val fyyd = FyydSource(client)
    private val gpodder = GpodderSource(client)
    private val charts = AppleChartsSource(client, itunes)
    private val rss = RssParser(client)
    /** 视频当播客听。播放前解析也走它(见 [com.yuyin.reverb.playback.PlayerController])。 */
    val bilibili = BilibiliSource(client)
    /** 直播流(A 档):粘一个音频流地址,直接当一路直播放。只在检索全部落空之后才探测。 */
    val live = LiveStreamSource(client)

    /**
     * 某个源回了 401 且手头没有可用凭据时发出它的 feedUrl。
     *
     * 用事件而不是改返回值:调用方有检索、详情页、订阅巡检、电台随机四类,把
     * `FeedResult?` 改成 sealed 会把这条"只在界面上需要"的信号扩散到所有层。
     * 没有界面在听时(后台巡检)tryEmit 丢了也无害 —— 下次进详情页会再触发一次。
     */
    private val _authRequired = kotlinx.coroutines.flow.MutableSharedFlow<String>(extraBufferCapacity = 8)
    val authRequired: kotlinx.coroutines.flow.SharedFlow<String> = _authRequired

    private val log = com.yuyin.reverb.util.Logger
    private val TAG = "Repo"

    /**
     * 一次 feed 抓取的失败分类,给界面区分「数据源暂不可用」与「这一档确实没内容」。
     *
     * 用一次性取走的 map 而不是改 [feed] 的返回值:调用方有详情页、粘贴链接、后台巡检好几路,
     * 把 `FeedResult?` 改成 sealed 会让这条只在界面上需要的信号扩散到所有层(与 401 那条同理)。
     * 按 url 记账,后台巡检先失败也不会盖掉详情页正在看的那一次。
     */
    data class FeedFailure(
        val kind: Kind,
        val host: String = "",
        val code: Int = 0,
        val contentType: String = ""
    ) {
        enum class Kind { PLATFORM_BLOCKED, HTTP_ERROR, NETWORK, PARSE, UNAUTHENTICATED }
    }

    private val feedFailures = ConcurrentHashMap<String, FeedFailure>()

    /** 取走即清,避免上一次的失败被挂到这一次成功的页面上。 */
    fun consumeFeedFailure(feedUrl: String): FeedFailure? = feedFailures.remove(cleanUrl(feedUrl))

    /**
     * 平台级拦截的短期熔断。已识别成拦截的域 60 秒内不再连发请求 —— 同一域连试 1/2/4 秒
     * 只会得到同样的拦页面,还把用户流量和对方日志都刷一遍(见 TROUBLESHOOTING 的 RSS 拦截条)。
     */
    private val blockedHosts = ConcurrentHashMap<String, Long>()

    /**
     * feed 抓取 + 指数退避。首枪失败后 1s / 2s / 4s 各补一次,四次都拿不到才返回 null。
     *
     * 为什么不是无限重试:RSS 动辄几百 KB,真被拦或真断网时重试一百次也不会好,而瞬时抖动
     * (切基站、Wi-Fi 掉一拍)基本落在第一枪之后的 1 秒内。401(要用户输凭据)与平台拦截
     * (短期熔断)都直接跳出,这两类重试没有意义。
     */
    private suspend fun fetchWithRetry(
        url: String,
        auth: FeedCredential?,
        onUnauthorized: () -> Unit
    ): FeedResult? {
        val host = hostOf(url)
        feedFailures.remove(url)
        val now = System.currentTimeMillis()
        val until = blockedHosts[host] ?: 0L
        if (now < until) {
            rss.recordBlocked(url, host, 0, "")
            feedFailures[url] = FeedFailure(FeedFailure.Kind.PLATFORM_BLOCKED, host)
            log.w(TAG, "feed 熔断中 host=$host 剩余=${until - now}ms url=$url")
            return null
        }
        val delays = longArrayOf(0L, 1_000L, 2_000L, 4_000L)
        var attempt = 0
        while (attempt < delays.size) {
            if (attempt > 0) delay(delays[attempt])
            attempt++
            val result = rss.fetch(url, auth, onUnauthorized)
            if (result != null) return result
            val failure = rss.consumeFailure(url)?.let { translate(it, host) }
                ?: FeedFailure(FeedFailure.Kind.NETWORK, host)
            feedFailures[url] = failure
            when (failure.kind) {
                FeedFailure.Kind.PLATFORM_BLOCKED -> {
                    blockedHosts[host] = System.currentTimeMillis() + BLOCK_WINDOW_MS
                    log.w(
                        TAG,
                        "feed 平台拦截,熔断 host=$host ${BLOCK_WINDOW_MS}ms status=${failure.code} " +
                            "contentType='${failure.contentType}' url=$url"
                    )
                    break
                }
                FeedFailure.Kind.UNAUTHENTICATED -> break // 要用户补凭据,重试没有意义
                else -> log.w(TAG, "feed 第 $attempt/${delays.size} 次失败 kind=${failure.kind} status=${failure.code} url=$url")
            }
        }
        return null
    }

    private fun translate(f: RssParser.Failure, host: String): FeedFailure = when (f) {
        is RssParser.Failure.Blocked -> FeedFailure(
            FeedFailure.Kind.PLATFORM_BLOCKED, f.host.ifBlank { host }, f.code, f.contentType
        )
        is RssParser.Failure.HttpError -> FeedFailure(FeedFailure.Kind.HTTP_ERROR, host, f.code)
        RssParser.Failure.NetworkError -> FeedFailure(FeedFailure.Kind.NETWORK, host)
        RssParser.Failure.ParseError -> FeedFailure(FeedFailure.Kind.PARSE, host)
        RssParser.Failure.Unauthorized -> FeedFailure(FeedFailure.Kind.UNAUTHENTICATED, host, 401)
    }

    private fun hostOf(url: String): String = runCatching {
        java.net.URI(url).host
    }.getOrNull()?.ifBlank { null }
        ?: url.substringAfter("://").substringBefore('/').ifBlank { url }

    @Volatile
    private var directoryGeneration = 0L

    /** 开关变化或恢复备份时调用,让已经发出的目录请求在返回后失效。 */
    fun invalidateDirectory() {
        directoryGeneration++
    }

    fun directoryToken(): Long? {
        if (!directoryEnabled()) {
            invalidateDirectory()
            return null
        }
        return directoryGeneration
    }

    fun directoryCurrent(token: Long): Boolean =
        token == directoryGeneration && directoryEnabled()

    data class SearchOutcome(
        val podcasts: List<Podcast>,
        val sourceLabel: String,
        val failed: Boolean = false
    )

    suspend fun search(query: String, region: String = ""): SearchOutcome {
        val q = query.trim()
        if (q.isBlank()) return SearchOutcome(emptyList(), "")
        // 只记词数,不记原文 —— 已发布的隐私政策第二节承诺「日志不记录搜索词」,
        // 而日志是用户可一键导出的。词数足够定位「搜了个短的/长的」这类问题。
        // 鸿蒙 net/PodcastRepository.ets 早就是这个形态(只记命中条数),这里是补齐而不是新口径。
        val words = q.split(Regex("\\s+")).count { it.isNotEmpty() }
        log.i(TAG, "search queryWords=$words region='$region'")

        // 0) 视频页地址(BV 号本体 / 完整 URL / b23.tv 短链)排在最前:它既是「用户点名的那一条」,
        //    也永远解析不出 RSS —— 先跑 RSS 只会白等一次超时。
        //    这一步**不受 CATALOG 闸管** —— 粘链接不是"下拉就能翻到的目录",与关键词检索不是一回事。
        if (BilibiliSource.looksLikeVideo(q)) {
            bilibili.resolveInput(q)?.let {
                log.i(TAG, "search via Bilibili ok parts=${it.episodes.size}")
                return SearchOutcome(listOf(it.podcast), "Bilibili")
            }
        }

        // 1) 直接是订阅源地址
        if (q.startsWith("http://", true) || q.startsWith("https://", true)) {
            // `https://user:pass@host/feed.xml` 是私有源最常见的粘贴形态(见 H253)。
            // 凭据要从 URL 里拆出来:它不该进订阅、备份与日志,只该进本机凭据账本。
            val (url, inline) = FeedCredential.splitUrl(q)
            val fetched = rss.fetch(url, inline ?: authStore.get(url)) { _authRequired.tryEmit(url) }
            if (fetched != null) {
                // 只在**确实读到了内容**之后才落盘:401 的那对错凭据不该覆盖原有的
                if (inline != null) authStore.save(url, inline)
                log.i(TAG, "search via RSS ok title='${fetched.podcast.title}'")
                return SearchOutcome(listOf(fetched.podcast), "RSS")
            }
        }

        // 关掉内容目录(`CATALOG=false`)的那份包到此为止:关键词检索返回的是节目列表,
        // 同样构成动态目录。用 BuildConfig 这个**编译期常量**做门,R8 会把下面整段连同
        // iTunes/fyyd/gpodder 三个数据源一起消掉 —— 那个 APK 里因此连目录接口的地址字符串
        // 都不存在,而不只是"界面上点不到"。(合并前这是商店渠道的常态,现在是备用闸,见 H205)
        if (!com.yuyin.reverb.BuildConfig.CATALOG) {
            return SearchOutcome(emptyList(), "", failed = true)
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

        log.w(TAG, "search failed, no result (queryWords=$words)")
        return SearchOutcome(emptyList(), "", failed = true)
    }

    /** 按关键字检索单集（可直接播放）。URL 输入直接指向频道，不参与单集检索。 */
    suspend fun searchEpisodes(query: String, region: String = ""): List<Episode> {
        // 关掉内容目录那一档不做单集检索(同 search 的理由);编译期常量门 → R8 剔掉 ITunesSource
        if (!com.yuyin.reverb.BuildConfig.CATALOG) return emptyList()
        val q = query.trim()
        if (q.isBlank() || q.startsWith("http", true)) return emptyList()
        log.i(TAG, "searchEpisodes queryWords=${q.split(Regex("\\s+")).count { it.isNotEmpty() }} region='$region'")
        val out = ArrayList<Episode>(itunes.searchEpisodes(q, region))
        // B 站的视频粒度和「单集」是同一件事,直接并进这一路。**受 CATALOG 闸管**:
        // 关键词检索拿到的是动态目录,与 Apple/fyyd/gpodder 同一口径(见 search() 里的那段注释)。
        // 搜索失败不拖垮整列 —— 上面的 Apple 结果照常返回。
        runCatching { bilibili.searchEpisodes(q) }
            .onSuccess { out.addAll(it) }
            .onFailure { log.w(TAG, "bilibili searchEpisodes failed") }
        log.i(TAG, "searchEpisodes count=${out.size}")
        return out
    }

    // 发现页热门推荐：磁盘缓存(按 地区+分类) + 每日刷新。cachedPopular 立即返回上次结果，refreshPopular 走网络并回写。
    private fun cacheKey(genreId: Int?, region: String) = "$region:${genreId ?: "default"}"

    /**
     * 立即返回可展示的列表，供进入页面时秒开。优先真实缓存；缓存为空（首装/清过缓存/一直无网）
     * 则回退到随包内置清单，保证首屏不空。种子**只读不写缓存**，联网刷新成功即被真数据取代。
     */
    fun cachedPopular(genreId: Int? = null, region: String = "us"): List<Podcast> {
        if (!directoryEnabled()) return emptyList()
        val real = cache.get(cacheKey(genreId, region))
        if (real.isNotEmpty()) return real
        return seed.get(genreId, region)
    }

    /** 当前展示的是内置清单（而非联网取回的真榜单）——UI 据此把标题标成「内置精选」。 */
    fun isSeedList(genreId: Int? = null, region: String = "us"): Boolean {
        if (!directoryEnabled()) return false
        return cache.get(cacheKey(genreId, region)).isEmpty() && seed.get(genreId, region).isNotEmpty()
    }

    /** 内置清单的生成日期（yyyy-MM-dd）。 */
    fun seedGeneratedAt(): String = if (directoryEnabled()) seed.generatedAt() else ""

    /** 拉取最新榜单，成功则回写磁盘缓存并返回；失败返回空（保留旧缓存）。 */
    suspend fun refreshPopular(genreId: Int? = null, region: String = "us"): List<Podcast> {
        val token = directoryToken() ?: return emptyList()
        log.i(TAG, "refreshPopular genre=${genreId ?: "all"} region='$region'")
        var list = if (genreId == null) {
            charts.top(region, 30)
        } else {
            charts.topByGenre(region, genreId, 30)
        }
        if (!directoryCurrent(token)) return emptyList()
        if (list.isEmpty() && genreId == null) {
            if (region != "us") {
                list = charts.top("us", 30)
                if (!directoryCurrent(token)) return emptyList()
            }
            if (list.isEmpty()) {
                list = fyyd.hot(30)
                if (!directoryCurrent(token)) return emptyList()
            }
        }
        if (list.isNotEmpty()) cache.put(cacheKey(genreId, region), list)
        log.i(TAG, "refreshPopular result count=${list.size} genre=${genreId ?: "all"} region='$region'")
        return list
    }

    /**
     * 解析某个 feed。成功则回写磁盘缓存；失败返回 null（旧缓存保留，由调用方决定是否用）。
     * 与 [cachedFeed] 配合成「先缓存秒开、再后台刷新、刷新失败退回缓存」。
     */
    suspend fun feed(feedUrl: String, directoryToken: Long? = null): FeedResult? {
        // 兜底:OPML 导入 / 旧数据 / 界面里手工拼出来的地址都可能带着 userinfo。
        // 缓存键与实际请求都用**去掉凭据**的那一份 —— 否则同一个源会因为"带没带口令"
        // 变成两份缓存,而带口令的那份键会跟着导出备份走。
        val (url, inline) = FeedCredential.splitUrl(feedUrl)
        val result = if (BilibiliSource.isPseudo(url)) {
            bilibili.feedOf(url).also {
                if (it == null) feedFailures[url] = FeedFailure(FeedFailure.Kind.PARSE, hostOf(url))
            }
        } else {
            fetchWithRetry(url, inline ?: authStore.get(url)) { _authRequired.tryEmit(url) }
        }
        if (result != null && inline != null) authStore.save(url, inline)
        if (result == null) log.w(TAG, "feed empty/failed url=$url")
        else {
            log.i(TAG, "feed ok episodes=${result.episodes.size} title='${result.podcast.title}' url=$url")
            if (directoryToken == null || directoryCurrent(directoryToken)) feedCache.put(url, result)
        }
        return result
    }

    /** 界面在 401 弹框里点「保存」之后调用,然后自己重新拉一次。 */
    fun saveAuth(feedUrl: String, username: String, password: String) {
        authStore.save(cleanUrl(feedUrl), FeedCredential(username, password))
    }

    fun forgetAuth(feedUrl: String) = authStore.forget(cleanUrl(feedUrl))

    private fun cleanUrl(raw: String): String = FeedCredential.splitUrl(raw).first

    /** 立即返回上次解析结果（可能过时，可能为 null），供进入详情页时秒开、断网时兜底。 */
    fun cachedFeed(feedUrl: String): FeedResult? = feedCache.get(cleanUrl(feedUrl))?.result

    /** 该 feed 缓存的落盘时刻（毫秒）；无缓存返回 0。用于「上次更新于 X」提示。 */
    fun feedCachedAt(feedUrl: String): Long = feedCache.get(cleanUrl(feedUrl))?.fetchedAt ?: 0L

    /**
     * 取一段纯文本（当前只用于「导入推荐订阅」拉官网那份 OPML）。
     * 失败返回 null，由调用方给出可见提示——这是用户主动触发的动作，静默失败不可接受。
     */
    suspend fun httpText(url: String): String? = withContext(Dispatchers.IO) {
        try {
            val req = okhttp3.Request.Builder()
                .url(url)
                .header("User-Agent", "Reverb/1.0 (Android podcast client)")
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    log.w(TAG, "httpText ${resp.code} url=$url")
                    return@withContext null
                }
                resp.body?.string()
            }
        } catch (e: Exception) {
            log.e(TAG, "httpText failed url=$url", e)
            null
        }
    }

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
        val token = directoryToken() ?: return@withContext null
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
        if (!directoryCurrent(token)) return@withContext null
        // 付费节目分集常为会员专享、拉不到直链,优先排除;全付费时再放开兜底
        val all = pool.values.toList()
        val candidates = all.filterNot { it.isPaid }.ifEmpty { all }
        log.i(TAG, "randomEpisode pool=${all.size} candidates=${candidates.size} region='$region'")
        if (candidates.isEmpty()) { log.w(TAG, "randomEpisode empty pool"); return@withContext null }

        // 3) 随机挑节目 → 解析 RSS → 随机取一集,重试若干档兜底(某档拉不到就换下一档)
        for (p in candidates.shuffled().take(6)) {
            if (!directoryCurrent(token)) return@withContext null
            val feed = feed(p.feedUrl, token) ?: continue
            if (!directoryCurrent(token)) return@withContext null
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

    private fun directoryEnabled(): Boolean =
        com.yuyin.reverb.BuildConfig.CATALOG && thirdPartyContentEnabled()

    companion object {
        /** 平台级拦截的熔断窗口:60 秒足够跨过一次限流,又不至于让用户永远看不到重试。 */
        private const val BLOCK_WINDOW_MS = 60_000L

        /**
         * 三方目录的有效地区。关闭时保留原来的设备 / 覆盖值供关键词搜索使用;
         * 开启后默认美国,只有明确选择 cn 才保留中文地区,hk/tw/mo 及其它未明确项回落 us。
         */
        fun catalogRegion(enabled: Boolean, override: String?, systemCountry: String): String {
            val selected = com.yuyin.reverb.data.local.RegionStore.normalize(override).orEmpty()
            if (!enabled) return (selected.ifBlank { systemCountry.lowercase() }).ifBlank { "us" }
            return if (selected == "cn" || (selected.isNotEmpty() && selected !in setOf("hk", "tw", "mo"))) {
                selected
            } else {
                "us"
            }
        }
    }
}
