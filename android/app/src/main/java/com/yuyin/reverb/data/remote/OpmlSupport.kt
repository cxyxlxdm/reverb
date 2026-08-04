package com.yuyin.reverb.data.remote

import android.util.Xml
import com.yuyin.reverb.data.model.Podcast
import org.xmlpull.v1.XmlPullParser
import java.io.StringReader

/**
 * 兜底源②：OPML 导入。多数播客客户端可导出 OPML，
 * 从中提取每个 outline 的 xmlUrl（即 RSS 地址），再由 [RssParser] 解析。
 */
object OpmlSupport {
    /** 由订阅列表生成 OPML 2.0 文本，用于导出。 */
    fun buildOpml(subs: List<Podcast>): String {
        val sb = StringBuilder()
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<opml version=\"2.0\">\n")
        sb.append("  <head><title>余音订阅</title></head>\n")
        sb.append("  <body>\n")
        for (p in subs) {
            val t = esc(p.title)
            sb.append("    <outline type=\"rss\" text=\"$t\" title=\"$t\" xmlUrl=\"${esc(p.feedUrl)}\"/>\n")
        }
        sb.append("  </body>\n</opml>\n")
        return sb.toString()
    }

    private fun esc(s: String): String = s
        .replace("&", "&amp;")
        .replace("\"", "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")

    fun extractFeedUrls(opml: String): List<String> {
        return try {
            val parser = Xml.newPullParser()
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
            parser.setInput(StringReader(opml))
            val urls = LinkedHashSet<String>()
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG && parser.name.equals("outline", true)) {
                    val xmlUrl = parser.getAttributeValue(null, "xmlUrl")
                        ?: parser.getAttributeValue(null, "xmlurl")
                    if (!xmlUrl.isNullOrBlank()) urls.add(xmlUrl.trim())
                }
                event = parser.next()
            }
            com.yuyin.reverb.util.Logger.i("OPML", "extractFeedUrls count=${urls.size}")
            urls.toList()
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.e("OPML", "extractFeedUrls failed", e)
            emptyList()
        }
    }
}
