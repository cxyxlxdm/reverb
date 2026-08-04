package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.URLEncoder

/**
 * 兜底源①：fyyd.de 播客搜索 —— 完全免费、无需任何 Key、开箱即用。
 * 返回结构规整（data[].xmlURL 即 RSS 地址），作为 Apple 之后的第一兜底。
 */
class FyydSource(private val client: OkHttpClient) {

    private val TAG = "fyyd"

    suspend fun search(term: String, limit: Int = 30): List<Podcast> = withContext(Dispatchers.IO) {
        if (term.isBlank()) return@withContext emptyList()
        val url = "https://api.fyyd.de/0.2/search/podcast?title=${enc(term)}&count=$limit"
        com.yuyin.reverb.util.Logger.d(TAG, "search term='$term'")
        parse(get(url)).also { com.yuyin.reverb.util.Logger.i(TAG, "search count=${it.size}") }
    }

    /** 热门播客（发现页推荐的兜底来源，无需 Key）。 */
    suspend fun hot(limit: Int = 30): List<Podcast> = withContext(Dispatchers.IO) {
        val url = "https://api.fyyd.de/0.2/feature/podcast/hot?count=$limit"
        com.yuyin.reverb.util.Logger.d(TAG, "hot limit=$limit")
        parse(get(url)).also { com.yuyin.reverb.util.Logger.i(TAG, "hot count=${it.size}") }
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

    private fun parse(json: String?): List<Podcast> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONObject(json).optJSONArray("data") ?: return emptyList()
            val out = ArrayList<Podcast>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val feed = o.optString("xmlURL", "")
                if (feed.isBlank()) continue
                out.add(
                    Podcast(
                        id = feed,
                        title = o.optString("title"),
                        author = o.optString("author"),
                        artworkUrl = o.optString("imgURL").ifBlank { o.optString("layoutImageURL") },
                        feedUrl = feed,
                        description = o.optString("description")
                    )
                )
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
}
