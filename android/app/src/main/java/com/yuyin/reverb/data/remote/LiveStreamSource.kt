package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * 直播流(A 档):用户把一路音频流的地址直接粘进搜索框。
 *
 * 这一档**不做目录、不做收录、不需要后端**:用户给什么地址就放什么地址,
 * 与「粘 RSS」「粘视频链接」同一性质 —— 用户点名的那一条,不是下拉就能翻到的目录。
 *
 * 判据只有一条:**响应必须自己表明它是音频流**。具体收三种信号:
 *  ① `Content-Type` 落在 `audio` 大类下(或 `application/ogg`)—— 绝大多数 Icecast/Shoutcast 的 MP3/AAC 流;
 *  ② `Content-Type` 是 HLS 的 MIME 或路径以 `.m3u8` 结尾 —— 那是播放列表,不是网页;
 *  ③ 带 `icy-*` 响应头 —— ICY 协议自己的身份,有的电台 Content-Type 写得很随意,这条兜住。
 * `text/html` 一律拒绝:粘一个普通网页或一条失效的 RSS 地址,不该被当成直播播出去。
 *
 * 返回的 [Episode] 是**合成出来的**,`isLive = true` 是它唯一的特殊之处 ——
 * 播放侧据此关掉历史/缓存/收听时长/断点续播/播完续播(见 PlayerController 里以 isLive 为闸的几处)。
 */
class LiveStreamSource(private val client: okhttp3.OkHttpClient) {

    companion object {
        private const val TAG = "Live"

        private val HLS_TYPES = setOf(
            "application/vnd.apple.mpegurl",
            "application/x-mpegurl",
            "audio/mpegurl",
            "audio/x-mpegurl"
        )

        /**
         * 只用来给界面做"这可能是直播"的廉价预判(不发请求);真正的判据在 [resolve] 的探测。
         *
         * 故意**不**只看扩展名:大量电台地址根本没有扩展名(或挂着一串查询参数),
         * 反过来一个 `.mp3` 也可能是一个普通音频文件。所以这里只排除明显不是的单播资源,
         * 其余交给探测 —— 探测只取响应头,代价是一次几百字节的往返。
         */
        fun looksLikeStream(raw: String): Boolean {
            val u = raw.trim().toHttpUrlOrNull() ?: return false
            return u.scheme == "http" || u.scheme == "https"
        }
    }

    suspend fun resolve(rawUrl: String): Episode? = withContext(Dispatchers.IO) {
        val url = rawUrl.trim()
        val http = url.toHttpUrlOrNull() ?: return@withContext null
        if (http.scheme != "http" && http.scheme != "https") return@withContext null
        try {
            // `Range: bytes=0-0` 只要一个字节:能拿到响应头就够判断,不必把整路音频拖下来。
            // 有的服务器不认 Range(回 200 + 从头开始推流),那就读完头立刻 close —— 连接当场断掉。
            // `Icy-MetaData: 1` 让支持 ICY 的服务器把 `icy-*` 头带回来(尤其是 icy-name,拿它当标题)。
            val req = Request.Builder()
                .url(http)
                .header("User-Agent", "Reverb/1.0 (Android podcast client)")
                .header("Icy-MetaData", "1")
                .header("Range", "bytes=0-0")
                .build()
            client.newCall(req).execute().use { resp ->
                val type = resp.header("Content-Type")
                    ?.substringBefore(';')?.trim()?.lowercase().orEmpty()
                val hasIcy = resp.headers.any { it.first.startsWith("icy-", ignoreCase = true) }
                val isHls = type in HLS_TYPES || http.encodedPath.endsWith(".m3u8", ignoreCase = true)
                val isAudio = type.startsWith("audio/") || type == "application/ogg"
                // 416 = 服务器认 Range 但一个字节也取不到(空流/地址尾正好在末尾),响应头仍然有效
                val okStatus = resp.isSuccessful || resp.code == 416
                if (!okStatus || !(isHls || isAudio || hasIcy)) {
                    Logger.i(TAG, "not a stream code=${resp.code} type='$type' icy=$hasIcy host=${http.host}")
                    return@withContext null
                }
                val name = resp.header("icy-name")?.trim().orEmpty()
                Logger.i(TAG, "live ok type='$type' icy=$hasIcy hls=$isHls host=${http.host} name='$name'")
                Episode(
                    // id 带上地址:同一路流的两次粘贴视为同一集,重复点不会在队列里堆两条
                    id = "live:$url",
                    title = name.ifBlank { http.host },
                    description = "",
                    audioUrl = url,
                    artworkUrl = "",
                    // 有台名时把主机名放到副标题,不然两行写的是同一句话
                    podcastTitle = if (name.isBlank()) "" else http.host,
                    durationSec = 0,
                    pubDate = "",
                    feedUrl = "",
                    isLive = true
                )
            }
        } catch (e: Exception) {
            Logger.w(TAG, "probe failed host=${http.host}: ${e.javaClass.simpleName}")
            null
        }
    }
}
