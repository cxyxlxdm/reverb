package com.yuyin.reverb.data.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `looksLikeStream` 是搜索框同步路径上的廉价预判(不发请求)。
 *
 * 它只回答"值不值得探测":真正的判据在 `resolve` 的响应头里。所以这里要盯住两件事 ——
 * http/https 一律放行(协议限制在 `resolve` 那一步),明显不是 URL 的输入不许放行。
 */
class LiveStreamSourceTest {

    @Test
    fun `http 与 https 地址都算候选`() {
        assertTrue(LiveStreamSource.looksLikeStream("https://stream.example.com/live.mp3"))
        assertTrue(LiveStreamSource.looksLikeStream("http://192.0.2.10:8000/stream"))
        assertTrue(LiveStreamSource.looksLikeStream("https://radio.example.com/hls/station.m3u8"))
    }

    @Test
    fun `首尾空白先 trim 再判断`() {
        assertTrue(LiveStreamSource.looksLikeStream("  https://stream.example.com/a  "))
    }

    @Test
    fun `非 http 协议不放行`() {
        assertFalse(LiveStreamSource.looksLikeStream("ftp://example.com/a.mp3"))
        assertFalse(LiveStreamSource.looksLikeStream("file:///tmp/a.mp3"))
    }

    @Test
    fun `不带协议的裸域名或普通文本不放行`() {
        assertFalse(LiveStreamSource.looksLikeStream("example.com/live"))
        assertFalse(LiveStreamSource.looksLikeStream("随便搜点什么"))
        assertFalse(LiveStreamSource.looksLikeStream(""))
    }

    @Test
    fun `缺 host 的残缺地址不放行`() {
        assertFalse(LiveStreamSource.looksLikeStream("https://"))
        assertFalse(LiveStreamSource.looksLikeStream("https:// /x"))
    }
}
