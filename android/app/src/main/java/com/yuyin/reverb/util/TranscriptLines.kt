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
                // 空格折进被并进来那一段的文本里,维持"words 拼接 == 整句"的不变式
                val glued = if (isAsciiHead(seg.text)) " ${seg.text}" else seg.text
                out[out.size - 1] = prev.copy(
                    text = prev.text + glued,
                    endMs = seg.endMs,
                    words = when {
                        prev.words == null && seg.words == null -> null
                        else -> (prev.words ?: listOf(TranscribedWord(prev.text, prev.startMs, prev.endMs))) +
                                (seg.words ?: listOf(TranscribedWord(glued, seg.startMs, seg.endMs)))
                    }
                )
            } else {
                out.add(seg)
            }
        }
        return out
    }

    /**
     * 把起点夹成**单调不减**、且不为负。所有带词级时间的稿都要过这一道。
     *
     * 为什么非做不可:渲染侧判断"读到哪个词/哪句"用的是
     * `indexOfLast { it.startMs <= nowMs }` —— 这个写法只在起点单调时才正确。
     * 队尾只要混进一个异常小的值,它就永远满足条件,于是**高亮钉死在那一条再也不动**
     * (真实事故见 TROUBLESHOOTING H60:某些 token 算不出时刻、退化成 -1)。
     *
     * 这里是所有来源的共同入口(发布方的 JSON 稿、whisper 的 token),所以放在这里最省事:
     * 本机识别那条在 C++ 侧已经保证过一遍,这一道额外覆盖**发布方给的稿** ——
     * 别人生成的文件不能假定一定按时间排好。终点同时保证不早于起点。
     */
    private fun monotonic(words: List<TranscribedWord>): List<TranscribedWord> {
        var prev = 0
        var needFix = false
        for (w in words) {
            if (w.startMs < prev || w.startMs < 0 || w.endMs < w.startMs) { needFix = true; break }
            prev = w.startMs
        }
        if (!needFix) return words                 // 绝大多数情况:原样返回,不复制
        var at = 0
        return words.map { w ->
            val s = maxOf(w.startMs, at)
            at = s
            TranscribedWord(w.text, s, maxOf(w.endMs, s))
        }
    }

    /// 以 ASCII 起头 ⇒ 拼接时前面要加空格(中文之间不加)。
    fun isAsciiHead(s: String): Boolean = s.firstOrNull()?.code?.let { it < 128 } == true

    /**
     * **细碎条目 → 可读的一行**,并把原始条目留在 `words` 里(于是能逐词高亮)。
     *
     * 三种来源都走这里,因为它们是同一个问题:
     * - 官方 JSON 稿:一条一个词(实测一集 10245 条);
     * - whisper 的 token:一条一到两个汉字 / 一个英文子词;
     * - (将来)鸿蒙若换三方引擎,同样是 token 流。
     *
     * 三个断句依据,先到先断:句末标点 / 累计长度超过一行 / 与下一条之间静音超过 900ms
     * (换气或换人说话)。行宽按内容选:多数是汉字用 24,否则 42。
     *
     * @param spaced 传 true 表示条目**不自带空格**,需要按 ASCII 规则补(官方 JSON 稿);
     *   传 false 表示条目自带该有的空格(whisper token),原样拼接。
     *   无论哪种,产出都满足 `words` 拼接 == 行文本这条不变式。
     */
    fun mergeWords(words: List<TranscribedWord>, spaced: Boolean): List<TranscribedSegment> {
        @Suppress("NAME_SHADOWING") val words = monotonic(words)
        val out = ArrayList<TranscribedSegment>()
        var buf = ArrayList<TranscribedWord>()
        var len = 0
        // 行宽按**这一行的首条**判中西文并锁定。逐条重判会在中文句里夹一个英文词时
        // 突然把行宽从 24 放到 42,断句就一会儿宽一会儿窄。
        var target = WEST_CHARS

        fun flush() {
            if (buf.isEmpty()) return
            val text = buf.joinToString("") { it.text }
            out.add(
                TranscribedSegment(
                    text = text,
                    startMs = buf.first().startMs,
                    endMs = buf.last().endMs,
                    // 只有真的合了多条才留词级时间;本来就是整句的稿留了也没用,白占缓存
                    words = if (buf.size > 1) ArrayList(buf) else null
                )
            )
            buf = ArrayList()
            len = 0
        }

        for ((i, w) in words.withIndex()) {
            // 需要补空格时**把空格折进 text**,以维持"拼接 == 整句"的不变式
            val text = if (spaced && len > 0 && isAsciiHead(w.text)) " ${w.text}" else w.text
            if (buf.isEmpty()) target = targetChars(text)
            buf.add(TranscribedWord(text, w.startMs, w.endMs))
            len += text.length
            val endsSentence = text.trimEnd().lastOrNull()?.let { it in SENTENCE_END } == true
            val gapNext = words.getOrNull(i + 1)?.let { it.startMs - w.endMs } ?: 0
            if (endsSentence || len >= target || gapNext > MAX_GAP_MS) flush()
        }
        flush()
        return glueOrphans(out)
    }

    /// 句末标点(中西都收)。合并细碎条目与切分长句都按它断。
    val SENTENCE_END = charArrayOf('。', '！', '？', '；', '.', '!', '?', ';', '…')

    /// 中文一行 24 字、西文 42 字符 —— 都是按手机屏宽估的
    const val CJK_CHARS = 24
    const val WEST_CHARS = 42
    /// 细碎条目之间静音超过这个值就断句 —— 通常是换气或换人说话
    const val MAX_GAP_MS = 900
    const val ORPHAN_CHARS = 12
    const val GLUE_GAP_MS = 400
}
