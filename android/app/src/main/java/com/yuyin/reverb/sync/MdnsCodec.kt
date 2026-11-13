package com.yuyin.reverb.sync

import java.io.ByteArrayOutputStream

/**
 * 极简 mDNS 报文编解码,只覆盖发现需要的四种记录(PTR / SRV / TXT / A)。
 *
 * **为什么自己写一份**:2026-11-12 在 H3C 网络实测到一种单向组播故障 ——
 * 手机发出的组播查询能到 Mac,Mac 的**组播应答到不了手机**(同一时刻 Mac 侧抓包看得到应答、
 * 手机侧 NsdService 一条 `SERVICE_FOUND` 都没有;手机 Wi-Fi 重连后能好一阵,几分钟后又不行)。
 * 而 QU(unicast-response)查询的应答是**单播回给查询方**的,不过 AP 的组播转发 —— 实测
 * 从临时端口发 QU,`mDNSResponder` 2 秒内单播回了 211 字节(PTR+SRV+TXT+A 全带)。
 * 所以发现改成两条路并行:系统 NSD 照旧(健康网络上它更省事),这条 QU 路兜住组播不通的网络。
 *
 * 只解析 IPv4 的 A 记录:同步端口是 TCP,手机与 Mac/Apple 端在同一 IPv4 子网;
 * Apple 端应答里还有链路本地 IPv6(fe80::),那需要 scope id,不值得在这里处理。
 *
 * 报文格式见 RFC 1035(名字压缩指针)与 RFC 6762(QU 位 = 类字段最高位)。
 */
object MdnsCodec {

    private const val TYPE_A = 1
    private const val TYPE_PTR = 12
    private const val TYPE_TXT = 16
    private const val TYPE_SRV = 33

    private const val CLASS_IN = 1
    private const val CLASS_UNICAST = 0x8000

    /** SRV 的 rdata:2 字节优先级、2 字节权重、2 字节端口,然后是目标主机名。 */
    data class Srv(val target: String, val port: Int)

    /**
     * 一轮里收到的所有记录。可以 `merge` 多包 —— 应答方不保证把
     * PTR / SRV / TXT / A 塞进同一个包(实测 Apple 塞得下,不保证所有实现都塞得下)。
     */
    class Records {
        val ptr = LinkedHashMap<String, String>()          // 服务实例全名 -> 自己
        val srv = LinkedHashMap<String, Srv>()             // 服务实例全名 -> 目标主机 + 端口
        val txt = LinkedHashMap<String, Map<String, String>>()
        val a = LinkedHashMap<String, String>()            // 主机名 -> IPv4 字符串

        fun merge(other: Records) {
            ptr.putAll(other.ptr)
            srv.putAll(other.srv)
            txt.putAll(other.txt)
            a.putAll(other.a)
        }

        /**
         * 拼出可以直接连的 peer。`ownServiceName` 是**实例短名**(不含 `_reverb._tcp.local`),
         * 用来挡掉自己的广播 —— 自己的应答也会被自己的 QU 查询问到。
         */
        fun peers(ownServiceName: String): List<LanSyncPeer> {
            val out = ArrayList<LanSyncPeer>()
            for (instance in ptr.keys) {
                if (instance.substringBefore('.') == ownServiceName) continue
                val record = srv[instance] ?: continue
                val ip = a[record.target] ?: continue
                val nm = txt[instance]?.get("nm")?.trim()?.takeIf { it.isNotEmpty() } ?: instance
                out.add(LanSyncPeer(nm, ip, record.port))
            }
            return out.distinctBy { it.name to it.address }
        }
    }

    /** 一条 QU 的 PTR 查询:`_reverb._tcp.local`。类字段带 0x8000,要求对方单播应答。 */
    fun buildPtrQuery(serviceType: String): ByteArray {
        val out = ByteArrayOutputStream()
        // ID=0;flags=0;QD=1;AN=NS=AR=0
        out.write(byteArrayOf(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0))
        writeName(out, serviceType)
        out.write(byteArrayOf(0, TYPE_PTR.toByte(), ((CLASS_IN or CLASS_UNICAST) shr 8).toByte(), (CLASS_IN or CLASS_UNICAST).toByte()))
        return out.toByteArray()
    }

    fun parse(data: ByteArray, length: Int = data.size): Records {
        val records = Records()
        if (length < 12) return records
        val questions = u16(data, 4)
        val answers = u16(data, 6)
        val authority = u16(data, 8)
        val additional = u16(data, 10)

        var offset = 12
        repeat(questions) {
            offset = skipQuestion(data, offset, length)
            if (offset < 0) return records
        }
        repeat(answers + authority + additional) {
            val rr = readRecord(data, offset, length) ?: return records
            offset = rr.next
            when (rr.type) {
                TYPE_PTR -> {
                    val name = readName(data, rr.rdata, length) ?: return@repeat
                    records.ptr[name.first] = name.first
                }
                TYPE_SRV -> {
                    if (rr.rdlen < 7) return@repeat
                    val port = u16(data, rr.rdata + 4)
                    val target = readName(data, rr.rdata + 6, length) ?: return@repeat
                    records.srv[rr.name] = Srv(target.first, port)
                }
                TYPE_TXT -> {
                    val attrs = LinkedHashMap<String, String>()
                    var p = rr.rdata
                    val end = rr.rdata + rr.rdlen
                    while (p < end) {
                        val len = data[p].toInt() and 0xFF
                        if (len == 0) { p++; continue }
                        if (p + 1 + len > end) break
                        val text = String(data, p + 1, len, Charsets.UTF_8)
                        val eq = text.indexOf('=')
                        if (eq > 0) attrs[text.substring(0, eq)] = text.substring(eq + 1)
                        p += 1 + len
                    }
                    records.txt[rr.name] = attrs
                }
                TYPE_A -> {
                    if (rr.rdlen == 4) {
                        val ip = "${data[rr.rdata].toInt() and 0xFF}.${data[rr.rdata + 1].toInt() and 0xFF}." +
                            "${data[rr.rdata + 2].toInt() and 0xFF}.${data[rr.rdata + 3].toInt() and 0xFF}"
                        records.a[rr.name] = ip
                    }
                }
            }
        }
        return records
    }

    // ---- 内部 ----

    private class ResourceRecord(val name: String, val type: Int, val rdata: Int, val rdlen: Int, val next: Int)

    private fun writeName(out: ByteArrayOutputStream, name: String) {
        for (label in name.split('.')) {
            if (label.isEmpty()) continue
            val bytes = label.toByteArray(Charsets.UTF_8)
            require(bytes.size <= 63) { "mDNS 标签超过 63 字节:$label" }
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(0)
    }

    private fun skipQuestion(data: ByteArray, offset: Int, end: Int): Int {
        val name = readName(data, offset, end) ?: return -1
        val next = name.second + 4 // QTYPE + QCLASS
        return if (next > end) -1 else next
    }

    private fun readRecord(data: ByteArray, offset: Int, end: Int): ResourceRecord? {
        val name = readName(data, offset, end) ?: return null
        val after = name.second
        if (after + 10 > end) return null
        val type = u16(data, after)
        val rdlen = u16(data, after + 8)
        val rdata = after + 10
        if (rdata + rdlen > end) return null
        return ResourceRecord(name.first, type, rdata, rdlen, rdata + rdlen)
    }

    /**
     * 读一个可能带压缩指针的名字。返回 (名字, 这个名字在**原位置**之后的下一个字节)。
     * 指针只能向前跳、最多 16 跳 —— 坏包里的环状指针不能让解析器卡死。
     */
    private fun readName(data: ByteArray, start: Int, end: Int): Pair<String, Int>? {
        var offset = start
        var next = -1
        var jumps = 0
        val labels = ArrayList<String>()
        while (offset < end) {
            val len = data[offset].toInt() and 0xFF
            if (len == 0) {
                return (labels.joinToString(".") to (if (next < 0) offset + 1 else next))
            }
            if ((len and 0xC0) == 0xC0) {
                if (offset + 1 >= end) return null
                val pointer = ((len and 0x3F) shl 8) or (data[offset + 1].toInt() and 0xFF)
                if (next < 0) next = offset + 2
                if (++jumps > 16 || pointer >= end || pointer >= offset) return null
                offset = pointer
                continue
            }
            if (len > 63 || offset + 1 + len > end) return null
            labels.add(String(data, offset + 1, len, Charsets.UTF_8))
            offset += 1 + len
        }
        return null
    }

    private fun u16(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
}
