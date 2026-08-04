package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

/**
 * 「发现」页的热门推荐来源：Apple 官方热门播客榜（每日更新，免费、无需 Key、无需登录）。
 * 榜单本身只给 id/名称，需再用 [ITunesSource.lookupBatch] 批量换取 feedUrl 与高清封面。
 */
class AppleChartsSource(
    private val client: OkHttpClient,
    private val itunes: ITunesSource
) {
    private val TAG = "Charts"

    /** 综合热门榜。region 例如 "cn"（中国区·热门节目）、"us"。 */
    suspend fun top(region: String = "cn", limit: Int = 30): List<Podcast> = withContext(Dispatchers.IO) {
        val url = "https://rss.marketingtools.apple.com/api/v2/$region/podcasts/top/$limit/podcasts.json"
        com.yuyin.reverb.util.Logger.d(TAG, "top region='$region' limit=$limit")
        val ids = parseIds(get(url))
        if (ids.isEmpty()) { com.yuyin.reverb.util.Logger.w(TAG, "top no ids region='$region'"); return@withContext emptyList() }
        itunes.lookupBatch(ids, region).also { com.yuyin.reverb.util.Logger.i(TAG, "top count=${it.size} region='$region'") }
    }

    /** 分类热门榜。genreId 见 Apple 播客分类 id（如 1303 喜剧、1489 新闻）。 */
    suspend fun topByGenre(region: String = "cn", genreId: Int, limit: Int = 30): List<Podcast> =
        withContext(Dispatchers.IO) {
            val url = "https://itunes.apple.com/$region/rss/toppodcasts/limit=$limit/genre=$genreId/json"
            com.yuyin.reverb.util.Logger.d(TAG, "topByGenre region='$region' genre=$genreId")
            val ids = parseRssIds(get(url))
            if (ids.isEmpty()) { com.yuyin.reverb.util.Logger.w(TAG, "topByGenre no ids genre=$genreId"); return@withContext emptyList() }
            itunes.lookupBatch(ids, region).also { com.yuyin.reverb.util.Logger.i(TAG, "topByGenre count=${it.size} genre=$genreId") }
        }

    // 旧版 iTunes RSS 结构：feed.entry[].id.attributes."im:id"
    private fun parseRssIds(json: String?): List<String> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val feed = JSONObject(json).optJSONObject("feed") ?: return emptyList()
            val arr = feed.optJSONArray("entry") ?: return emptyList()
            val out = ArrayList<String>(arr.length())
            for (i in 0 until arr.length()) {
                val id = arr.optJSONObject(i)
                    ?.optJSONObject("id")
                    ?.optJSONObject("attributes")
                    ?.optString("im:id")
                    .orEmpty()
                if (id.isNotBlank()) out.add(id)
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun get(url: String): String? = try {
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) com.yuyin.reverb.util.Logger.w(TAG, "http ${resp.code} url=$url")
            if (resp.isSuccessful) resp.body?.string() else null
        }
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e(TAG, "http error url=$url", e)
        null
    }

    private fun parseIds(json: String?): List<String> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONObject(json).optJSONObject("feed")?.optJSONArray("results")
                ?: return emptyList()
            val out = ArrayList<String>(arr.length())
            for (i in 0 until arr.length()) {
                val id = arr.optJSONObject(i)?.optString("id").orEmpty()
                if (id.isNotBlank()) out.add(id)
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }
}
