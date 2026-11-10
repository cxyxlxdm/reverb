package com.yuyin.reverb.util

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
}
