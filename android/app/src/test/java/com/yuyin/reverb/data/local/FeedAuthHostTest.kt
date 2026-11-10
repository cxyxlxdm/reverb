package com.yuyin.reverb.data.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 凭据只发给源自己(含父子域)的那条判据。
 *
 * 放错一个字符,口令就会跟着音频 CDN 的请求发出去 —— 所以同源与不同源两侧都要钉住。
 */
class FeedAuthHostTest {

    @Test
    fun `host 统一小写并去掉路径`() {
        assertEquals("example.com", FeedAuthStore.hostOf("https://Example.COM/feed.xml"))
        assertEquals("example.com", FeedAuthStore.hostOf("  https://example.com:8443/x  "))
    }

    @Test
    fun `不是 URL 时 host 为空`() {
        assertNull(FeedAuthStore.hostOf("不是网址"))
    }

    @Test
    fun `父子域视为同源`() {
        assertTrue(FeedAuthStore.hostMatches("a.example.com", "example.com"))
        assertTrue(FeedAuthStore.hostMatches("example.com", "a.example.com"))
        assertTrue(FeedAuthStore.hostMatches("example.com", "example.com"))
    }

    @Test
    fun `后缀相同但不是子域的不算`() {
        assertFalse(FeedAuthStore.hostMatches("evil-example.com", "example.com"))
        assertFalse(FeedAuthStore.hostMatches("example.com.evil.net", "example.com"))
        assertFalse(FeedAuthStore.hostMatches("other.com", "example.com"))
    }

    @Test
    fun `空值不算匹配`() {
        assertFalse(FeedAuthStore.hostMatches(null, "example.com"))
        assertFalse(FeedAuthStore.hostMatches("example.com", null))
        assertFalse(FeedAuthStore.hostMatches("", "example.com"))
    }
}
