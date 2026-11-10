package com.yuyin.reverb.data.local

import com.yuyin.reverb.data.model.Episode
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * `EpisodeJson` 是历史 / 下载 / 缓存共用的编解码,四端备份格式互通的上游。
 * 两个方向都要测:写进去的字段读得回来;老数据缺 `isLive` / 逐字稿字段时按默认值读。
 */
class EpisodeJsonTest {

    @Test
    fun `全部字段往返一致`() {
        val episode = Episode(
            id = "ep-1",
            title = "标题",
            description = "简介",
            audioUrl = "https://cdn.example.com/a.m4a",
            artworkUrl = "https://cdn.example.com/a.jpg",
            podcastTitle = "频道",
            durationSec = 3725,
            pubDate = "2026-11-10T08:00:00Z",
            feedUrl = "https://feed.example.com/rss",
            isLive = true,
            transcriptUrl = "https://feed.example.com/t.json",
            transcriptType = "application/json"
        )
        assertEquals(episode, EpisodeJson.fromJson(EpisodeJson.toJson(episode)))
    }

    @Test
    fun `老缓存缺新字段时读成默认值`() {
        val old = JSONObject()
            .put("id", "ep-old")
            .put("title", "旧条目")
            .put("audioUrl", "https://cdn.example.com/old.mp3")
        val episode = EpisodeJson.fromJson(old)
        assertEquals("ep-old", episode.id)
        assertEquals(0L, episode.durationSec)
        assertFalse("老数据没有 isLive,不能读成直播", episode.isLive)
        assertEquals("", episode.transcriptUrl)
        assertEquals("", episode.transcriptType)
    }
}
