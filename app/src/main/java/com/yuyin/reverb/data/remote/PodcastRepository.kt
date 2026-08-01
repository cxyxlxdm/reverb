package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.FeedResult
import com.yuyin.reverb.data.model.Podcast

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
    private val cache: com.yuyin.reverb.data.local.PopularCacheStore
) {
    private val itunes = ITunesSource(client)
    private val fyyd = FyydSource(client)
    private val gpodder = GpodderSource(client)
    private val charts = AppleChartsSource(client, itunes)
    private val rss = RssParser(client)

    data class SearchOutcome(
        val podcasts: List<Podcast>,
        val sourceLabel: String,
        val failed: Boolean = false
    )

    suspend fun search(query: String, region: String = ""): SearchOutcome {
        val q = query.trim()
        if (q.isBlank()) return SearchOutcome(emptyList(), "")

        // 0) 直接是订阅源地址
        if (q.startsWith("http://", true) || q.startsWith("https://", true)) {
            rss.fetch(q)?.let { return SearchOutcome(listOf(it.podcast), "RSS") }
        }

        // 1) 默认源 Apple（按地区）
        itunes.search(q, region).let { if (it.isNotEmpty()) return SearchOutcome(it, "Apple Podcasts") }

        // 2) 兜底 fyyd.de（无需 Key）
        fyyd.search(q).let { if (it.isNotEmpty()) return SearchOutcome(it, "fyyd.de") }

        // 3) 兜底 gpodder.net（无需 Key）
        gpodder.search(q).let { if (it.isNotEmpty()) return SearchOutcome(it, "gpodder.net") }

        return SearchOutcome(emptyList(), "", failed = true)
    }

    // 发现页热门推荐：磁盘缓存(按 地区+分类) + 每日刷新。cachedPopular 立即返回上次结果，refreshPopular 走网络并回写。
    private fun cacheKey(genreId: Int?, region: String) = "$region:${genreId ?: "default"}"

    /** 立即返回缓存（可能为空，也可能是上次的数据），供进入页面时秒开。 */
    fun cachedPopular(genreId: Int? = null, region: String = "us"): List<Podcast> = cache.get(cacheKey(genreId, region))

    /** 拉取最新榜单，成功则回写磁盘缓存并返回；失败返回空（保留旧缓存）。 */
    suspend fun refreshPopular(genreId: Int? = null, region: String = "us"): List<Podcast> {
        var list = if (genreId == null) charts.top(region, 30) else charts.topByGenre(region, genreId, 30)
        if (list.isEmpty() && genreId == null) {
            if (region != "us") list = charts.top("us", 30)
            if (list.isEmpty()) list = fyyd.hot(30)
        }
        if (list.isNotEmpty()) cache.put(cacheKey(genreId, region), list)
        return list
    }

    suspend fun feed(feedUrl: String): FeedResult? = rss.fetch(feedUrl)
}
