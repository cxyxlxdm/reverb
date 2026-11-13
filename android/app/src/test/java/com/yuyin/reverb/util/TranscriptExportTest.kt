package com.yuyin.reverb.util

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 导出是**离开 App 之后**才被读到的产物,这里盯住三件容易错的事:
 * 时间戳位数、Markdown 的形状、以及文件名里的非法字符。
 */
class TranscriptExportTest {

    private fun episode(title: String = "第 3 期 / 上", channel: String = "测试频道") = Episode(
        id = "e1",
        title = title,
        description = "",
        audioUrl = "https://example.com/a.mp3",
        artworkUrl = "",
        podcastTitle = channel
    )

    private fun segments(vararg spec: Triple<String, Int, Int>) =
        spec.map { TranscribedSegment(it.first, it.second, it.third) }

    @Test
    fun `一小时以内只写到分`() {
        assertEquals("0:00", TranscriptExport.stamp(0, withHours = false))
        assertEquals("12:03", TranscriptExport.stamp(723_000, withHours = false))
        assertEquals("59:59", TranscriptExport.stamp(3_599_000, withHours = false))
    }

    @Test
    fun `超过一小时写成时分秒,且整篇统一`() {
        val segs = segments(
            Triple("开头", 0, 1_000),
            Triple("结尾", 3_723_000, 3_724_000)   // 1:02:03
        )
        val text = TranscriptExport.build(episode(), segs, TranscriptExport.Format.Text)
        assertTrue(text, text.contains("[0:00:00] 开头"))
        assertTrue(text, text.contains("[1:02:03] 结尾"))
    }

    @Test
    fun `纯文本是标题加逐行时间轴`() {
        val segs = segments(Triple("第一句", 0, 1_000), Triple("第二句", 5_000, 6_000))
        val text = TranscriptExport.build(episode(title = "测试集", channel = "频道 A"), segs, TranscriptExport.Format.Text)
        assertEquals(
            "测试集\n频道 A\n\n[0:00] 第一句\n[0:05] 第二句\n",
            text
        )
    }

    @Test
    fun `Markdown 是标题加列表`() {
        val segs = segments(Triple("Hello", 0, 1_000))
        val text = TranscriptExport.build(episode(title = "Ep", channel = "Ch"), segs, TranscriptExport.Format.Markdown)
        assertEquals("# Ep\n\n_Ch_\n\n- [0:00] Hello\n", text)
    }

    @Test
    fun `导出里不留换行 —— 一条脏文本会把列表打断`() {
        val segs = segments(Triple("第一行\n第二行", 0, 1_000))
        val text = TranscriptExport.build(episode(title = "Ep\nTitle", channel = "Ch"), segs, TranscriptExport.Format.Markdown)
        assertFalse(text, text.contains("\nTitle"))
        assertFalse(text, text.contains("第一行\n第二行"))
        assertTrue(text, text.contains("第一行 第二行"))
    }

    @Test
    fun `文件名去掉路径分隔符与控制字符`() {
        val name = TranscriptExport.fileName(episode(title = "a/b\\c:d*e?f\"g<h>i|j\nk"), TranscriptExport.Format.Text)
        assertEquals("a b c d e f g h i j k.txt", name)
    }

    @Test
    fun `空标题有兜底名字`() {
        assertEquals("transcript.md", TranscriptExport.fileName(episode(title = "  "), TranscriptExport.Format.Markdown))
    }

    @Test
    fun `搜索大小写不敏感,并且一句里的多处都标出来`() {
        val segs = segments(
            Triple("Podcast Podcast podcast", 0, 1_000),
            Triple("无关", 1_000, 2_000),
            Triple("另一个 PODCAST", 2_000, 3_000)
        )
        val result = TranscriptSearch.find(segs, "podcast")
        assertEquals(listOf(0, 2), result.indices)
        assertEquals(3, result.rangesByIndex.getValue(0).size)
        assertEquals(4..10, result.rangesByIndex.getValue(2).first())
    }

    @Test
    fun `空查询不涂亮整篇`() {
        val segs = segments(Triple("abc", 0, 1_000))
        assertTrue(TranscriptSearch.find(segs, "").isEmpty)
    }
}
