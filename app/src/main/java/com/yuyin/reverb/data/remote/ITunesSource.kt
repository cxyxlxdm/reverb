package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Genres
import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.URLEncoder

/**
 * 默认源：Apple iTunes Search API。
 * 免费、无需 API Key、全球稳定，且检索结果直接携带 feedUrl（播客的 RSS 地址）。
 * 我们只用它做「发现/检索」，音频始终来自 RSS 中发布方的原始直链，不转存、不代理。
 */
class ITunesSource(private val client: OkHttpClient) {

    suspend fun search(term: String, country: String = "", limit: Int = 50): List<Podcast> = withContext(Dispatchers.IO) {
        if (term.isBlank()) return@withContext emptyList()
        val c = if (country.isNotBlank()) "&country=$country" else ""
        val url = "https://itunes.apple.com/search?media=podcast&term=${enc(term)}$c&limit=$limit"
        parsePodcasts(get(url))
    }

    suspend fun lookup(collectionId: String): Podcast? = withContext(Dispatchers.IO) {
        val url = "https://itunes.apple.com/lookup?id=$collectionId&entity=podcast"
        parsePodcasts(get(url)).firstOrNull()
    }

    /** 批量换取详情（含 feedUrl）。country 用于让分类名等本地化到对应地区。 */
    suspend fun lookupBatch(ids: List<String>, country: String = ""): List<Podcast> = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext emptyList()
        val c = if (country.isNotBlank()) "&country=$country" else ""
        val url = "https://itunes.apple.com/lookup?id=${ids.joinToString(",")}&entity=podcast$c"
        parsePodcasts(get(url))
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

    private fun parsePodcasts(json: String?): List<Podcast> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONObject(json).optJSONArray("results") ?: return emptyList()
            val out = ArrayList<Podcast>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val feed = o.optString("feedUrl", "")
                if (feed.isBlank()) continue
                out.add(
                    Podcast(
                        id = o.optString("collectionId").ifBlank { feed },
                        title = o.optString("collectionName").ifBlank { o.optString("trackName") },
                        author = o.optString("artistName"),
                        artworkUrl = o.optString("artworkUrl600").ifBlank { o.optString("artworkUrl100") },
                        feedUrl = feed,
                        genre = Genres.key(o.optString("primaryGenreName")),
                        isPaid = o.optDouble("collectionPrice", 0.0) > 0.0 ||
                            o.optDouble("trackPrice", 0.0) > 0.0
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
