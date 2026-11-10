package com.yuyin.reverb.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * B 站这一路的三个纯判据:标题强相关过滤、视频输入识别、取流头判据。
 *
 * 标题过滤的规则见 H241:清洗后整词包含,或关键词任意 2 字连续片段出现在标题里。
 * 这里把"留下 / 剔掉"两侧都钉住 —— 只测留下会掩盖"什么都留"的实现错误。
 */
class BilibiliSourceTest {

    @Test
    fun `标题整词包含关键词就留下`() {
        assertTrue(BilibiliSource.isTitleRelevant("聊天记录 学习资料", "学习资料"))
        assertTrue(BilibiliSource.isTitleRelevant("【学习资料】整理", "学习资料"))
    }

    @Test
    fun `空白与标点不阻断整词匹配`() {
        assertTrue(BilibiliSource.isTitleRelevant("学习 资料 汇总", "学习资料"))
        assertTrue(BilibiliSource.isTitleRelevant("学习-资料", "学习资料"))
    }

    @Test
    fun `停用词在两侧一起剥掉`() {
        assertTrue(BilibiliSource.isTitleRelevant("如何学习英语", "如何学习英语"))
        assertTrue(BilibiliSource.isTitleRelevant("学习英语的方法", "如何学习英语"))
    }

    @Test
    fun `两字连续片段命中近义标题`() {
        assertTrue(BilibiliSource.isTitleRelevant("推荐几档播客", "播客推荐"))
        assertTrue(BilibiliSource.isTitleRelevant("我的资料整理", "学习资料"))
    }

    @Test
    fun `标题与关键词无关就剔掉`() {
        assertFalse(BilibiliSource.isTitleRelevant("猫咪日常 vlog", "学习资料"))
        assertFalse(BilibiliSource.isTitleRelevant("三分钟做一道家常菜", "英语听力"))
    }

    @Test
    fun `关键词为空时不过滤`() {
        assertTrue(BilibiliSource.isTitleRelevant("任意标题", ""))
        assertTrue(BilibiliSource.isTitleRelevant("任意标题", "   "))
        assertTrue(BilibiliSource.isTitleRelevant("任意标题", "的"))
    }

    @Test
    fun `视频输入识别认 BV 号与短链`() {
        assertTrue(BilibiliSource.looksLikeVideo("BV1xx411c7mD"))
        assertTrue(BilibiliSource.looksLikeVideo("看这个 https://www.bilibili.com/video/BV1xx411c7mD"))
        assertTrue(BilibiliSource.looksLikeVideo("https://b23.tv/abcd123"))
        assertTrue(BilibiliSource.looksLikeVideo("https://bili2233.cn/abcd123"))
        assertFalse(BilibiliSource.looksLikeVideo("https://example.com/feed.xml"))
        assertFalse(BilibiliSource.looksLikeVideo("播客推荐"))
    }

    @Test
    fun `伪协议能取回视频 id`() {
        assertEquals("BV1xx411c7mD", BilibiliSource.videoIdOf("bilibili://video/BV1xx411c7mD"))
        assertNull(BilibiliSource.videoIdOf("https://www.bilibili.com/video/BV1xx411c7mD"))
        assertNull(BilibiliSource.videoIdOf("bilibili://video/"))
    }

    @Test
    fun `取流头按参数指纹判断而不是域名白名单`() {
        val signed = "https://cdn.example.com/a.m4a?upsig=abc&deadline=123"
        assertTrue(BilibiliSource.needsStreamHeaders(signed))
        assertTrue(BilibiliSource.needsStreamHeaders("https://upos-sz-mirrorcos.bilivideo.com/a.m4a"))
        assertFalse(BilibiliSource.needsStreamHeaders("https://cdn.example.com/a.mp3"))
        assertFalse(BilibiliSource.needsStreamHeaders("file:///tmp/a.mp3"))
    }
}
