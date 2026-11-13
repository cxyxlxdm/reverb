package com.yuyin.reverb.util

import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.data.model.TranscribedWord

/**
 * 把逐字稿整理成**屏幕上一行左右**的句子。两条路都要用它,所以抽在这里:
 * - 官方稿(`TranscriptFetcher`):VTT 的 cue 可以长到几百字;
 * - 本机识别(`SenseVoiceEngine`):SenseVoice 直接吐带标点的整段,一个 26 秒块
 *   可能有几百字 —— 不切的话跟读高亮的粒度就是"整块一起亮"。
 *
 * 为什么必须切:跟读高亮的粒度就是句子的粒度。一段三百字的文本会整段高亮二十多秒,
 * 跟读效果等于没有,还得在屏幕上滚半天才看到当前位置。
 *
 * 时间轴按**字符占比**线性插值。一句话内部语速大体均匀,这个近似的误差远小于"整段一起亮"。
 * 真有词级时间的稿(Podcast Index JSON)走的是另一条路,不经过这里。
 */
object TranscriptLines {

    /**
     * 一行的目标字数。**中文与西文不是一个数** —— 一个汉字大约占两个西文字符的宽度。
     * 汉字占一半以上,或**有汉字且按字宽折算**已超过一行西文的容量,都按中文行宽走
     * (纯西文永远走 38,不受折算影响)。
     *
     * 只看"汉字是否过半数"会漏掉中英混排:"元今年 open a i 一度在部分收入指标上落后于
     * anropic 彭"汉字只有 47%,按 38 个字符切,上屏就是一行放不下再折一行 ——
     * 与 H280 修的是同一个形状,只是触发条件藏在混排里。
     */
    fun targetChars(text: String): Int {
        if (text.isEmpty()) return WEST_CHARS
        val cjk = text.count { it.code in 0x3400..0x9FFF || it.code in 0xF900..0xFAFF }
        val columns = cjk * 2 + (text.length - cjk)
        return if (cjk * 2 >= text.length || (cjk > 0 && columns > WEST_CHARS)) CJK_CHARS else WEST_CHARS
    }

    /**
     * 一句太长就切开,时间按字符占比分摊。**放得进一行的原样返回**(不复制也无所谓,列表很短)。
     *
     * 早先的提前返回放宽到 `target * 3 / 2`,切分窗口也取到 `target + target / 4` ——
     * 于是 27 字的 cue 整条进稿,上屏折成两行、第二行只剩几个字。行宽这把尺子的用途就是
     * "每一条都画得进一行",这一条不能有例外(见 H280);宁可硬切,不越一行。
     */
    fun split(text: String, startMs: Int, endMs: Int): List<TranscribedSegment> {
        val target = targetChars(text)
        if (text.length <= target) {
            return listOf(TranscribedSegment(text, startMs, endMs))
        }
        val chunks = ArrayList<String>()
        var rest = text
        while (rest.length > target) {
            // 优先在一行窗口内的句末标点断;找不到就退到最后一个空格;都没有(中文长句)就硬切
            val window = rest.take(target)
            val cut = window.indexOfLast { it in SENTENCE_END }.takeIf { it >= target / 2 }
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
     * 只由标点组成的条目(「，」「。」「……」这种)。
     *
     * 断行时它们**必须黏在前一行尾部**,原因有两条,都是 2026-11-13 在 Android 装机时看见的:
     * ① 中文排版不允许一行以「，」起头 —— 长度到点那一刻正好轮到一个逗号,屏幕上就是
     *    下一段以逗号开头;② 标点还占一个字宽,甩到新行会白白吃掉下一行的容量。
     * 所以 `mergeWords` 里做了两处:长度到点时**先看下一条是不是标点**(是就先别断),
     * 标点条目自己也不触发"超长先断"。
     */
    fun isPunctOnly(s: String): Boolean = s.isNotEmpty() && s.all { it in PUNCT_ONLY }

    private val PUNCT_ONLY = charArrayOf(
        '，', '。', '、', '；', '：', '！', '？', '…', '—',
        ',', '.', '!', '?', ';', ':', ')', '）', '」', '』', '》', '”', '’', '"'
    )

    /**
     * 把孤零零的碎片行并回上一行 —— 但**并完必须仍放得进一行**。
     *
     * 为什么需要:长度规则会在句末词之前就把行切掉,于是句子的最后一两个词单独成行 ——
     * 真实数据里 1480 行有 57 行不足 8 字,屏幕上就是"one." 独占一行,很难看。
     * 只在**与上一行几乎连着说**(间隔 < 400ms)时才并,否则那本来就是一句短的应答
     * (「Yes.」「我也是。」),独立成行是对的。
     *
     * 上限是"**并完之后**这一行的目标字数 + `GLUE_OVERHANG`":并句是为了消灭碎片行,
     * 不是为了把两行挤进一段。
     * 旧判据只看"碎片本身不足 12 字",于是 18+11=29 字也能并出来,换行后第二行只剩一两个字 ——
     * 与用户报的"一行铺满 + 一个字"是同一个形状(见 H280)。超出一行的尾巴**宁可让它自己成行**:
     * 一条 5~17 字的短句读着正常,挤出来的孤字不正常。
     */
    fun glueOrphans(lines: List<TranscribedSegment>): List<TranscribedSegment> {
        val out = ArrayList<TranscribedSegment>(lines.size)
        for (seg in lines) {
            val prev = out.lastOrNull()
            // 空格折进被并进来那一段的文本里,维持"words 拼接 == 整句"的不变式
            val glued = if (isAsciiHead(seg.text)) " ${seg.text}" else seg.text
            // 上限按**并完之后整行**的字宽判,不按上一行自己:上一行常是「4分之1。」这种
            // 五六个字的短条,单看它会被判成西文 38 字,于是并出一条 21 字的长行。
            val merged = prev?.let { it.text + glued }
            if (prev != null && merged != null && seg.startMs - prev.endMs < GLUE_GAP_MS
                && merged.length <= targetChars(merged) + GLUE_OVERHANG) {
                // 词级那边也要带上同一个空格:`TranscriptPane.karaokeLine` 是**逐条 words 拼接**
                // 出整行的(它故意不补空格,依据就是这条不变式)。早先这里直接
                // `prev.words + seg.words`,于是被并进来的那句首词丢了空格,屏幕上读出
                // "…andhe's" —— 不变式在注释里写着、代码里没做(见 H150)。
                val needSpace = glued.length != seg.text.length
                val segWords = seg.words?.let { ws ->
                    if (!needSpace || ws.isEmpty()) ws
                    else listOf(ws.first().copy(text = " ${ws.first().text}")) + ws.drop(1)
                }
                out[out.size - 1] = prev.copy(
                    text = prev.text + glued,
                    endMs = seg.endMs,
                    words = when {
                        prev.words == null && segWords == null -> null
                        else -> (prev.words ?: listOf(TranscribedWord(prev.text, prev.startMs, prev.endMs))) +
                                (segWords ?: listOf(TranscribedWord(glued, seg.startMs, seg.endMs)))
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
     * 这里是所有来源的共同入口(发布方的 JSON 稿、本机识别的 token),所以放在这里最省事:
     * 本机识别那条在 `SenseVoiceEngine.wordsFrom` 里已经保证过一遍(1.0.8 前是在 C++ 侧),
     * 这一道额外覆盖**发布方给的稿** ——
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

    /// 一行开头**一小段**(够一个汉字行宽)用于判行宽 —— 只取首条会误判混排小条目。
    private fun headWindow(words: List<TranscribedWord>, from: Int): String {
        val sb = StringBuilder()
        var k = from
        while (k < words.size && sb.length < CJK_CHARS) {
            sb.append(words[k].text)
            k++
        }
        return sb.toString()
    }

    /**
     * **细碎条目 → 可读的一行**,并把原始条目留在 `words` 里(于是能逐词高亮)。
     *
     * 三种来源都走这里,因为它们是同一个问题:
     * - 官方 JSON 稿:一条一个词(实测一集 10245 条);
     * - 本机识别的 token:一条一到两个汉字 / 一个英文子词(SenseVoice,1.0.8 前是 whisper);
     * - (将来)鸿蒙若换三方引擎,同样是 token 流。
     *
     * 三个断句依据,先到先断:句末标点 / 累计长度超过一行 / 与下一条之间静音超过 900ms
     * (换气或换人说话)。行宽按内容选:多数是汉字用 `CJK_CHARS`,否则 `WEST_CHARS`。
     *
     * @param spaced 传 true 表示条目**不自带空格**,需要按 ASCII 规则补(官方 JSON 稿);
     *   传 false 表示条目自带该有的空格(本机识别的 token),原样拼接。
     *   无论哪种,产出都满足 `words` 拼接 == 行文本这条不变式。
     */
    fun mergeWords(words: List<TranscribedWord>, spaced: Boolean): List<TranscribedSegment> {
        @Suppress("NAME_SHADOWING") val words = monotonic(words)
        val out = ArrayList<TranscribedSegment>()
        var buf = ArrayList<TranscribedWord>()
        var len = 0
        // 行宽按**这一行开头的一段**判中西文并锁定,不再按首条。首条常常是「4分之1。」
        // 这种五六个字的混排小条目,单看它会被判成西文(38 字),后面再接汉字就把同一行
        // 撑到 25 字 —— 上屏折两行(2026-11-13 Android 装机实测)。逐条重判也不行:中文句
        // 里夹一个英文词会让行宽一会儿 18 一会儿 38。
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
            // 需要补空格时**把空格折进 text**,以维持"拼接 == 整句"的不变式。
            // 空格算不算长度要在断行之前定:断完 len 归零,再加前缀就多一个空格。
            val wantSpace = spaced && isAsciiHead(w.text)
            // 长度到点就断,**但要先加再看**:旧写法是"加完再看 len >= target",而一个条目
            // 可能是 2~3 个字,于是每行实际能到 target+3 —— 21 字在 Android 的 20 字容量下
            // 正好溢出,屏幕上又是"一行铺满 + 下一行一个字"(H280 的同一个形状)。
            // 标点条目例外:让它黏在上一行尾(见 isPunctOnly)。
            if (buf.isNotEmpty() && !isPunctOnly(w.text)
                && len + w.text.length + (if (wantSpace) 1 else 0) > target) flush()
            if (buf.isEmpty()) target = targetChars(headWindow(words, i))
            val text = if (wantSpace && len > 0) " ${w.text}" else w.text
            buf.add(TranscribedWord(text, w.startMs, w.endMs))
            len += text.length
            val endsSentence = text.trimEnd().lastOrNull()?.let { it in SENTENCE_END } == true
            val gapNext = words.getOrNull(i + 1)?.let { it.startMs - w.endMs } ?: 0
            // 下一条是标点时先别断:否则它就成了下一行的第一个字(中文排版不允许)
            val nextIsPunct = words.getOrNull(i + 1)?.let { isPunctOnly(it.text) } == true
            if (endsSentence || gapNext > MAX_GAP_MS || (len >= target && !nextIsPunct)) flush()
        }
        flush()
        return glueOrphans(out).flatMap(::fitOneLine)
    }

    /**
     * 最后一道闸:**任何一条都必须画得进它自己那一行**。
     *
     * 前两道(按字宽折算、`headWindow` 取样)都只能拿到"一行开头"的信息:引擎一次吐出整句、
     * 或一行开头是一长串英文时,`headWindow` 那 18 个字符会被英文占满,整行汉字占多数的稿
     * 也会被判成西文 38 字 —— 上屏照样折两行(2026-11-13 鸿蒙装机实测:
     * 「亿美元今年 open a i 一度在部分收入指标上落后于 anropic 彭」38 字,第二行 6 个字)。
     * 这里按**整行**重判一次,超了就切;切出来的碎片不带词级时间 —— 那一行退化为行级高亮,
     * 好过在屏幕上折出第二行。
     */
    private fun fitOneLine(seg: TranscribedSegment): List<TranscribedSegment> =
        if (seg.text.length <= targetChars(seg.text) + GLUE_OVERHANG) listOf(seg)
        else split(seg.text, seg.startMs, seg.endMs)

    /// 句末标点(中西都收)。合并细碎条目与切分长句都按它断。
    val SENTENCE_END = charArrayOf('。', '！', '？', '；', '.', '!', '?', ';', '…')

    /**
     * 中文一行 18 字、西文 38 字符 —— 切出来的每一条都必须**画得进一行**。
     *
     * 原先写的是 24 / 42,注明"按手机屏宽估的",但**从没拿真机量过**。2026-11-13 在 Mate 60
     * (374 vp 宽、页面左右各 24 ⇒ 正文 326 vp、14 vp 字)上量到一行只放得下 **23 个汉字**:
     * 每条 24 字的段落因此恰好溢出 1 个字,屏幕上就是"一行铺满 + 下一行一个字",且断点落在词中间。
     * 鸿蒙逐字稿的字号已按另两端对齐到 16 vp(容量 ⇒ 20 个);Android 的 `bodyLarge`
     * (16sp + 0.5sp 字距、344 dp 正文)同样是 20 个 —— 24 对这两端都是**取整取在了临界点上**。
     *
     * 规律:目标字数要比**最窄那台机器**的容量再小两格,不能等于容量(等于就是"每次刚好溢出")。
     * 18 对应的容量下限是 360 dp 小屏(正文 312 dp ÷ 每字 16.5 dp ⇒ 18 个);
     * 38 按 18 × 2.1(汉字宽度约西文的 2.1 倍)折出来,西文又按词断开,余量更宽。
     * ⚠️ 系统字号调到 1.1 倍以上仍可能挤出一两个字 —— 固定尺子的固有边界:三端共用一把尺子
     * (跨端要能数行数,见 H150)优先于按每台机器的实际排版宽度算。
     */
    const val CJK_CHARS = 18
    const val WEST_CHARS = 38
    /// 细碎条目之间静音超过这个值就断句 —— 通常是换气或换人说话
    const val MAX_GAP_MS = 900
    /**
     * 并回上一行后允许比目标多出的**字数**。多一两个仍画得进一行(`CJK_CHARS` 那里留了余量),
     * 再多就会把第二行挤成一两个字 —— 那正是 2026-11-13 修掉的形状(见 H280)。
     *
     * 原先的判据是"碎片不足 12 字就并",**没有上限**。并句的目的只是别让「one.」独占一行,
     * 不是"越长越好"。
     */
    const val GLUE_OVERHANG = 2
    const val GLUE_GAP_MS = 400
}
