package com.yuyin.reverb.util

import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.data.model.TranscribedWord

/**
 * 把逐字稿整理成**屏幕上一行左右**的句子。两条路都要用它,所以抽在这里:
 * - 官方稿(`TranscriptFetcher`):VTT 的 cue 可以长到几百字;
 * - 本机识别(`WhisperEngine`):给了标点提示词之后,whisper 会吐出整段带标点的长句。
 *
 * 为什么必须切:跟读高亮的粒度就是句子的粒度。一段三百字的文本会整段高亮二十多秒,
 * 跟读效果等于没有,还得在屏幕上滚半天才看到当前位置。
 *
 * 时间轴按**字符占比**线性插值。一句话内部语速大体均匀,这个近似的误差远小于"整段一起亮"。
 * 真有词级时间的稿(Podcast Index JSON)走的是另一条路,不经过这里。
 */
object TranscriptLines {

    /**
     * 一行的目标字数。**中文与西文不是一个数** —— 汉字宽得多,42 个汉字在手机上要占三行。
     * 按内容里 CJK 的比例选:多数是汉字就用 24,否则 42。
     */
    fun targetChars(text: String): Int {
        if (text.isEmpty()) return WEST_CHARS
        val cjk = text.count { it.code in 0x3400..0x9FFF || it.code in 0xF900..0xFAFF }
        return if (cjk * 2 >= text.length) CJK_CHARS else WEST_CHARS
    }

    /**
     * 一句太长就切开,时间按字符占比分摊。短句原样返回(不复制对象也无所谓,列表很短)。
     */
    fun split(text: String, startMs: Int, endMs: Int): List<TranscribedSegment> {
        val target = targetChars(text)
        if (text.length <= target * 3 / 2) {
            return listOf(TranscribedSegment(text, startMs, endMs))
        }
        val chunks = ArrayList<String>()
        var rest = text
        while (rest.length > target) {
            // 优先在目标长度附近的句末标点断;找不到就退到最后一个空格;都没有(中文长句)就硬切
            val window = rest.take(target + target / 4)
            val cut = window.indexOfLast { it in SENTENCE_END }.let { if (it >= target / 2) it else -1 }
                .takeIf { it > 0 }
                ?: window.lastIndexOf(' ').takeIf { it >= target / 2 }
                ?: (target - 1)
            chunks.add(rest.take(cut + 1).trim())
            rest = rest.drop(cut + 1).trimStart()
        }
        if (rest.isNotBlank()) chunks.add(rest)

        val total = chunks.sumOf { it.length }.coerceAtLeast(1)
        val span = (endMs - startMs).coerceAtLeast(0)
        val out = ArrayList<TranscribedSegment>(chunks.size)
        var acc = 0
        for (c in chunks) {
            val s = startMs + span * acc / total
            acc += c.length
            val e = startMs + span * acc / total
            out.add(TranscribedSegment(c, s, maxOf(e, s)))
        }
        return out
    }

    /**
     * 把孤零零的碎片行并回上一行。
     *
     * 为什么需要:长度规则会在句末词之前就把行切掉,于是句子的最后一两个词单独成行 ——
     * 真实数据里 1480 行有 57 行不足 8 字,屏幕上就是"one." 独占一行,很难看。
     * 只在**与上一行几乎连着说**(间隔 < 400ms)时才并,否则那本来就是一句短的应答
     * (「Yes.」「我也是。」),独立成行是对的。
     *
     * 并完可能略超一行的目标字数 —— 这是有意的:多两个词比多一行碎片好看。
     */
    fun glueOrphans(lines: List<TranscribedSegment>): List<TranscribedSegment> {
        val out = ArrayList<TranscribedSegment>(lines.size)
        for (seg in lines) {
            val prev = out.lastOrNull()
            if (prev != null && seg.text.length < ORPHAN_CHARS && seg.startMs - prev.endMs < GLUE_GAP_MS) {
                val sep = if (isAsciiHead(seg.text)) " " else ""
                out[out.size - 1] = prev.copy(
                    text = prev.text + sep + seg.text,
                    endMs = seg.endMs,
                    words = when {
                        prev.words == null && seg.words == null -> null
                        else -> (prev.words ?: listOf(TranscribedWord(prev.text, prev.startMs, prev.endMs))) +
                                (seg.words ?: listOf(TranscribedWord(seg.text, seg.startMs, seg.endMs)))
                    }
                )
            } else {
                out.add(seg)
            }
        }
        return out
    }

    /// 以 ASCII 起头 ⇒ 拼接时前面要加空格(中文之间不加)。
    fun isAsciiHead(s: String): Boolean = s.firstOrNull()?.code?.let { it < 128 } == true

    /// 句末标点(中西都收)。合并细碎条目与切分长句都按它断。
    val SENTENCE_END = charArrayOf('。', '！', '？', '；', '.', '!', '?', ';', '…')

    /// 中文一行 24 字、西文 42 字符 —— 都是按手机屏宽估的
    const val CJK_CHARS = 24
    const val WEST_CHARS = 42
    const val ORPHAN_CHARS = 12
    const val GLUE_GAP_MS = 400
}
