package com.yuyin.reverb.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 章节表解析的判据。重点不是"能读出几条",而是**入口不变式**:
 * 起点单调、≥0、没有标题的章不收 —— 界面用「从后往前找第一个 startMs <= now」判当前章,
 * 顺序错一条就会让当前章跳回上一章(与逐字稿那条同一个故障形状,硬规矩 10)。
 */
class ChaptersFetcherTest {

    @Test
    fun `标准 chapters 包装按 startTime 解析成毫秒`() {
        val json = """
            { "version": "1.2.0", "chapters": [
              { "startTime": 0, "title": "开场", "img": "https://a/0.jpg", "url": "https://a/0" },
              { "startTime": 83.5, "title": "正题" }
            ] }
        """.trimIndent()
        val out = ChaptersFetcher.parseChapters(json)!!
        assertEquals(2, out.size)
        assertEquals(0, out[0].startMs)
        assertEquals("开场", out[0].title)
        assertEquals("https://a/0.jpg", out[0].imageUrl)
        assertEquals("https://a/0", out[0].url)
        assertEquals(83_500, out[1].startMs)
    }

    @Test
    fun `顶层直接是数组也认`() {
        val json = """[{"startTime": 10, "title": "A"},{"startTime": 20, "title": "B"}]"""
        val out = ChaptersFetcher.parseChapters(json)!!
        assertEquals(listOf(10_000, 20_000), out.map { it.startMs })
    }

    @Test
    fun `乱序输入在出口排好序 —— 渲染侧依赖单调`() {
        val json = """
            {"chapters": [
              {"startTime": 300, "title": "三"},
              {"startTime": 100, "title": "一"},
              {"startTime": 200, "title": "二"}
            ]}
        """.trimIndent()
        val out = ChaptersFetcher.parseChapters(json)!!
        assertEquals(listOf("一", "二", "三"), out.map { it.title })
        assertTrue(out.zipWithNext().all { (a, b) -> a.startMs <= b.startMs })
    }

    @Test
    fun `同一秒只留一条 —— 当前章不能有两个答案`() {
        val json = """
            {"chapters": [
              {"startTime": 60, "title": "第一版"},
              {"startTime": 60, "title": "第二版"}
            ]}
        """.trimIndent()
        val out = ChaptersFetcher.parseChapters(json)!!
        assertEquals(1, out.size)
    }

    @Test
    fun `旧式 start 时间串与负数起点`() {
        val json = """
            {"chapters": [
              {"start": "00:01:23.500", "title": "hms"},
              {"start": "02:05.250", "title": "ms"},
              {"startTime": -5, "title": "负值"}
            ]}
        """.trimIndent()
        val out = ChaptersFetcher.parseChapters(json)!!
        // 负值被夹到 0 后与"零起点"同秒去重规则无关 —— 这里没有别的 0,所以三条都在
        assertEquals(listOf(0, 83_500, 125_250), out.map { it.startMs }.sorted())
    }

    @Test
    fun `没标题的章不收,全是无标题就是空表`() {
        assertTrue(ChaptersFetcher.parseChapters("""{"chapters":[{"startTime":0}]}""")!!.isEmpty())
        assertTrue(ChaptersFetcher.parseChapters("""{"chapters":[{"startTime":0,"title":"   "}]}""")!!.isEmpty())
    }

    @Test
    fun `不是章表返回 null,与空表区分开`() {
        assertNull(ChaptersFetcher.parseChapters("<html>nope</html>"))
        assertNull(ChaptersFetcher.parseChapters(""))
        // 合法 JSON 但没有 chapters 键,按"章表为空"处理(不是坏格式)
        assertTrue(ChaptersFetcher.parseChapters("""{"version":"1.2.0"}""")!!.isEmpty())
    }
}
