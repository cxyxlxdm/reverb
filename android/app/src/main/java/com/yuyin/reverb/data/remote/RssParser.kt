package com.yuyin.reverb.data.remote

import android.util.Xml
import com.yuyin.reverb.data.model.Episode
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

    suspend fun fetch(feedUrl: String): FeedResult? = withContext(Dispatchers.IO) {
        com.yuyin.reverb.util.Logger.d(TAG, "fetch endpoint=${com.yuyin.reverb.util.Logger.endpoint(feedUrl)}")
        val xml = download(feedUrl) ?: return@withContext null
        parse(xml, feedUrl)
    }

    private fun download(feedUrl: String): String? = try {
        val req = Request.Builder()
            .url(feedUrl)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) com.yuyin.reverb.util.Logger.w(
                TAG,
                "http ${resp.code} endpoint=${com.yuyin.reverb.util.Logger.endpoint(feedUrl)}"
            )
            if (resp.isSuccessful) resp.body?.string() else null
        }
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e(
            TAG,
            "download error endpoint=${com.yuyin.reverb.util.Logger.endpoint(feedUrl)}",
            e
        )
        null
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
                                                transcriptType = iTrType
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
}
