package com.yuyin.reverb.util

import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.data.model.TranscribedWord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 逐字稿时间轴的两条不变式(见 H60 与硬规矩 10):
 * 起点 `>= 0` 且单调不减;拼接出来的文本与词表逐字一致。
 *
 * 渲染侧用 `indexOfLast { startMs <= now }` 找当前词,只要队尾混进一个更小的起点,
 * 高亮就会钉死在那一条 —— 所以这里必须把"修好之后"的形状逐个数出来。
 */
class TranscriptLinesTest {

    private fun words(vararg spec: Triple<String, Int, Int>) =
        spec.map { TranscribedWord(it.first, it.second, it.third) }

    @Test
    fun `起点为负或回退时被夹成单调不减`() {
        val out = TranscriptLines.mergeWords(
            words(
                Triple("a", 100, 200),
                Triple("b", 50, 300),
                Triple("c", -5, 10)
            ),
            spaced = false
        )
        val flat = out.flatMap { it.words ?: emptyList() }
        // 修法是"抬到前一个起点",不是"回填":只要单调且非负就满足渲染侧的前提。
        flat.zipWithNext().forEach { (a, b) ->
            assertTrue("起点必须单调不减", b.startMs >= a.startMs)
        }
        flat.forEach {
            assertTrue("起点不能为负", it.startMs >= 0)
            assertTrue("终点不能早于起点", it.endMs >= it.startMs)
        }
        assertEquals("abc", out.joinToString("") { it.text })
    }

    @Test
    fun `负数起点从零起算`() {
        val out = TranscriptLines.mergeWords(
            words(Triple("a", -5, 10), Triple("b", 100, 200)),
            spaced = false
        )
        val flat = out.flatMap { it.words ?: emptyList() }
        assertEquals(0, flat.first().startMs)
    }

    @Test
    fun `已经单调的稿原样保留起点`() {
        val out = TranscriptLines.mergeWords(
            words(Triple("one ", 0, 100), Triple("two", 100, 200)),
            spaced = false
        )
        val flat = out.flatMap { it.words ?: emptyList() }
        assertEquals(listOf(0, 100), flat.map { it.startMs })
        assertEquals(listOf(100, 200), flat.map { it.endMs })
        assertEquals("one two", out.joinToString("") { it.text })
    }

    @Test
    fun `句子的起止取首尾词`() {
        val out = TranscriptLines.mergeWords(
            words(Triple("a", 10, 20), Triple("b", 20, 30), Triple("c", 30, 40)),
            spaced = false
        )
        assertEquals(1, out.size)
        assertEquals(10, out[0].startMs)
        assertEquals(40, out[0].endMs)
    }

    @Test
    fun `空输入不产出句子`() {
        assertTrue(TranscriptLines.mergeWords(emptyList(), spaced = false).isEmpty())
    }

    @Test
    fun `西文按 ASCII 起头判断是否要补空格`() {
        assertTrue(TranscriptLines.isAsciiHead("Hello"))
        assertFalse(TranscriptLines.isAsciiHead("中文"))
        assertFalse(TranscriptLines.isAsciiHead(""))
    }

    /**
     * 行宽是**跨端共用的尺子**,而且必须比一台手机真能放下的字数小两格 ——
     * 等于容量就是"每条都刚好溢出",屏幕上就是"一行铺满 + 下一行一个字"(见 H280)。
     */
    @Test
    fun `行宽是共用尺子`() {
        assertEquals(18, TranscriptLines.CJK_CHARS)
        assertEquals(38, TranscriptLines.WEST_CHARS)
        assertEquals(18, TranscriptLines.targetChars("这是一段中文"))
        assertEquals(38, TranscriptLines.targetChars("this is english"))
    }

    @Test
    fun `24 个汉字断成两条,每条都放得进一行`() {
        val out = TranscriptLines.mergeWords(
            (0 until 24).map { TranscribedWord("字", it * 100, it * 100 + 90) },
            spaced = false
        )
        assertTrue("24 字必须断成至少两条", out.size >= 2)
        out.forEach {
            assertTrue(
                "每条都要放得进一行,实际 ${it.text.length} 字",
                it.text.length <= TranscriptLines.CJK_CHARS
            )
        }
        assertEquals("字".repeat(24), out.joinToString("") { it.text })
    }

    /**
     * 长度是**加之前**判的:一条 3 个字的词正好卡在边界上时,旧写法会产出 21 字
     * (18 加完再看),而 Android 正文一行只放得下 20 个 —— 21 字就是"一行铺满 + 下一行一个字"。
     */
    @Test
    fun `多字词不会把一行顶过目标字数`() {
        val out = TranscriptLines.mergeWords(
            (0 until 8).map { TranscribedWord("三个字", it * 500, it * 500 + 400) },
            spaced = false
        )
        out.forEach {
            assertTrue("实际 ${it.text.length} 字:${it.text}", it.text.length <= TranscriptLines.CJK_CHARS)
        }
    }

    /**
     * 中文排版不允许一行以「，」起头。长度到点那一刻正好轮到逗号时,逗号要黏在上一行尾 ——
     * 2026-11-13 在 Android 上就看见了一段以「，这里是…」起头的行。
     */
    @Test
    fun `标点不落到行首`() {
        val words = (0 until 18).map { TranscribedWord("字", it * 100, it * 100 + 90) } +
            listOf(TranscribedWord("，", 1800, 1900)) +
            (0 until 6).map { TranscribedWord("后", 2000 + it * 100, 2050 + it * 100) }
        val out = TranscriptLines.mergeWords(words, spaced = false)
        out.forEach {
            assertTrue("这一行以标点起头:${it.text}", !TranscriptLines.isPunctOnly(it.text.take(1)))
        }
        assertTrue("逗号应当留在上一行尾", out.first().text.endsWith("，"))
    }

    /**
     * 27 字的 cue 早先整条进稿(`split` 的提前返回放宽到 1.5 倍行宽),上屏折成两行、
     * 第二行只剩几个字 —— 与"一行铺满 + 下一行一个字"同一个形状(H280)。
     */
    @Test
    fun `超一行的整条稿必被切开`() {
        val text = "这是一句刚好超过一行的稿件内容用来验证切分"
        assertTrue(text.length > TranscriptLines.CJK_CHARS)
        val out = TranscriptLines.split(text, 0, 1000)
        assertTrue("必须切成至少两条", out.size >= 2)
        out.forEach {
            assertTrue("实际 ${it.text.length} 字:${it.text}", it.text.length <= TranscriptLines.CJK_CHARS)
        }
        assertEquals(text, out.joinToString("") { it.text })
    }

    /// 中英混排里汉字不到一半,但按字宽折算已超过一行 —— 按西文的 38 切就会折行。
    @Test
    fun `中英混排按字宽折算选中文行宽`() {
        val mixed = "元今年 open a i 一度在部分收入指标上落后于 anropic 彭"
        val cjk = mixed.count { it.code in 0x3400..0x9FFF || it.code in 0xF900..0xFAFF }
        assertTrue("构造的样例汉字应不到一半", cjk * 2 < mixed.length)
        assertEquals(TranscriptLines.CJK_CHARS, TranscriptLines.targetChars(mixed))
    }

    /**
     * 首条是「4分之1。」这种混排小条目时,行宽不能只看它 —— 单看首条会判成西文 38 字,
     * 同一行后面再接汉字就撑到 25 字,上屏折两行(2026-11-13 Android 装机实测)。
     */
    @Test
    fun `首条是混排数字时行宽仍按中文`() {
        val out = TranscriptLines.mergeWords(
            listOf("4分之1。", "另外，", "面对签约运动员姆巴佩引发的", "争议，", "昂跑联席CEO表示，")
                .mapIndexed { i, t -> TranscribedWord(t, i * 100, i * 100 + 90) },
            spaced = false
        )
        out.forEach {
            assertTrue(
                "实际 ${it.text.length} 字:${it.text}",
                it.text.length <= TranscriptLines.CJK_CHARS + TranscriptLines.GLUE_OVERHANG
            )
        }
    }

    /// 行首 18 个字符被英文占满时,`headWindow` 会把整行判成西文 38 字,于是一条 38 字的混排行
    /// 上屏折两行(2026-11-13 鸿蒙装机实测)。`fitOneLine` 按整行重判后必须切开。
    @Test
    fun `行首是长串英文的混排行仍被切开`() {
        val out = TranscriptLines.mergeWords(
            listOf(
                "亿美元今年", " open a i ", "一度在部分收入指标上落后于", " anropic 彭"
            ).mapIndexed { i, t -> TranscribedWord(t, i * 100, i * 100 + 90) },
            spaced = false
        )
        out.forEach {
            assertTrue(
                "实际 ${it.text.length} 字:${it.text}",
                it.text.length <= TranscriptLines.CJK_CHARS + TranscriptLines.GLUE_OVERHANG
            )
        }
    }

    /// 旧判据"碎片不足 12 字就并"会并出 29 字,换行后第二行只剩孤字。
    @Test
    fun `并句不会并出一行放不下的段落`() {
        val out = TranscriptLines.glueOrphans(
            listOf(
                TranscribedSegment("甲".repeat(18), 0, 1000),
                TranscribedSegment("乙".repeat(11), 1100, 2000)
            )
        )
        assertEquals(2, out.size)
    }
}
