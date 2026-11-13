package com.yuyin.reverb.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * mDNS 编解码的**固定报文测试**。
 *
 * 夹具不是自己拼的:2026-11-12 在 H3C 网络下,从手机临时端口发一条 QU 的 PTR 查询,
 * `mDNSResponder` 单播回来的 **211 字节原样**存成 `/tmp/qu_response.bin`,这里就是它的十六进制。
 * 这条报文同时覆盖四类记录、两处压缩指针(PTR 的目标名、SRV 的 `_reverb._tcp.local` 尾)
 * 和两段链路本地 IPv6 —— 后者本实现故意不解析(见 [MdnsCodec] 头注)。
 *
 * 别把期望值改成"实现打印出来的那个":判据是**协议的字节口径**,不是自己的输出。
 */
class MdnsCodecTest {

    private val response = hex(RESPONSE_HEX)

    private val probe = "ReverbProbe-c035cf43._reverb._tcp.local"

    @Test
    fun parsesPtrSrvTxtAndAFromRealResponse() {
        assertEquals(211, response.size)

        val records = MdnsCodec.parse(response)

        assertEquals(setOf(probe), records.ptr.keys)
        val srv = records.srv[probe]
        assertNotNull(srv)
        assertEquals("cxyxldeMac-Mini.local", srv!!.target)
        assertEquals(47820, srv.port)
        assertEquals("cxyxl的Mac Mini", records.txt[probe]?.get("nm"))
        assertEquals("192.168.6.153", records.a["cxyxldeMac-Mini.local"])
        // 两条 AAAA 不该出现在 A 表里(只认 IPv4)。
        assertEquals(1, records.a.size)
    }

    @Test
    fun buildsPeerReadyToConnect() {
        val peers = MdnsCodec.parse(response).peers(ownServiceName = "Reverb-841efc1b")

        assertEquals(1, peers.size)
        assertEquals("cxyxl的Mac Mini", peers.single().name)
        assertEquals("192.168.6.153:47820", peers.single().address)
    }

    @Test
    fun filtersOwnAdvertisementByInstanceName() {
        // 自己的 QU 查询会问到自己的应答;挡掉靠实例短名,不是全名。
        val peers = MdnsCodec.parse(response).peers(ownServiceName = "ReverbProbe-c035cf43")
        assertTrue(peers.isEmpty())
    }

    @Test
    fun mergeKeepsRecordsFromDifferentPackets() {
        // 应答方不保证四类记录塞进一个包:先只放查询包(空),再合完整应答。
        val merged = MdnsCodec.parse(MdnsCodec.buildPtrQuery("_reverb._tcp.local"))
        assertTrue(merged.ptr.isEmpty())
        merged.merge(MdnsCodec.parse(response))
        assertEquals(1, merged.peers("").size)
    }

    @Test
    fun queryIsQuPtrForServiceType() {
        val query = MdnsCodec.buildPtrQuery("_reverb._tcp.local")

        // 头:ID=0 flags=0 QD=1,其余计数 0
        assertArrayEquals(byteArrayOf(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0), query.copyOfRange(0, 12))
        // 名字 `_reverb._tcp.local`,然后是 QTYPE=PTR(12) + QCLASS=IN|QU(0x8001)
        assertEquals(36, query.size)
        assertArrayEquals(byteArrayOf(0, 12, 0x80.toByte(), 0x01), query.copyOfRange(32, 36))
        // 名字按标签长度编码,不是带点的纯字符串
        assertArrayEquals(
            hex("075f726576657262045f746370056c6f63616c00"),
            query.copyOfRange(12, 32)
        )
    }

    @Test
    fun survivesGarbageWithoutHanging() {
        // 指向自己的压缩指针:必须被丢掉,不能原地打转。
        val loop = hex("000084000000000100000000c00c000100010000000a0004c0a80699")
        assertTrue(MdnsCodec.parse(loop).ptr.isEmpty())

        // 截在 SRV 记录中间:完整的 PTR 留下,读不全的 SRV 丢掉,不抛异常。
        val truncated = MdnsCodec.parse(response.copyOfRange(0, 80))
        assertEquals(1, truncated.ptr.size)
        assertTrue(truncated.srv.isEmpty())

        // 短到连头部都不够。
        assertTrue(MdnsCodec.parse(byteArrayOf(1, 2, 3)).ptr.isEmpty())
    }

    private fun hex(text: String): ByteArray {
        val clean = text.filter { !it.isWhitespace() }
        require(clean.length % 2 == 0) { "十六进制长度不是偶数" }
        return ByteArray(clean.length / 2) {
            clean.substring(it * 2, it * 2 + 2).toInt(16).toByte()
        }
    }

    private companion object {
        const val RESPONSE_HEX =
            "000084000001000100000005075f726576657262045f746370056c6f63616c00000c8001c00c000c00010000000a0017" +
                "1452657665726250726f62652d6330333563663433c00cc030002100010000000a001800" +
                "000000bacc0f637879786c64654d61632d4d696e69c019c030001000010000000a0014136e6d3d637879786ce79a844d6163" +
                "204d696e69c059001c00010000000a0010fe800000000000001c1aec5362915dbdc059001c00010000000a0010fd9ef6a8" +
                "dad200000c785504aa862c01c059000100010000000a0004c0a80699"
    }
}
