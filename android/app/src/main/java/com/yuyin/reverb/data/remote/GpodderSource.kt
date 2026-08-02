package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import java.net.URLEncoder

/**
 * 兜底源②：gpodder.net 公开搜索 —— 同样免费、无需 Key、无需登录。
 * 返回顶层 JSON 数组，每项 url 即 RSS 地址。作为最后的目录兜底。
 */
class GpodderSource(private val client: OkHttpClient) {

    suspend fun search(term: String, limit: Int = 30): List<Podcast> = withContext(Dispatchers.IO) {
        if (term.isBlank()) return@withContext emptyList()
        val url = "https://gpodder.net/search.json?q=${enc(term)}"
        parse(get(url), limit)
    }

    private fun get(url: String): String? = try {
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            .build()
        client.newCall(req).execute().use { resp ->
            if (resp.isSuccessful) resp.body?.string() else null
        }
    } catch (e: Exception) {
        null
    }

    private fun parse(json: String?, limit: Int): List<Podcast> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONArray(json)
            val out = ArrayList<Podcast>()
            var i = 0
            while (i < arr.length() && out.size < limit) {
                val o = arr.optJSONObject(i)
                i++
                if (o == null) continue
                val feed = o.optString("url", "")
                if (feed.isBlank()) continue
                out.add(
                    Podcast(
                        id = feed,
                        title = o.optString("title"),
                        author = o.optString("author"),
                        artworkUrl = o.optString("logo_url").ifBlank { o.optString("scaled_logo_url") },
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
