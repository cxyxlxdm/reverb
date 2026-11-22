package com.yuyin.reverb.data.local

import com.yuyin.reverb.data.model.Station
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * `stations` 是四端备份的契约段(键名见 `docs/ARCHITECTURE.md`「直播电台」),
 * 所以这里固定住两件事:七个键逐字写出、坏条目(没有 url)不被读成一条空电台。
 */
class StationJsonTest {

    @Test
    fun `往返保留七个契约键`() {
        val st = Station(
            id = "rb:abc",
            name = "测试电台",
            url = "https://example.com/live.mp3",
            logo = "https://example.com/logo.png",
            group = "music",
            country = "CN",
            source = Station.SOURCE_DIRECTORY
        )
        val o = StationJson.toJson(st)
        assertEquals("rb:abc", o.getString("id"))
        assertEquals("测试电台", o.getString("name"))
        assertEquals("https://example.com/live.mp3", o.getString("url"))
        assertEquals("https://example.com/logo.png", o.getString("logo"))
        assertEquals("music", o.getString("group"))
        assertEquals("CN", o.getString("country"))
        assertEquals("directory", o.getString("source"))
        assertEquals(st, StationJson.fromJson(o))
    }

    @Test
    fun `没有 url 的条目不算电台`() {
        assertNull(StationJson.fromJson(JSONObject().put("id", "x").put("name", "坏条目")))
        assertNull(StationJson.fromJson(JSONObject().put("url", "   ")))
    }

    @Test
    fun `缺名称与来源时用确定值兜底`() {
        val st = StationJson.fromJson(JSONObject().put("url", "https://example.com/a"))!!
        assertEquals("https://example.com/a", st.name)
        assertEquals("local:https://example.com/a", st.id)
        assertEquals(Station.SOURCE_MANUAL, st.source)
        assertEquals("", st.group)
    }

    @Test
    fun `不认识的分组归为未分组`() {
        val st = StationJson.fromJson(
            JSONObject().put("url", "https://example.com/a").put("group", "jazz")
        )!!
        assertEquals("", st.group)
    }
}
