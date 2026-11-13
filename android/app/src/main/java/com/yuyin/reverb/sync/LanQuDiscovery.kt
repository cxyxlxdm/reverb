package com.yuyin.reverb.sync

import com.yuyin.reverb.util.Logger
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketException
import java.net.SocketTimeoutException

/**
 * 自己发 QU 查询的发现通道(组播发查询、**单播**收应答)。
 *
 * 存在的理由见 [MdnsCodec] 的头注:某些 AP(2026-11-12 的 H3C 实测)会把组播应答丢了,
 * 系统 NSD 因此一直"发现不到设备",而它的 `resolveService` 又没有取消接口。这条路不依赖
 * 组播转发,只要「组播查询出得去 + 单播回得来」就能用 —— 这两件事在出问题的那台 AP 上都成立。
 *
 * 不开组播锁、不要额外权限:只发查询、只收单播,不需要接收组播帧。
 * 一轮 ~2.5 秒(前两包间隔 300ms),两轮之间歇 1 秒;只在结果变化时回调。
 */
class LanQuDiscovery(
    private val ownServiceName: String,
    private val onPeers: (List<LanSyncPeer>) -> Unit
) {
    @Volatile private var running = false
    private var thread: Thread? = null
    private var socket: DatagramSocket? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread({ loop() }, "lan-qu").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running = false
        // 关掉 socket 让阻塞中的 receive 立刻抛出来,不用等 400ms 超时。
        runCatching { socket?.close() }
        socket = null
        thread = null
    }

    private fun loop() {
        var last: List<LanSyncPeer>? = null
        var group: InetAddress? = null
        var query: ByteArray? = null
        while (running) {
            val sock = try {
                DatagramSocket()
            } catch (e: Exception) {
                Logger.w(TAG, "打开 UDP 套接字失败:${e.message}")
                sleep(2_000)
                continue
            }
            socket = sock
            try {
                sock.soTimeout = RECV_TIMEOUT_MS
                if (group == null) group = InetAddress.getByName(GROUP)
                if (query == null) query = MdnsCodec.buildPtrQuery(SERVICE_TYPE)
                val records = MdnsCodec.Records()
                val started = System.currentTimeMillis()
                var sent = 0
                val buffer = ByteArray(4096)
                while (running && System.currentTimeMillis() - started < ROUND_MS) {
                    val elapsed = System.currentTimeMillis() - started
                    if (sent < 2 && elapsed >= sent * 300L) {
                        sock.send(DatagramPacket(query, query.size, group, MDNS_PORT))
                        sent++
                    }
                    try {
                        val packet = DatagramPacket(buffer, buffer.size)
                        sock.receive(packet)
                        records.merge(MdnsCodec.parse(buffer, packet.length))
                    } catch (_: SocketTimeoutException) {
                        // 正常:这一小段没人应答,继续等到本轮结束
                    }
                }
                val peers = records.peers(ownServiceName)
                if (peers != last) {
                    last = peers
                    Logger.i(TAG, "QU 发现 ${peers.size} 台:${peers.joinToString { it.name + "@" + it.address }}")
                    onPeers(peers)
                }
            } catch (e: SocketException) {
                if (running) Logger.w(TAG, "套接字中断:${e.message}")
            } catch (e: Exception) {
                if (running) Logger.w(TAG, "发现出错:${e.message}")
            } finally {
                runCatching { sock.close() }
                socket = null
            }
            sleep(GAP_MS)
        }
    }

    private fun sleep(ms: Long) {
        try {
            Thread.sleep(ms)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private companion object {
        const val TAG = "LanSync.Qu"
        const val SERVICE_TYPE = "_reverb._tcp.local"
        const val GROUP = "224.0.0.251"
        const val MDNS_PORT = 5353
        const val RECV_TIMEOUT_MS = 400
        const val ROUND_MS = 2_500L
        const val GAP_MS = 1_000L
    }
}
