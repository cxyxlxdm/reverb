package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Podcast
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * OPML 导出是订阅的唯一可迁移出口,`&` / 引号 / 尖括号写坏一处,
 * 导入端就会在第一个 outline 处解析失败。
 */
class OpmlSupportTest {

    @Test
    fun `标题与地址里的 XML 特殊字符被转义`() {
        val opml = OpmlSupport.buildOpml(
            listOf(
                Podcast(
                    id = "1",
                    title = "A & \"B\" <C>",
                    author = "",
                    artworkUrl = "",
                    feedUrl = "https://example.com/rss?a=1&b=2"
                )
            )
        )
        assertTrue(opml.contains("text=\"A &amp; &quot;B&quot; &lt;C&gt;\""))
        assertTrue(opml.contains("xmlUrl=\"https://example.com/rss?a=1&amp;b=2\""))
        assertTrue(opml.startsWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        assertTrue(opml.trimEnd().endsWith("</opml>"))
    }

    @Test
    fun `空订阅列表仍产出合法骨架`() {
        val opml = OpmlSupport.buildOpml(emptyList())
        assertTrue(opml.contains("<body>"))
        assertTrue(opml.contains("</body>"))
        assertTrue(!opml.contains("<outline"))
    }
}
