package com.yuyin.reverb.cast

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * UPnP AVTransport 客户端(手写,不引三方 SDK)。
 *
 * 只实现投播需要的四个动作:SetAVTransportURI / Play / Pause / Stop /(以及 UPnP 错误码识别)。
 * 选路靠的是设备描述里的 control URL(见 `SsdpDiscovery`),协议就是标准 SOAP。
 *
 * 判断成败**看 HTTP 码 + body 里的 `UPnPError`**,不看"200 就算成功":
 * 不少电视对不支持的格式返回 200 再在 body 里塞 errorCode(700 一类)。
 */
class DlnaClient(private val client: OkHttpClient) {

    suspend fun setUri(device: CastDevice, episode: Episode) {
        soap(device, "SetAVTransportURI", setUriArgs(episode))
    }

    suspend fun play(device: CastDevice) {
        soap(device, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    suspend fun pause(device: CastDevice) {
        soap(device, "Pause", "<InstanceID>0</InstanceID>")
    }

    suspend fun stop(device: CastDevice) {
        soap(device, "Stop", "<InstanceID>0</InstanceID>")
    }

    private suspend fun soap(device: CastDevice, action: String, args: String): Unit =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(device.controlUrl)
                .header("SOAPACTION", "\"$SERVICE_TYPE#$action\"")
                .header("Content-Type", "text/xml; charset=\"utf-8\"")
                .header("User-Agent", "Reverb/1.0 (Android DLNA)")
                .post(envelope(action, args).toRequestBody(XML_MEDIA))
                .build()
            client.newCall(req).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    Logger.w(TAG, "$action http ${resp.code}")
                    throw DlnaException("$action HTTP ${resp.code}")
                }
                val code = errorCode(body)
                if (code != null) {
                    Logger.w(TAG, "$action upnp $code")
                    throw DlnaException("$action UPnP $code")
                }
                Logger.i(TAG, "$action ok")
            }
        }

    companion object {
        private const val TAG = "DLNA"
        internal const val SERVICE_TYPE = "urn:schemas-upnp-org:service:AVTransport:1"
        private val XML_MEDIA = "text/xml; charset=utf-8".toMediaType()

        internal fun errorCode(body: String): String? =
            Regex("<errorCode>\\s*(\\d+)\\s*</errorCode>").find(body)?.groupValues?.get(1)

        /** SOAP 1.1 信封。参数串由 [setUriArgs] 等拼好,已经是转义过的 XML 片段。 */
        internal fun envelope(action: String, args: String): String =
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
                "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
                "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
                "<s:Body><u:$action xmlns:u=\"$SERVICE_TYPE\">$args</u:$action></s:Body>" +
                "</s:Envelope>"

        internal fun setUriArgs(episode: Episode): String =
            "<InstanceID>0</InstanceID>" +
                "<CurrentURI>${escape(episode.audioUrl)}</CurrentURI>" +
                "<CurrentURIMetaData>${escape(didl(episode))}</CurrentURIMetaData>"

        /**
         * DIDL-Lite 元数据:很多电视不认这个也能播,但给了之後遥控器 / 屏幕上的标题才有内容。
         * 直播条目的 class 用 `audioBroadcast`,点播用 `musicTrack` —— 这是接收端决定
         * "能不能拖进度"的提示之一。
         */
        internal fun didl(episode: Episode): String {
            val cls = if (episode.isLive) "object.item.audioItem.audioBroadcast"
            else "object.item.audioItem.musicTrack"
            val art = if (episode.artworkUrl.isBlank()) ""
            else "<upnp:albumArtURI>${escape(episode.artworkUrl)}</upnp:albumArtURI>"
            return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" " +
                "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
                "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" +
                "<item id=\"0\" parentID=\"-1\" restricted=\"1\">" +
                "<dc:title>${escape(episode.title)}</dc:title>" +
                "<upnp:class>$cls</upnp:class>$art" +
                // 通配 content-type:严格写 audio/mpeg 会让 HLS 直播(.m3u8)被部分电视拒收
                "<res protocolInfo=\"http-get:*:*:*\">${escape(episode.audioUrl)}</res>" +
                "</item></DIDL-Lite>"
        }

        internal fun escape(s: String): String = buildString(s.length + 16) {
            for (c in s) when (c) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '"' -> append("&quot;")
                '\'' -> append("&apos;")
                else -> append(c)
            }
        }
    }
}

/** 设备回了一个非成功码 / UPnP 错误。消息里只有动作名与码,不含地址。 */
class DlnaException(message: String) : Exception(message)
