package com.yuyin.reverb.data.local

import com.yuyin.reverb.data.model.Podcast
import org.json.JSONObject

/** Podcast 的 JSON 序列化，供订阅/缓存/备份复用。 */
object PodcastJson {
    fun toJson(p: Podcast): JSONObject = JSONObject()
        .put("id", p.id)
        .put("title", p.title)
        .put("author", p.author)
        .put("artworkUrl", p.artworkUrl)
        .put("feedUrl", p.feedUrl)
        .put("description", p.description)
        .put("genre", p.genre)
        .put("isPaid", p.isPaid)
        .put("fundingUrl", p.fundingUrl)
        .put("fundingLabel", p.fundingLabel)
        .put("altFeeds", org.json.JSONArray().apply { p.altFeeds.forEach { put(it) } })

    fun fromJson(o: JSONObject): Podcast = Podcast(
        id = o.optString("id"),
        title = o.optString("title"),
        author = o.optString("author"),
        artworkUrl = o.optString("artworkUrl"),
        feedUrl = o.optString("feedUrl"),
        description = o.optString("description"),
        genre = o.optString("genre"),
        isPaid = o.optBoolean("isPaid", false),
        fundingUrl = o.optString("fundingUrl"),
        fundingLabel = o.optString("fundingLabel"),
        altFeeds = o.optJSONArray("altFeeds")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotBlank() } }
        } ?: emptyList()
    )
}
