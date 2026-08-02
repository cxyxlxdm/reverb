package com.yuyin.reverb.data.local

import com.yuyin.reverb.data.model.Episode
import org.json.JSONObject

/** Episode 的 JSON 序列化，供下载/历史等本地存储复用。 */
object EpisodeJson {
    fun toJson(e: Episode): JSONObject = JSONObject()
        .put("id", e.id)
        .put("title", e.title)
        .put("description", e.description)
        .put("audioUrl", e.audioUrl)
        .put("artworkUrl", e.artworkUrl)
        .put("podcastTitle", e.podcastTitle)
        .put("durationSec", e.durationSec)
        .put("pubDate", e.pubDate)

    fun fromJson(o: JSONObject): Episode = Episode(
        id = o.optString("id"),
        title = o.optString("title"),
        description = o.optString("description"),
        audioUrl = o.optString("audioUrl"),
        artworkUrl = o.optString("artworkUrl"),
        podcastTitle = o.optString("podcastTitle"),
        durationSec = o.optLong("durationSec"),
        pubDate = o.optString("pubDate")
    )
}
