package com.yuyin.reverb.cast

import com.yuyin.reverb.data.model.Episode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 投播里不碰网络的那一半:SSDP 应答/设备描述的解析,以及 SOAP 信封与 DIDL 元数据的形状。
 *
 * 这一层最容易悄悄写错(比如相对 control URL 没解析、元数据忘了转义),
 * 而写错的表现是"电视上点了没反应",在真机上极难定位 —— 所以在单测里钉住。
 */
class DlnaTest {

    private fun episode(
        url: String = "https://example.com/a.mp3",
        title: String = "一集",
        artwork: String = "",
        live: Boolean = false
    ) = Episode(
        id = "ep1", title = title, description = "", audioUrl = url,
        artworkUrl = artwork, podcastTitle = "频道", isLive = live
    )

    @Test
    fun `SSDP 应答里的 LOCATION 大小写与行序都不敏感`() {
        val response = "HTTP/1.1 200 OK\r\n" +
            "CACHE-CONTROL: max-age=1800\r\n" +
            "location: http://192.168.1.9:49152/desc.xml\r\n" +
            "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        assertEquals("http://192.168.1.9:49152/desc.xml", SsdpDiscovery.parseLocation(response))
    }

    @Test
    fun `没有 LOCATION 的应答返回 null`() {
        assertNull(SsdpDiscovery.parseLocation("HTTP/1.1 200 OK\r\nST: ssdp:all\r\n\r\n"))
        assertNull(SsdpDiscovery.parseLocation(""))
    }

    @Test
    fun `设备描述取 friendlyName 与相对 control URL`() {
        val xml = """
            <?xml version="1.0"?>
            <root xmlns="urn:schemas-upnp-org:device-1-0">
              <device>
                <friendlyName>客厅电视</friendlyName>
                <manufacturer>某厂</manufacturer>
                <modelName>TV-1</modelName>
                <serviceList>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                    <controlURL>/upnp/control/avt</controlURL>
                  </service>
                </serviceList>
              </device>
            </root>
        """.trimIndent()
        val d = SsdpDiscovery.parseDescription("http://192.168.1.9:49152/desc.xml", xml)
        requireNotNull(d)
        assertEquals("客厅电视", d.name)
        assertEquals("TV-1", d.model)
        // 相对路径要按 description 的地址解析,否则 SOAP 会发到手机自己的 80 端口
        assertEquals("http://192.168.1.9:49152/upnp/control/avt", d.controlUrl)
    }

    @Test
    fun `没有 AVTransport 的描述不当作可投放设备`() {
        val xml = """
            <root><device><friendlyName>路由器</friendlyName>
            <serviceList><service>
              <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
              <controlURL>/ctl</controlURL>
            </service></serviceList></device></root>
        """.trimIndent()
        assertNull(SsdpDiscovery.parseDescription("http://10.0.0.1/d.xml", xml))
    }

    @Test
    fun `元数据里的特殊字符被转义且点播与直播用不同 upnp class`() {
        val vod = DlnaClient.didl(episode(url = "https://x/a.mp3?b=1&c=2", title = "A&B <C>"))
        assertTrue(vod.contains("A&amp;B &lt;C&gt;"))
        assertTrue(vod.contains("https://x/a.mp3?b=1&amp;c=2"))
        assertTrue(vod.contains("object.item.audioItem.musicTrack"))
        assertTrue(vod.contains("albumArtURI").not())

        val live = DlnaClient.didl(episode(title = "电台", live = true))
        assertTrue(live.contains("object.item.audioItem.audioBroadcast"))
    }

    @Test
    fun `SetAVTransportURI 参数把 DIDL 再转义一层`() {
        val args = DlnaClient.setUriArgs(episode(title = "A&B"))
        // DIDL 作为文本值嵌进 SOAP,尖括号必须以实体出现
        assertTrue(args.contains("&lt;DIDL-Lite"))
        assertTrue(args.contains("&amp;amp;"))
    }

    @Test
    fun `三方封面关闭时不进投播元数据开启时才携带`() {
        val ep = episode(artwork = "https://example.com/art.jpg?a=1&b=2")
        assertTrue(DlnaClient.didl(ep, artworkEnabled = false).contains("albumArtURI").not())
        assertTrue(DlnaClient.setUriArgs(ep, artworkEnabled = false).contains("albumArtURI").not())

        val enabled = DlnaClient.didl(ep, artworkEnabled = true)
        assertTrue(enabled.contains("<upnp:albumArtURI>"))
        assertTrue(enabled.contains("https://example.com/art.jpg?a=1&amp;b=2"))
    }

    @Test
    fun `SOAP 信封带 action 与 service 命名空间`() {
        val env = DlnaClient.envelope("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
        assertTrue(env.contains("<u:Play xmlns:u=\"${DlnaClient.SERVICE_TYPE}\">"))
        assertTrue(env.contains("<InstanceID>0</InstanceID><Speed>1</Speed>"))
        assertTrue(env.contains("http://schemas.xmlsoap.org/soap/envelope/"))
    }

    @Test
    fun `UPnP 错误码从 200 应答的 body 里取`() {
        val body = "<Envelope><Body><Fault><detail><UPnPError>" +
            "<errorCode>714</errorCode><errorDescription>Illegal MIME</errorDescription>" +
            "</UPnPError></detail></Fault></Body></Envelope>"
        assertEquals("714", DlnaClient.errorCode(body))
        assertNull(DlnaClient.errorCode("<Envelope><Body>ok</Body></Envelope>"))
    }
}
