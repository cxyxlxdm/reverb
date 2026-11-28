package com.yuyin.reverb.data.local

import com.yuyin.reverb.data.model.Podcast
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `PodcastJson` 是订阅 / 缓存 / 备份共用的编解码。
 * 新增字段 altFeeds(H311)两个方向都要验:写进去读得回;老数据缺键时按空列表读,
 * 否则老用户冷启动解析订阅失败。
 */
class PodcastJsonTest {

    @Test
    fun `altFeeds 往返一致且小宇宙垫底`() {
        val p = Podcast(
            id = "1493503146", title = "忽左忽右", author = "JustPod", artworkUrl = "",
            feedUrl = "https://feed.xyzfm.space/cv4bkgpuglwp",
            altFeeds = listOf("https://www.ximalaya.com/album/12817863.xml",
                "https://feed.xyzfm.space/cv4bkgpuglwp")
        )
        val json = PodcastJson.toJson(p)
        assertEquals(2, json.getJSONArray("altFeeds").length())
        assertEquals("https://www.ximalaya.com/album/12817863.xml",
            json.getJSONArray("altFeeds").getString(0))
        assertEquals(p, PodcastJson.fromJson(json))
        assertEquals(p.feedUrl, PodcastJson.fromJson(json).altFeeds.last())
    }

    @Test
    fun `老数据缺 altFeeds 解成空列表`() {
        val json = JSONObject("""
            {"id":"1493503146","title":"忽左忽右","author":"JustPod","artworkUrl":"",
             "feedUrl":"https://feed.xyzfm.space/cv4bkgpuglwp","description":"","genre":"",
             "isPaid":false,"fundingUrl":"","fundingLabel":""}
        """.trimIndent())
        assertTrue(PodcastJson.fromJson(json).altFeeds.isEmpty())
    }
}
