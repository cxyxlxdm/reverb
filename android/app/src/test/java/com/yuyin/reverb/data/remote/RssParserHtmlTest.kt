package com.yuyin.reverb.data.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 拦截页识别是纯判据,不碰网络也不碰 android.util.Xml,JVM 单测直接验。
 *
 * 为什么单测这一处:小宇宙 `feed.xyzfm.space` 那边 302 跟到 200 + text/html 拦页面,
 * 旧代码只看 `resp.isSuccessful`,把它交给 XmlPullParser 报一次 parse error,
 * 用户看到的是空列表而不是「源暂时不可用」。判据一旦漂移(比如漏掉 `<head` 那种开头),
 * 同样的症状就会回来,而日志里只有一句 parse error。
 */
class RssParserHtmlTest {

    @Test
    fun `doctype html 与 html 开头都判为拦截页`() {
        assertTrue(RssParser.isHtmlInterception("<!DOCTYPE html><html><head><title>访问受限</title></head></html>"))
        assertTrue(RssParser.isHtmlInterception("<html lang=\"zh-CN\"><body>请开启 JavaScript</body></html>"))
        assertTrue(RssParser.isHtmlInterception("<head><meta charset=\"utf-8\"></head>"))
    }

    @Test
    fun `RSS 与 Atom 真 feed 不能被误判`() {
        assertFalse(RssParser.isHtmlInterception("<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss version=\"2.0\"><channel/></rss>"))
        assertFalse(RssParser.isHtmlInterception("<rss version=\"2.0\"><channel><title>节目</title></channel></rss>"))
        assertFalse(RssParser.isHtmlInterception("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>节目</title></feed>"))
    }

    @Test
    fun `前导 BOM 与空白不影响判定`() {
        assertTrue(RssParser.isHtmlInterception("\uFEFF\n  <HTML><HEAD></HEAD></HTML>"))
        assertFalse(RssParser.isHtmlInterception("\n\t<?xml version=\"1.0\"?><rss><channel/></rss>"))
    }

    @Test
    fun `普通文本正文不算拦截页`() {
        assertFalse(RssParser.isHtmlInterception(""))
        assertFalse(RssParser.isHtmlInterception(null))
        assertFalse(RssParser.isHtmlInterception("This feed is temporarily unavailable."))
    }

    @Test
    fun `Content-Type 含 html 一律识别,含 xml 的链路不识别`() {
        assertTrue(RssParser.isHtmlContentType("text/html; charset=utf-8"))
        assertTrue(RssParser.isHtmlContentType("application/xhtml+xml"))
        assertFalse(RssParser.isHtmlContentType("application/rss+xml; charset=utf-8"))
        assertFalse(RssParser.isHtmlContentType(null))
    }
}
