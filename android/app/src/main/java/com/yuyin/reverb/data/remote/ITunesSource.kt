package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Episode
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

    private val TAG = "iTunes"

    suspend fun search(term: String, country: String = "", limit: Int = 50): List<Podcast> = withContext(Dispatchers.IO) {
        if (term.isBlank()) return@withContext emptyList()
        val c = if (country.isNotBlank()) "&country=$country" else ""
        val url = "https://itunes.apple.com/search?media=podcast&term=${enc(term)}$c&limit=$limit"
        com.yuyin.reverb.util.Logger.d(TAG, "search country='$country'")
        parsePodcasts(get(url)).also { com.yuyin.reverb.util.Logger.i(TAG, "search count=${it.size}") }
    }

    /**
     * 单集检索：entity=podcastEpisode，结果直接携带音频直链(episodeUrl)与所属频道，
     * 可直接构造 [Episode] 播放，无需再解析该频道 RSS。
     */
    suspend fun searchEpisodes(term: String, country: String = "", limit: Int = 50): List<Episode> = withContext(Dispatchers.IO) {
        if (term.isBlank()) return@withContext emptyList()
        val c = if (country.isNotBlank()) "&country=$country" else ""
        val url = "https://itunes.apple.com/search?media=podcast&entity=podcastEpisode&term=${enc(term)}$c&limit=$limit"
        com.yuyin.reverb.util.Logger.d(TAG, "searchEpisodes country='$country'")
        parseEpisodes(get(url)).also { com.yuyin.reverb.util.Logger.i(TAG, "searchEpisodes count=${it.size}") }
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
        com.yuyin.reverb.util.Logger.d(TAG, "lookupBatch ids=${ids.size} country='$country'")
        parsePodcasts(get(url)).also { com.yuyin.reverb.util.Logger.i(TAG, "lookupBatch count=${it.size}") }
    }

    private fun get(url: String): String? = try {
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) com.yuyin.reverb.util.Logger.w(
                TAG,
                "http ${resp.code} endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
            )
            if (resp.isSuccessful) resp.body?.string() else null
        }
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e(
            TAG,
            "http error endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}",
            e
        )
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

    private fun parseEpisodes(json: String?): List<Episode> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONObject(json).optJSONArray("results") ?: return emptyList()
            val out = ArrayList<Episode>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                // 结果里首条常是 collection(频道)包装，只取真正的单集
                val isEpisode = o.optString("wrapperType") == "podcastEpisode" ||
                    o.optString("kind") == "podcast-episode"
                if (!isEpisode) continue
                val audio = o.optString("episodeUrl").ifBlank { o.optString("previewUrl") }
                if (audio.isBlank()) continue
                val durMs = o.optLong("trackTimeMillis", 0L)
                out.add(
                    Episode(
                        id = o.optString("trackId").ifBlank { audio },
                        title = o.optString("trackName"),
                        description = stripHtml(o.optString("description")),
                        audioUrl = audio,
                        artworkUrl = o.optString("artworkUrl600")
                            .ifBlank { o.optString("artworkUrl160") }
                            .ifBlank { o.optString("artworkUrl100") },
                        podcastTitle = o.optString("collectionName"),
                        durationSec = if (durMs > 0) durMs / 1000 else 0,
                        pubDate = o.optString("releaseDate").take(10),
                        feedUrl = o.optString("feedUrl", "")
                    )
                )
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** iTunes 单集简介可能夹带简单 HTML，去标签后展示到播放页 shownotes。 */
    private fun stripHtml(s: String): String {
        if (s.isBlank()) return ""
        return s.replace(Regex("(?i)<br\\s*/?>"), "\n")
            .replace(Regex("(?i)</p>"), "\n\n")
            .replace(Regex("<[^>]*>"), "")
            .replace("&nbsp;", " ").replace("&amp;", "&")
            .replace("&lt;", "<").replace("&gt;", ">")
            .replace("&quot;", "\"").replace("&#39;", "'")
            .trim()
    }

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
}
