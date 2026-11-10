package com.yuyin.reverb.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 私有订阅源的第一道边界:URL 里的 userinfo 必须在落库前剥掉。
 *
 * 它不能出现在订阅列表、备份、日志与分享卡片里 —— 这条断言就是那三处的上游。
 */
class FeedCredentialTest {

    @Test
    fun `userinfo 被剥掉并拆成凭据`() {
        val (url, cred) = FeedCredential.splitUrl("https://user:pa%3Ass@example.com/feed.xml")
        assertEquals("https://example.com/feed.xml", url)
        assertEquals("user", cred?.username)
        assertEquals("pa:ss", cred?.password)
    }

    @Test
    fun `只有用户名时密码为空串`() {
        val (url, cred) = FeedCredential.splitUrl("https://user@example.com/feed.xml")
        assertEquals("https://example.com/feed.xml", url)
        assertEquals("user", cred?.username)
        assertEquals("", cred?.password)
    }

    @Test
    fun `没有 userinfo 时原样返回`() {
        val (url, cred) = FeedCredential.splitUrl("  https://example.com/feed.xml  ")
        assertEquals("https://example.com/feed.xml", url)
        assertNull(cred)
    }

    @Test
    fun `端口与查询参数在重建后保留`() {
        val (url, cred) = FeedCredential.splitUrl("https://u:p@example.com:8443/feed.xml?x=1")
        assertEquals("https://example.com:8443/feed.xml?x=1", url)
        assertEquals("u", cred?.username)
        assertEquals("p", cred?.password)
    }

    @Test
    fun `不是 URL 的输入不抛异常`() {
        val (url, cred) = FeedCredential.splitUrl("不是网址")
        assertEquals("不是网址", url)
        assertNull(cred)
    }
}
