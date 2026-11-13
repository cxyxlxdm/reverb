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
        .put("feedUrl", e.feedUrl)
        .put("isLive", e.isLive)
        .put("transcriptUrl", e.transcriptUrl)
        .put("transcriptType", e.transcriptType)
        .put("chaptersUrl", e.chaptersUrl)
        .put("chaptersType", e.chaptersType)

    /// `optString` 缺键返回空串,所以老缓存(没有这些键)读出来就是"这集没有逐字稿/章节",
    /// 不会炸也不会误判 —— 下次刷新 feed 时自然补上。
    ///
    /// ⚠️ 章节这两个键是 1.0.8 才加的,但**漏写一轮的代价是功能在重启后凭空消失**:
    /// 播放页恢复靠 `PlaybackStateStore` → `fromJson`,历史/下载/收藏也各走一遍这里。
    /// 只加在 `RssParser` 里等于"刚搜到的那一集有章节、冷启动后同一个节目就没有了" ——
    /// 装机验收就是这么抓到的(2026-11-11,`playback_state.json` 里没有 chaptersUrl)。
    fun fromJson(o: JSONObject): Episode = Episode(
        id = o.optString("id"),
        title = o.optString("title"),
        description = o.optString("description"),
        audioUrl = o.optString("audioUrl"),
        artworkUrl = o.optString("artworkUrl"),
        podcastTitle = o.optString("podcastTitle"),
        durationSec = o.optLong("durationSec"),
        pubDate = o.optString("pubDate"),
        feedUrl = o.optString("feedUrl"),
        isLive = o.optBoolean("isLive"),
        transcriptUrl = o.optString("transcriptUrl"),
        transcriptType = o.optString("transcriptType"),
        chaptersUrl = o.optString("chaptersUrl"),
        chaptersType = o.optString("chaptersType")
    )
}
