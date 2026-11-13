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
            transcriptType = "application/json",
            chaptersUrl = "https://feed.example.com/chapters.json",
            chaptersType = "application/json+chapters"
        )
        val json = EpisodeJson.toJson(episode)
        // 往返相等证明不了"真的写出去了":两个方向同时漏掉新字段,往返照样相等。
        // 所以先认键名与值,再比整条(2026-11-11 就是漏了这一步才让章节在重启后消失)。
        assertEquals("https://feed.example.com/chapters.json", json.getString("chaptersUrl"))
        assertEquals("application/json+chapters", json.getString("chaptersType"))
        assertEquals(episode, EpisodeJson.fromJson(json))
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
        assertEquals("", episode.chaptersUrl)
        assertEquals("", episode.chaptersType)
    }
}
