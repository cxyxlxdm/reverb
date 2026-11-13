package com.yuyin.reverb.util

import com.yuyin.reverb.data.model.TranscribedSegment

/**
 * 逐字稿的全文搜索:找出**哪些句子**命中了,以及每句里**哪些区间**要贴底色。
 *
 * 为什么区间要在这里一次算完:渲染侧一句一次 `indexOf` 看着不贵,但词级高亮打开时
 * 当前句每 80ms 就重建一次 `AnnotatedString`(见 `TranscriptPane.karaokeLine` 的调用处),
 * 那句里的匹配区间就该是现成的。这与硬规矩 6 是同一件事:解析不要在渲染路径里做。
 *
 * 大小写不敏感比较交给 `String.indexOf(ignoreCase = true)`,不自己做 `lowercase()` ——
 * 某些语言的大小写折叠会改变长度(土耳其语 İ 之类),拿折叠后的下标去切原文会错位。
 */
object TranscriptSearch {

    /** 一条命中:句子的下标 + 该句内要贴底色的区间(左闭右开,`IntRange.last` 是闭端)。 */
    data class Hit(val index: Int, val ranges: List<IntRange>)

    data class Result(
        val hits: List<Hit>,
        val rangesByIndex: Map<Int, List<IntRange>>
    ) {
        val isEmpty: Boolean get() = hits.isEmpty()
        val indices: List<Int> get() = hits.map { it.index }
    }

    val EMPTY = Result(emptyList(), emptyMap())

    /**
     * @param query 调用方已经 `trim()` 过。空串直接返回 [EMPTY] —— 空白查询不该把整篇涂亮。
     */
    fun find(segments: List<TranscribedSegment>, query: String): Result {
        if (query.isEmpty() || segments.isEmpty()) return EMPTY
        val hits = ArrayList<Hit>()
        val ranges = HashMap<Int, List<IntRange>>()
        for (i in segments.indices) {
            val found = rangesIn(segments[i].text, query)
            if (found.isNotEmpty()) {
                hits.add(Hit(i, found))
                ranges[i] = found
            }
        }
        return Result(hits, ranges)
    }

    /**
     * 一句里的所有命中区间。允许重叠之外的重叠没有意义 —— 从上一处命中之后继续找,
     * 单字符查询在长句里也不会退化成平方级。
     */
    fun rangesIn(text: String, query: String): List<IntRange> {
        if (text.isEmpty() || query.isEmpty()) return emptyList()
        var from = 0
        var out: ArrayList<IntRange>? = null
        while (from <= text.length - 1) {
            val at = text.indexOf(query, from, ignoreCase = true)
            if (at < 0) break
            val end = (at + query.length).coerceAtMost(text.length)
            if (end > at) {
                (out ?: ArrayList<IntRange>(4).also { out = it }).add(at until end)
            }
            from = if (end > at) end else at + 1
        }
        return out ?: emptyList()
    }
}
