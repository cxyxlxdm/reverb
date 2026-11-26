package com.yuyin.reverb.data.remote

import android.util.Xml
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.FeedCredential
import com.yuyin.reverb.data.model.FeedResult
import com.yuyin.reverb.data.model.Genres
import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.xmlpull.v1.XmlPullParser
import java.io.StringReader

/**
 * 播放核心：解析播客自身的 RSS/Atom，取出频道信息与每集的音频直链。
 * 无论用哪个目录发现节目，最终都回到发布方的原始 feed —— 版权安全、零成本的正规方式。
 * 使用系统内置 XmlPullParser，不引入额外解析依赖。
 */
class RssParser(private val client: OkHttpClient) {

    private val TAG = "Rss"

    /**
     * 抓取失败的分类。**只给上层区分「源暂时不可用」与「这一档确实没内容」用**,不进 UI 文案:
     * 用户看到的是统一的"数据源暂不可用",细分留给日志定位(平台拦截 / 网络 / HTTP / 解析)。
     *
     * 为什么按 url 记账而不是让 `fetch` 返回 sealed:调用方有详情页、粘贴链接检索、后台巡检
     * 好几路,改返回类型会把这条只在界面上需要的信号扩散到所有层。沿用 401 那一路的口径
     * —— 用一次性事件旁路传递,调用方在 `fetch` 回 null 之后取走(见 PodcastRepository)。
     */
    sealed interface Failure {
        /** 平台限制页:跳转后仍是 3xx、Content-Type 是 html、或正文开头是 HTML 标记。 */
        data class Blocked(val host: String, val code: Int, val contentType: String) : Failure
        data class HttpError(val code: Int) : Failure
        data object NetworkError : Failure
        data object ParseError : Failure
        data object Unauthorized : Failure
    }

    private val failures = java.util.concurrent.ConcurrentHashMap<String, Failure>()

    /** 一次性取走这个 url 最近一次失败分类,取走即清。 */
    fun consumeFailure(feedUrl: String): Failure? = failures.remove(feedUrl)

    /** 上层熔断期内直接跳过请求时,也要记一笔同样的分类,否则界面读不到"为什么没内容"。 */
    fun recordBlocked(feedUrl: String, host: String, code: Int, contentType: String) {
        failures[feedUrl] = Failure.Blocked(host, code, contentType)
    }

    suspend fun fetch(feedUrl: String, auth: FeedCredential? = null,
                      onUnauthorized: (() -> Unit)? = null): FeedResult? = withContext(Dispatchers.IO) {
        val endpoint = com.yuyin.reverb.util.Logger.endpoint(feedUrl)
        com.yuyin.reverb.util.Logger.d(TAG, "fetch endpoint=$endpoint")
        // 每次重新抓之前先清掉上一次的失败,免得这次成功之后上层还读到旧分类。
        failures.remove(feedUrl)
        val resp = download(feedUrl, auth, onUnauthorized)
        if (resp == null) {
            // 401 已经通过回调问过用户了;这里只记分类,让上层别把它当成普通失败去重试。
            failures[feedUrl] = Failure.Unauthorized
            return@withContext null
        }
        when {
            resp.blocked -> {
                val host = hostOf(feedUrl)
                failures[feedUrl] = Failure.Blocked(host, resp.code, resp.contentType)
                // 拦截页最容易被误读成"源里没有单集",日志必须带齐 host / 最终状态码 / Content-Type,
                // 否则用户换网络再试仍然空列表,而排障时没有任何线索。
                com.yuyin.reverb.util.Logger.e(
                    TAG,
                    "平台拦截/非 XML 响应 host=$host status=${resp.code} contentType='${resp.contentType}' endpoint=$endpoint"
                )
                return@withContext null
            }
            resp.code == 0 -> {
                failures[feedUrl] = Failure.NetworkError
                return@withContext null
            }
            resp.code !in 200..299 -> {
                failures[feedUrl] = Failure.HttpError(resp.code)
                return@withContext null
            }
            resp.body == null -> {
                failures[feedUrl] = Failure.NetworkError
                return@withContext null
            }
        }
        val result = parse(resp.body!!, feedUrl)
        if (result == null) failures[feedUrl] = Failure.ParseError
        result
    }

    /**
     * 下载 feed 原文。
     *
     * 401 分两种:没有凭据(要问用户)与凭据不对(也要问用户,输入框会预填用户名)。
     * 两种情况都通过 [onUnauthorized] 上报,由界面弹框 —— 静默失败在这里是最坏的结果,
     * 用户只会看到「加载失败」,然后以为链接坏了。
     *
     * 为什么会有第二次请求:RFC 7617 没规定字符集,凭据里带非 ASCII 字符时 ISO-8859-1
     * 与 UTF-8 编出来的字节不同。这里只在两种编码**真的不一样**时用 UTF-8 再试一次,
     * 纯 ASCII 凭据不会多打一枪(见 H253)。
     */
    private fun download(feedUrl: String, auth: FeedCredential?,
                         onUnauthorized: (() -> Unit)?): Attempt? {
        val first = attempt(feedUrl, auth?.header(utf8 = false))
        if (first.code != 401) return first
        // 401 只有两种可能:没带凭据,或凭据不对。两种都要交给界面问一次 ——
        // 静默失败在这里是最坏的结果,用户只会看到「加载失败」,然后以为链接坏了。
        if (auth == null) {
            onUnauthorized?.invoke()
            return null
        }
        // 门槛是「两串字节真的不同」而不是「有非 Latin-1 字符」:`é` / `ß` 这类
        // Latin-1 表示得了的字符两串就不同,服务器按 UTF-8 解时只有第二发能过。
        // 纯 ASCII 凭据两种编码完全一样,不重复发同一个头(见 H253)。
        if (!auth.encodingDiffers) {
            onUnauthorized?.invoke()
            return null
        }
        val second = attempt(feedUrl, auth.header(utf8 = true))
        if (second.code == 401) {
            onUnauthorized?.invoke()
            return null
        }
        return second
    }

    /** 一次 HTTP 尝试的完整结果。body 在失败时也留着:拦截页就藏在 3xx/200 的 HTML 正文里。 */
    private class Attempt(
        val code: Int,
        val body: String?,
        val contentType: String,
        val blocked: Boolean
    )

    private fun attempt(feedUrl: String, authorization: String?): Attempt = try {
        val builder = Request.Builder()
            .url(feedUrl)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
        if (authorization != null) builder.header("Authorization", authorization)
        client.newCall(builder.build()).execute().use { resp ->
            val code = resp.code
            val contentType = resp.header("Content-Type").orEmpty()
            // 即使状态码非 2xx 也把正文读出来:平台拦截常见形态是 302 跟到 200 + text/html,
            // 也有直接 403 + HTML 验证页。不读正文就分不清「源坏了」和「被拦了」。
            val body = runCatching { resp.body?.string() }.getOrNull()
            val blocked = isBlocked(code, contentType, body)
            if (!resp.isSuccessful || blocked) com.yuyin.reverb.util.Logger.w(
                TAG,
                "http status=$code contentType='$contentType' blocked=$blocked endpoint=${com.yuyin.reverb.util.Logger.endpoint(feedUrl)}"
            )
            Attempt(code, body, contentType, blocked)
        }
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e(
            TAG,
            "download error endpoint=${com.yuyin.reverb.util.Logger.endpoint(feedUrl)}",
            e
        )
        Attempt(0, null, "", false)
    }

    private fun isBlocked(code: Int, contentType: String, body: String?): Boolean {
        // OkHttp 默认跟随跳转;跟完之后还是 3xx 多半是跳转环或限流,按平台限制处理,
        // 而不是把 HTML 正文交给 XmlPullParser 再报一次无意义的 parse error。
        if (code in 300..399) return true
        if (isHtmlContentType(contentType) && !looksLikeXml(body)) return true
        return isHtmlInterception(body)
    }

    private fun parse(xml: String, feedUrl: String): FeedResult? {
        return try {
            val parser = Xml.newPullParser()
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
            parser.setInput(StringReader(xml))

            var channelTitle = ""
            var channelAuthor = ""
            var channelImage = ""
            var channelDesc = ""
            var channelCategory = ""
            var channelFundingUrl = ""
            var channelFundingLabel = ""
            val episodes = ArrayList<Episode>()

            var inItem = false
            var inImage = false // RSS 频道 <image><url> 块
            var iTitle = ""; var iDesc = ""; var iAudio = ""
            var iImage = ""; var iGuid = ""; var iDate = ""; var iDur = ""
            // 逐字稿:同一集可能给多条(不同格式),iTrRank 记住当前已选那条的优先级
            var iTrUrl = ""; var iTrType = ""; var iTrRank = -1
            // 章节表:只需一条 JSON,按 type 打分取最优(见下面 podcast:chapters 那段)
            var iChUrl = ""; var iChType = ""; var iChRank = -1
            // 累积**当前元素**的文本。为什么是栈而不是一个 buffer:
            // 原先在 START_TAG 里 `setLength(0)`,于是标题里内嵌一个标签就把前半截丢掉 ——
            // `<title>前情<b>提要</b>收尾</title>` 读出来只剩「提要收尾」(REVIEW-2026-10-25 低·族 B-3)。
            // 栈的语义:进子元素时把父元素已攒的文本压栈、子元素从零开始,出元素时把子元素的文本并回父元素。
            // 这样两件事同时成立:
            //  ① 空元素不再继承兄弟的文本(它自己的 buffer 是新的,父的在栈上)—— 原 clear 要防的就是这个;
            //  ② 内联标签前后的文字拼成完整标题。
            var textBuf = StringBuilder()
            val textStack = ArrayList<StringBuilder>()

            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                val name = parser.name?.lowercase() ?: ""
                when (event) {
                    XmlPullParser.START_TAG -> {
                        textStack.add(textBuf)
                        textBuf = StringBuilder()
                        when (name) {
                            "item", "entry" -> {
                                inItem = true
                                iTitle = ""; iDesc = ""; iAudio = ""
                                iImage = ""; iGuid = ""; iDate = ""; iDur = ""
                                iTrUrl = ""; iTrType = ""; iTrRank = -1
                                iChUrl = ""; iChType = ""; iChRank = -1
                            }
                            "image" -> inImage = true
                            // <enclosure> 优先，无条件覆盖
                            "enclosure" -> {
                                val url = parser.getAttributeValue(null, "url")
                                if (inItem && !url.isNullOrBlank()) iAudio = url
                            }
                            // <media:content> 仅在尚无音频且明确为 audio 时采用，避免误取图片
                            "media:content" -> if (inItem && iAudio.isBlank()) {
                                val url = parser.getAttributeValue(null, "url")
                                val type = parser.getAttributeValue(null, "type").orEmpty()
                                val medium = parser.getAttributeValue(null, "medium").orEmpty()
                                if (!url.isNullOrBlank() && (type.startsWith("audio") || medium == "audio")) {
                                    iAudio = url
                                }
                            }
                            // Atom：<link rel="enclosure" type="audio/..." href="..."/>
                            "link" -> if (inItem && iAudio.isBlank()) {
                                val rel = parser.getAttributeValue(null, "rel").orEmpty()
                                val type = parser.getAttributeValue(null, "type").orEmpty()
                                val href = parser.getAttributeValue(null, "href")
                                if (!href.isNullOrBlank() && (rel == "enclosure" || type.startsWith("audio"))) {
                                    iAudio = href
                                }
                            }
                            "itunes:image" -> {
                                val href = parser.getAttributeValue(null, "href")
                                if (!href.isNullOrBlank()) {
                                    if (inItem) iImage = href else channelImage = href
                                }
                            }
                            "itunes:category" -> if (!inItem && channelCategory.isBlank()) {
                                val cat = parser.getAttributeValue(null, "text")
                                if (!cat.isNullOrBlank()) channelCategory = cat.trim()
                            }
                            "podcast:funding" -> if (!inItem && channelFundingUrl.isBlank()) {
                                val u = parser.getAttributeValue(null, "url")
                                if (!u.isNullOrBlank()) channelFundingUrl = u.trim()
                            }
                            /**
                             * 发布方自己的逐字稿(Podcasting 2.0)。**空元素、信息全在属性里**,
                             * 所以只能在 START_TAG 取,和上面 itunes:image / podcast:funding 一样。
                             *
                             * 一集常有多条(同一稿的不同格式,外加 `rel="captions"` 的字幕版),
                             * 故不是"取第一条",而是按 transcriptRank 打分取最优:
                             * JSON(带词级时间)> VTT > SRT,HTML/纯文本直接不要(没有时间轴,
                             * 拿来也做不了跟读高亮)。
                             */
                            "podcast:transcript" -> if (inItem) {
                                val u = parser.getAttributeValue(null, "url")
                                val t = parser.getAttributeValue(null, "type").orEmpty()
                                val rank = transcriptRank(t)
                                if (!u.isNullOrBlank() && rank > iTrRank) {
                                    iTrUrl = u.trim(); iTrType = t.trim(); iTrRank = rank
                                }
                            }
                            /**
                             * 发布方给的**章节表**(Podcasting 2.0)。与逐字稿同形:空元素、信息全在属性里。
                             *
                             * 只收 JSON:本端按 [data.model.Chapter] 解析,别的格式(个别源给 XML)
                             * 收下来只会得到一个"加载失败"。打分只区分"标准 chapters 类型"与"泛 JSON":
                             * `application/json+chapters` 优先,`application/json` 次之,其余不要。
                             */
                            "podcast:chapters" -> if (inItem) {
                                val u = parser.getAttributeValue(null, "url")
                                val t = parser.getAttributeValue(null, "type").orEmpty()
                                val rank = chaptersRank(t)
                                if (!u.isNullOrBlank() && rank > iChRank) {
                                    iChUrl = u.trim(); iChType = t.trim(); iChRank = rank
                                }
                            }
                        }
                    }

                    XmlPullParser.TEXT, XmlPullParser.CDSECT -> textBuf.append(parser.text ?: "")

                    XmlPullParser.END_TAG -> {
                        val text = textBuf.toString().trim()
                        if (inItem) {
                            when (name) {
                                "title" -> if (iTitle.isBlank()) iTitle = text
                                "description", "itunes:summary", "summary", "content:encoded" ->
                                    if (iDesc.isBlank()) iDesc = text
                                "guid", "id" -> if (iGuid.isBlank()) iGuid = text
                                "pubdate", "published" -> if (iDate.isBlank()) iDate = text
                                "itunes:duration" -> if (iDur.isBlank()) iDur = text
                                "item", "entry" -> {
                                    if (iAudio.isNotBlank()) {
                                        episodes.add(
                                            Episode(
                                                id = iGuid.ifBlank { iAudio },
                                                title = iTitle,
                                                description = htmlToText(iDesc),
                                                audioUrl = iAudio,
                                                artworkUrl = iImage.ifBlank { channelImage },
                                                podcastTitle = channelTitle,
                                                durationSec = parseDuration(iDur),
                                                pubDate = iDate,
                                                feedUrl = feedUrl,
                                                transcriptUrl = iTrUrl,
                                                transcriptType = iTrType,
                                                chaptersUrl = iChUrl,
                                                chaptersType = iChType
                                            )
                                        )
                                    }
                                    inItem = false
                                }
                            }
                        } else {
                            when (name) {
                                "title" -> if (channelTitle.isBlank()) channelTitle = text
                                "author", "itunes:author" -> if (channelAuthor.isBlank()) channelAuthor = text
                                "description", "itunes:summary" -> if (channelDesc.isBlank()) channelDesc = text
                                "url" -> if (inImage && channelImage.isBlank()) channelImage = text
                                "image" -> inImage = false
                                "podcast:funding" ->
                                    if (channelFundingLabel.isBlank() && channelFundingUrl.isNotBlank()) {
                                        channelFundingLabel = text
                                    }
                            }
                        }
                        // 出元素:把本元素攒到的文本并回父元素,这样 `<title>前<b>中</b>后</title>`
                        // 的父(= title)最终拿到「前中后」。与 START_TAG 那次压栈一一对应:
                        // 压栈时栈顶是父、当前 buffer 是新的;出栈时弹回父并把子文本接上去。
                        val parent = textStack.removeAt(textStack.size - 1)
                        if (textBuf.isNotEmpty()) parent.append(textBuf)
                        textBuf = parent
                    }
                }
                event = parser.next()
            }

            val podcast = Podcast(
                id = feedUrl,
                title = channelTitle,
                author = channelAuthor,
                artworkUrl = channelImage,
                feedUrl = feedUrl,
                description = htmlToText(channelDesc),
                genre = Genres.key(channelCategory),
                fundingUrl = channelFundingUrl,
                fundingLabel = channelFundingLabel
            )
            com.yuyin.reverb.util.Logger.i(
                TAG,
                "parse ok episodes=${episodes.size} endpoint=${com.yuyin.reverb.util.Logger.endpoint(feedUrl)}"
            )
            FeedResult(podcast, episodes)
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.e(
                TAG,
                "parse error endpoint=${com.yuyin.reverb.util.Logger.endpoint(feedUrl)}",
                e
            )
            null
        }
    }

    /**
     * 逐字稿格式的优先级。**负数表示不要**。
     *
     * 只收带时间轴的格式:JSON(Podcast Index 那套,可能带词级时间)> VTT > SRT。
     * HTML / 纯文本稿虽然也常见,但没有时间轴 —— 拿来只能当一整篇文章,做不了跟播放高亮,
     * 反而会让"有稿"的判断变成"有一篇读不动的长文",故直接排除。
     */
    private fun transcriptRank(type: String): Int {
        val t = type.lowercase()
        return when {
            t.contains("json") -> 3
            t.contains("vtt") -> 2
            t.contains("srt") || t.contains("subrip") -> 1
            else -> -1          // text/html、text/plain 等
        }
    }

    /**
     * 章节表格式的优先级。**负数表示不要**。
     *
     * 章节规范只定义了 JSON 一种载体;`application/json+chapters` 是标准写法,
     * 不少源写成 `application/json`,这两种都收,前者优先。XML 之类的章表本端不解析 ——
     * 宣告"有章节"却点开报错,比根本不出现入口更糟。
     */
    private fun chaptersRank(type: String): Int {
        val t = type.lowercase()
        return when {
            t.contains("json+chapters") -> 2
            t.contains("json") -> 1
            else -> -1
        }
    }

    private fun parseDuration(s: String): Long {
        if (s.isBlank()) return 0
        return try {
            if (s.contains(":")) {
                val parts = s.split(":").map { it.trim().toLong() }
                when (parts.size) {
                    3 -> parts[0] * 3600 + parts[1] * 60 + parts[2]
                    2 -> parts[0] * 60 + parts[1]
                    else -> parts[0]
                }
            } else {
                s.toDouble().toLong()
            }
        } catch (e: Exception) {
            0
        }
    }

    /** 将 HTML 简介转为带段落换行的纯文本，用于详情简介与播放页 shownotes。 */
    private fun htmlToText(s: String): String {
        if (s.isBlank()) return ""
        var t = s
        t = t.replace(Regex("(?i)<br\\s*/?>"), "\n")
        t = t.replace(Regex("(?i)</p>"), "\n\n")
        t = t.replace(Regex("(?i)</div>"), "\n")
        t = t.replace(Regex("(?i)<li[^>]*>"), "· ")
        t = t.replace(Regex("<[^>]*>"), "")
        // 实体解码顺序:**`&amp;` 必须放最后**。
        // 原先 `&amp;`→`&` 排在 `&lt;`→`<` 前面,于是源里字面写的 `&amp;lt;`(用户想看到「&lt;」)
        // 先折成 `&lt;`,再被下一行折成 `<` —— 双重反转义(REVIEW-2026-10-25 低·族 B-1)。
        // 反过来先解 `&lt;`/`&gt;`/`&quot;` 等,`&amp;lt;` 里并不含字面 `&lt;`,不受影响;
        // 最后一步才把 `&amp;` 折成 `&`,得到的正是发布方写的那个 `&lt;`。
        // (RSS 的 description 绝大多数在 CDATA 里,解析器不会替我们解一层,所以这一层必须自己解对。)
        t = t.replace("&nbsp;", " ")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
            .replace("&amp;", "&")
        t = t.replace(Regex("[ \\t]+"), " ")
        t = t.replace(Regex(" *\\n *"), "\n")
        t = t.replace(Regex("\\n{3,}"), "\n\n")
        return t.trim()
    }

    companion object {
        /** 去掉 BOM 与开头空白再判断:有些网关在 XML/HTML 前塞一个 UTF-8 BOM。 */
        private fun head(body: String?): String =
            body?.trimStart('\uFEFF', ' ', '\t', '\r', '\n')?.lowercase().orEmpty()

        /** 开头像 RSS/Atom 就是真 feed。只看开头,不做整文解析(这函数在 IO 层调用)。 */
        private fun looksLikeXml(body: String?): Boolean {
            val s = head(body)
            return s.startsWith("<?xml") || s.startsWith("<rss") || s.startsWith("<feed")
        }

        /**
         * 正文是否是 HTML 拦截页而不是 RSS/Atom。纯函数、不碰网络与 android.util.Xml,
         * JVM 单测直接验。判据只取正文开头:`<!doctype html` / `<html` / `<head`,
         * 且明确排除 `<rss` / `<feed` / `<?xml` 开头 —— 这三句正好是平台拦页面给的形状。
         */
        fun isHtmlInterception(body: String?): Boolean {
            val s = head(body)
            if (looksLikeXml(s)) return false
            return s.startsWith("<!doctype html") || s.startsWith("<html") || s.startsWith("<head")
        }

        /** Content-Type 里带 html 即视为非 XML 响应。`application/xhtml+xml` 也算。 */
        fun isHtmlContentType(contentType: String?): Boolean =
            contentType?.contains("html", ignoreCase = true) == true

        /** 日志只需要主机名,不要把可能带凭据的完整 URL 写进去。 */
        private fun hostOf(url: String): String = runCatching {
            java.net.URI(url).host
        }.getOrNull()?.ifBlank { null }
            ?: url.substringAfter("://").substringBefore('/').ifBlank { url }
    }
}
