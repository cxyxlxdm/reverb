package com.yuyin.reverb.cast

import android.content.Context
import android.net.wifi.WifiManager
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.w3c.dom.Element
import org.xml.sax.InputSource
import java.io.StringReader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.URI
import javax.xml.parsers.DocumentBuilderFactory

/**
 * DLNA 设备发现:SSDP M-SEARCH → 设备描述 XML → AVTransport control URL。
 *
 * 为什么用组播锁:Wi-Fi 驱动在没有 MCAST 锁时会过滤组播帧,LAN 同步那边已经用实测
 * 撞过一次(见 H276);这里只在发现的那几秒内持锁,结束立刻释放。
 *
 * **日志只记条数与失败类型**,不记设备名 / IP / description URL —— 隐私政策第二节。
 */
class SsdpDiscovery(private val context: Context, private val client: OkHttpClient) {

    suspend fun discover(timeoutMs: Long = 3200): List<CastDevice> = withContext(Dispatchers.IO) {
        val locations = LinkedHashSet<String>()
        val lock = multicastLock()
        try {
            DatagramSocket().use { socket ->
                socket.soTimeout = 500
                val group = InetAddress.getByName(SSDP_ADDR)
                val payload = SEARCH_MESSAGE.toByteArray(Charsets.UTF_8)
                // UDP 会丢:同一条 M-SEARCH 发两次,间隔 300ms(很多设备的应答比首包晚)。
                repeat(2) { i ->
                    if (i > 0) delay(300)
                    runCatching {
                        socket.send(DatagramPacket(payload, payload.size, group, SSDP_PORT))
                    }.onFailure { Logger.w(TAG, "m-search send failed ${it.javaClass.simpleName}") }
                }
                val deadline = System.currentTimeMillis() + timeoutMs
                val buf = ByteArray(4096)
                while (System.currentTimeMillis() < deadline) {
                    val packet = DatagramPacket(buf, buf.size)
                    try {
                        socket.receive(packet)
                    } catch (e: SocketTimeoutException) {
                        continue
                    } catch (e: Exception) {
                        Logger.w(TAG, "receive failed ${e.javaClass.simpleName}")
                        break
                    }
                    val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                    parseLocation(text)?.let { locations.add(it) }
                }
            }
        } catch (e: Exception) {
            Logger.w(TAG, "ssdp failed ${e.javaClass.simpleName}")
        } finally {
            runCatching { lock?.release() }
        }

        if (locations.isEmpty()) {
            Logger.i(TAG, "ssdp hits=0")
            return@withContext emptyList()
        }
        val found = coroutineScope {
            locations.take(MAX_DESCRIPTIONS).map { loc ->
                async { fetchDevice(loc) }
            }.awaitAll().filterNotNull()
        }.distinctBy { it.id }
        Logger.i(TAG, "ssdp hits=${locations.size} renderers=${found.size}")
        found
    }

    private fun fetchDevice(location: String): CastDevice? = try {
        val req = Request.Builder().url(location).header("User-Agent", USER_AGENT).build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                Logger.w(TAG, "desc http ${resp.code}")
                null
            } else {
                val xml = resp.body?.string().orEmpty()
                parseDescription(location, xml)
            }
        }
    } catch (e: Exception) {
        Logger.w(TAG, "desc failed ${e.javaClass.simpleName}")
        null
    }

    private fun multicastLock(): WifiManager.MulticastLock? = try {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        wifi?.createMulticastLock("reverb-dlna")?.apply {
            setReferenceCounted(false)
            acquire()
        }
    } catch (e: Exception) {
        Logger.w(TAG, "multicast lock failed ${e.javaClass.simpleName}")
        null
    }

    companion object {
        private const val TAG = "DLNA"
        internal const val SSDP_ADDR = "239.255.255.250"
        internal const val SSDP_PORT = 1900
        private const val MAX_DESCRIPTIONS = 12
        private const val USER_AGENT = "Reverb/1.0 (Android DLNA)"

        internal val SEARCH_MESSAGE = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: $SSDP_ADDR:$SSDP_PORT\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 2\r\n" +
            "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n" +
            "USER-AGENT: $USER_AGENT UPnP/1.1\r\n\r\n"

        /** 从 SSDP 应答里取 LOCATION(大小写不敏感);没有就返回 null。 */
        internal fun parseLocation(response: String): String? {
            for (line in response.lineSequence()) {
                val idx = line.indexOf(':')
                if (idx <= 0) continue
                if (line.substring(0, idx).trim().equals("LOCATION", ignoreCase = true)) {
                    val v = line.substring(idx + 1).trim()
                    if (v.isNotEmpty()) return v
                }
            }
            return null
        }

        /**
         * 设备描述 → [CastDevice]。只认带 AVTransport 服务的描述:
         * 路由器 / 网关也会应答 SSDP,但它们没有 AVTransport,投过去只会得到一个错误。
         *
         * 相对 control URL 按 description 的地址解析(规范允许相对路径,实测不少电视这么写)。
         *
         * ⚠️ 用 DOM 而不是 XmlPullParser:后者在 JVM 单测里是 android.jar 的桩
         * (`Stub!`),这段解析就永远进不了单测;而它在真机上写错的表现是"点了没反应",
         * 恰是最该被单测钉住的一段。XXE 关掉(设备描述来自局域网,但不该有 DTD)。
         */
        internal fun parseDescription(location: String, xml: String): CastDevice? = try {
            val factory = DocumentBuilderFactory.newInstance().apply {
                isNamespaceAware = true
                runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
                runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
                runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            }
            val doc = factory.newDocumentBuilder().parse(InputSource(StringReader(xml)))

            fun first(tag: String): String =
                (doc.getElementsByTagNameNS("*", tag).item(0) as? Element)
                    ?.textContent?.trim().orEmpty()

            val friendly = first("friendlyName")
            val manufacturer = first("manufacturer")
            val model = first("modelName")

            var control: String? = null
            val services = doc.getElementsByTagNameNS("*", "service")
            for (i in 0 until services.length) {
                val svc = services.item(i) as? Element ?: continue
                val type = (svc.getElementsByTagNameNS("*", "serviceType").item(0) as? Element)
                    ?.textContent.orEmpty()
                if (!type.contains("AVTransport", ignoreCase = true)) continue
                val c = (svc.getElementsByTagNameNS("*", "controlURL").item(0) as? Element)
                    ?.textContent?.trim().orEmpty()
                if (c.isNotBlank()) {
                    control = resolve(location, c)
                    break
                }
            }
            val ctl = control ?: return null
            CastDevice(
                id = location,
                name = friendly.ifBlank { model.ifBlank { "DLNA" } },
                model = model.ifBlank { manufacturer },
                location = location,
                controlUrl = ctl
            )
        } catch (e: Exception) {
            Logger.w(TAG, "desc parse failed ${e.javaClass.simpleName}")
            null
        }

        internal fun resolve(base: String, ref: String): String = try {
            URI(base).resolve(ref).toString()
        } catch (e: Exception) {
            ref
        }
    }
}
