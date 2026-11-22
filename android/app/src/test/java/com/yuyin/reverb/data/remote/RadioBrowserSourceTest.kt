package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Station
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 目录响应的解析口径(网络层不参与):哪些字段算数、哪些条目该丢。
 * 这几条决定"收藏进来的电台点得响" —— 地址为空或最近一次检查失败的不该进列表。
 */
class RadioBrowserSourceTest {

    private fun one(
        name: String = "电台",
        urlResolved: String = "",
        url: String = "",
        uuid: String = "u1",
        lastCheckOk: Int = 1
    ): String = """
        {"stationuuid":"$uuid","name":"$name","url_resolved":"$urlResolved",
         "url":"$url","favicon":"https://x/logo.png","country":"China",
         "lastcheckok":$lastCheckOk}
    """.trimIndent()

    @Test
    fun `优先取 url_resolved 并映射为目录来源`() {
        val list = RadioBrowserSource.parseStations("[${one(urlResolved = "https://a/stream", url = "https://a/old")}]")
        assertEquals(1, list.size)
        val st = list[0]
        assertEquals("https://a/stream", st.url)
        assertEquals("rb:u1", st.id)
        assertEquals("China", st.country)
        assertEquals("https://x/logo.png", st.logo)
        assertEquals(Station.SOURCE_DIRECTORY, st.source)
        assertEquals("", st.group)
    }

    @Test
    fun `url_resolved 为空时退回 url`() {
        val list = RadioBrowserSource.parseStations("[${one(url = "https://a/old")}]")
        assertEquals("https://a/old", list.single().url)
    }

    @Test
    fun `最近一次检查失败的条目丢掉`() {
        val list = RadioBrowserSource.parseStations("[${one(urlResolved = "https://a/s", lastCheckOk = 0)}]")
        assertTrue(list.isEmpty())
    }

    @Test
    fun `没有地址或没有名字的条目丢掉`() {
        val json = "[${one(name = "空地址")}, ${one(name = "", urlResolved = "https://a/s", uuid = "u2")}]"
        assertTrue(RadioBrowserSource.parseStations(json).isEmpty())
    }

    @Test
    fun `同一地址只留第一条`() {
        val json = "[${one(urlResolved = "https://a/s", uuid = "u1")}, ${one(urlResolved = "https://a/s", uuid = "u2")}]"
        val list = RadioBrowserSource.parseStations(json)
        assertEquals(1, list.size)
        assertEquals("rb:u1", list[0].id)
    }

    @Test
    fun `缺 stationuuid 时用地址生成稳定 id`() {
        val list = RadioBrowserSource.parseStations("[${one(urlResolved = "https://a/s", uuid = "")}]")
        assertEquals("rb:https://a/s", list.single().id)
    }

    @Test
    fun `非数组响应按空处理`() {
        assertTrue(RadioBrowserSource.parseStations("{\"error\":\"oops\"}").isEmpty())
        assertTrue(RadioBrowserSource.parseStations("").isEmpty())
    }
}
