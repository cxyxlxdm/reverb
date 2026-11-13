import Foundation

/// 把逐字稿整理成**屏幕上一行左右**的句子。
///
/// 这是 Android `util/TranscriptLines.kt` 的逐条移植,两条取稿路径都要经过它:
/// - 发布方官方稿(`TranscriptFetcher`):VTT 的 cue 可以长到几百字,JSON 稿常常一条只有一两个词;
/// - 本机识别(Apple `SpeechTranscriber`):它给的 run 也不保证按句子切。
///
/// 口径必须与手机两端一致,否则同一份 JSON 稿在桌面上会断成不同的行数
/// (三端行数曾经分叉过一次,见 docs/TROUBLESHOOTING.md H150)。
enum TranscriptLines {
    /// 中文一行 18 字、西文 38 字符 —— 切出来的每一条都必须**画得进一行**。
    ///
    /// 原先写的是 24 / 42,注明"按手机屏宽估的",但**从没拿真机量过**。2026-11-13 在 Mate 60
    /// (374 vp 宽、页面左右各 24 ⇒ 正文 326 vp)上量到:14 vp 字一行只放得下 **23 个汉字**,
    /// 每条 24 字的段落因此恰好溢出 1 个字,屏幕上就是"一行铺满 + 下一行一个字",断点还落在词中间
    /// (用户报的就是这个)。鸿蒙字号已对齐到 16 vp(容量 ⇒ 20 个);Android 的 `bodyLarge`
    /// (16sp + 0.5sp 字距、344 dp 正文)也是 20 个;iPhone 的 `.body` 17pt、正文 362 pt ⇒ 21 个 ——
    /// 24 对手机三端都是**取整取在了临界点上**。
    ///
    /// 规律:目标字数要比**最窄那台机器**的容量再小两格,不能等于容量(等于就是"每次刚好溢出")。
    /// 18 对应的容量下限是 360 dp 小屏(正文 312 dp ÷ 每字 16.5 dp ⇒ 18 个);
    /// 38 按 18 × 2.1(汉字宽度约西文的 2.1 倍)折出来,西文又按词断开,余量更宽。
    ///
    /// 桌面沿用同一把尺子,尽管窗口宽得多 —— 行数一致比"桌面能多放几个字"重要,
    /// 那是跨端核对的基本单位。⚠️ 系统字号/动态字体调大后仍可能挤出一两个字:固定尺子的固有边界。
    static let cjkChars = 18
    static let westChars = 38
    /// 条目之间静音超过这个值就断句 —— 通常是换气或换人说话
    static let maxGapMs = 900
    /// 并回上一行后允许比目标多出的**字数**。多一两个仍画得进一行(`cjkChars` 那里留了余量),
    /// 再多就会把第二行挤成一两个字 —— 那正是 2026-11-13 修掉的形状(见 H280)。
    static let glueOverhang = 2
    /// 与上一行几乎连着说(间隔小于它)才并 —— 否则本来就是一句短应答
    static let glueGapMs = 400

    /// 句末标点(中西都收)。合并细碎条目与切分长句都按它断。
    private static let sentenceEnd: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";", "…"]

    /// 一行的目标字数。汉字占一半以上,或**有汉字且按字宽折算**已超过一行西文的容量,
    /// 都按中文行宽走(纯西文永远走 38,不受折算影响)。
    ///
    /// 只看"汉字是否过半数"会漏掉中英混排:"元今年 open a i 一度在部分收入指标上落后于
    /// anropic 彭"汉字只有 47%,按 38 个字符切,上屏就是一行放不下再折一行 ——
    /// 与 H280 修的是同一个形状,只是触发条件藏在混排里。
    static func targetChars(_ text: String) -> Int {
        guard !text.isEmpty else { return westChars }
        var cjk = 0
        for u in text.unicodeScalars {
            let v = u.value
            if (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) { cjk += 1 }
        }
        let columns = cjk * 2 + (text.count - cjk)
        return (cjk * 2 >= text.count || (cjk > 0 && columns > westChars)) ? cjkChars : westChars
    }

    /// 一句太长就切开,时间按字符占比分摊。**放得进一行的原样返回**。
    ///
    /// 早先的提前返回放宽到 `target * 3 / 2`,切分窗口也取到 `target + target / 4` ——
    /// 于是 27 字的 cue 整条进稿,上屏折成两行、第二行只剩几个字。行宽这把尺子的用途就是
    /// "每一条都画得进一行",这一条不能有例外(见 H280);宁可硬切,不越一行。
    static func split(_ text: String, startMs: Int, endMs: Int) -> [TranscribedSegment] {
        let target = targetChars(text)
        if text.count <= target {
            return [TranscribedSegment(text: text, startMs: startMs, endMs: endMs)]
        }

        let chars = Array(text)
        var chunks: [String] = []
        var pos = 0
        while chars.count - pos > target {
            let windowEnd = min(chars.count, pos + target)
            // 优先在目标长度附近的句末标点断;找不到就退到最后一个空格;都没有(中文长句)就硬切
            var cut = -1
            var i = windowEnd - 1
            while i >= pos {
                if sentenceEnd.contains(chars[i]) { cut = i; break }
                i -= 1
            }
            if !(cut > pos && cut - pos >= target / 2) { cut = -1 }
            if cut < 0 {
                var j = windowEnd - 1
                while j >= pos {
                    if chars[j] == " " { cut = j; break }
                    j -= 1
                }
                if !(cut >= 0 && cut - pos >= target / 2) { cut = -1 }
            }
            if cut < 0 { cut = pos + target - 1 }

            let piece = String(chars[pos...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            pos = cut + 1
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
        }
        if pos < chars.count {
            let tail = String(chars[pos...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { chunks.append(tail) }
        }

        let total = max(chunks.reduce(0) { $0 + $1.count }, 1)
        let span = max(endMs - startMs, 0)
        var acc = 0
        var out: [TranscribedSegment] = []
        out.reserveCapacity(chunks.count)
        for c in chunks {
            let s = startMs + span * acc / total
            acc += c.count
            let e = startMs + span * acc / total
            out.append(TranscribedSegment(text: c, startMs: s, endMs: max(e, s)))
        }
        return out
    }

    /// 把孤零零的碎片行并回上一行 —— 但**并完必须仍放得进一行**。只在**与上一行几乎连着说**时才并,
    /// 否则那本来就是一句短的应答(「Yes.」「我也是。」),独立成行是对的。
    ///
    /// 上限是"**并完之后**这一行的目标字数 + `glueOverhang`":并句是为了消灭碎片行,
    /// 不是为了把两行挤进一段。
    /// 旧判据只看"碎片本身不足 12 字",于是 18+11=29 字也能并出来,换行后第二行只剩一两个字 ——
    /// 与"一行铺满 + 一个字"是同一个形状(见 H280)。超出一行的尾巴**宁可让它自己成行**。
    static func glueOrphans(_ lines: [TranscribedSegment]) -> [TranscribedSegment] {
        var out: [TranscribedSegment] = []
        out.reserveCapacity(lines.count)
        for seg in lines {
            // 空格折进被并进来那一段的文本里,维持「words 拼接 == 整句」的不变式;
            // 词级那边也要带上同一个空格,否则卡拉OK会读出 "…andhe's"(H150)。
            let needSpace = isAsciiHead(seg.text)
            let glued = needSpace ? " " + seg.text : seg.text
            // 上限按**并完之后整行**的字宽判,不按上一行自己:上一行常是「4分之1。」这种
            // 五六个字的短条,单看它会被判成西文 38 字,于是并出一条 21 字的长行。
            guard let prev = out.last,
                  seg.startMs - prev.endMs < glueGapMs,
                  prev.text.count + glued.count <= targetChars(prev.text + glued) + glueOverhang else {
                out.append(seg)
                continue
            }
            var segWords = seg.words
            if needSpace, var ws = segWords, !ws.isEmpty {
                ws[0] = TranscribedWord(text: " " + ws[0].text,
                                        startMs: ws[0].startMs, endMs: ws[0].endMs)
                segWords = ws
            }
            let mergedWords: [TranscribedWord]?
            if prev.words == nil && segWords == nil {
                mergedWords = nil
            } else {
                mergedWords = (prev.words ?? [TranscribedWord(text: prev.text, startMs: prev.startMs, endMs: prev.endMs)])
                    + (segWords ?? [TranscribedWord(text: glued, startMs: seg.startMs, endMs: seg.endMs)])
            }
            out[out.count - 1] = TranscribedSegment(
                text: prev.text + glued, startMs: prev.startMs, endMs: seg.endMs, words: mergedWords)
        }
        return out
    }

    /// 把起点夹成**单调不减**、且不为负。所有带词级时间的稿都要过这一道。
    ///
    /// 渲染侧判断"读到哪个词/哪句"用的是 `lastIndex { startMs <= now }` ——
    /// 这个写法只在起点单调时才正确;队尾混进一个异常小的值就会让高亮钉死(H60)。
    /// 别人生成的时间轴不能假定排好,所以这道理应放在**所有来源的共同入口**。
    static func monotonicWords(_ words: [TranscribedWord]) -> [TranscribedWord] {
        var prev = 0
        var needFix = false
        for w in words {
            if w.startMs < prev || w.startMs < 0 || w.endMs < w.startMs {
                needFix = true
                break
            }
            prev = w.startMs
        }
        if !needFix { return words }   // 绝大多数情况:原样返回,不复制
        var at = 0
        return words.map { w in
            let s = max(w.startMs, at)
            at = s
            return TranscribedWord(text: w.text, startMs: s, endMs: max(w.endMs, s))
        }
    }

    /// 细碎条目 → 可读的一行,并把原始条目留在 `words` 里(于是能逐词高亮)。
    ///
    /// - `spaced == true`:条目**不自带空格**,按 ASCII 规则补(发布方 JSON 稿);
    /// - `spaced == false`:条目自带该有的空格,原样拼接(将来别的引擎)。
    ///
    /// 两种都满足 `words` 拼接 == 行文本这条不变式(卡拉OK逐条拼接整行,不补空格)。
    static func mergeWords(_ input: [TranscribedWord], spaced: Bool) -> [TranscribedSegment] {
        let words = monotonicWords(input)
        var out: [TranscribedSegment] = []
        var buf: [TranscribedWord] = []
        var len = 0
        // 行宽按**这一行开头的一段**判中西文并锁定,不再按首条。首条常常是「4分之1。」
        // 这种五六个字的混排小条目,单看它会被判成西文(38 字),后面再接汉字就把同一行
        // 撑到 25 字 —— 上屏折两行(2026-11-13 Android 装机实测)。逐条重判也不行:中文句
        // 里夹一个英文词会让行宽一会儿 18 一会儿 38。
        var target = westChars

        func flush() {
            if buf.isEmpty { return }
            let text = buf.map { $0.text }.joined()
            out.append(TranscribedSegment(
                text: text,
                startMs: buf[0].startMs,
                endMs: buf[buf.count - 1].endMs,
                // 只有真的合了多条才留词级时间;本来就是整句的稿留了也白占缓存
                words: buf.count > 1 ? buf : nil))
            buf.removeAll()
            len = 0
        }

        for (i, w) in words.enumerated() {
            // 空格算不算长度要在断行之前定:断完 len 归零,再加前缀就多一个空格
            let wantSpace = spaced && isAsciiHead(w.text)
            // 长度到点就断,**但要先加再看**:旧写法是"加完再看 len >= target",而一个条目
            // 可能是 2~3 个字,于是每行实际能到 target+3 —— 21 字在 Android 的 20 字容量下
            // 正好溢出,屏幕上又是"一行铺满 + 下一行一个字"(H280 的同一个形状)。
            // 标点条目例外:让它黏在上一行尾(见 isPunctOnly)。
            if !buf.isEmpty, !isPunctOnly(w.text),
               len + w.text.count + (wantSpace ? 1 : 0) > target {
                flush()
            }
            if buf.isEmpty { target = targetChars(headWindow(words, from: i)) }
            let text = (wantSpace && len > 0) ? " " + w.text : w.text
            buf.append(TranscribedWord(text: text, startMs: w.startMs, endMs: w.endMs))
            len += text.count
            let lastNonSpace = text.last { !$0.isWhitespace }
            let endsSentence = lastNonSpace.map { sentenceEnd.contains($0) } ?? false
            let gapNext = i + 1 < words.count ? words[i + 1].startMs - w.endMs : 0
            // 下一条是标点时先别断:否则它就成了下一行的第一个字(中文排版不允许)
            let nextIsPunct = i + 1 < words.count && isPunctOnly(words[i + 1].text)
            if endsSentence || gapNext > maxGapMs || (len >= target && !nextIsPunct) { flush() }
        }
        flush()
        return glueOrphans(out).flatMap(fitOneLine)
    }

    /// 最后一道闸:**任何一条都必须画得进它自己那一行**。
    ///
    /// 前两道(按字宽折算、`headWindow` 取样)都只能拿到"一行开头"的信息:引擎一次吐出整句、
    /// 或一行开头是一长串英文时,`headWindow` 那 18 个字符会被英文占满,整行汉字占多数的稿
    /// 也会被判成西文 38 字 —— 上屏照样折两行(2026-11-13 鸿蒙装机实测:
    /// 「亿美元今年 open a i 一度在部分收入指标上落后于 anropic 彭」38 字,第二行 6 个字)。
    /// 这里按**整行**重判一次,超了就切;切出来的碎片不带词级时间 —— 那一行退化为行级高亮,
    /// 好过在屏幕上折出第二行。
    private static func fitOneLine(_ seg: TranscribedSegment) -> [TranscribedSegment] {
        seg.text.count <= targetChars(seg.text) + glueOverhang
            ? [seg]
            : split(seg.text, startMs: seg.startMs, endMs: seg.endMs)
    }

    /// 只由标点组成的条目(「，」「。」「……」这种)。
    ///
    /// 断行时它们**必须黏在前一行尾部**,原因有两条,都是 2026-11-13 在 Android 装机时看见的:
    /// ① 中文排版不允许一行以「，」起头 —— 长度到点那一刻正好轮到一个逗号,屏幕上就是
    /// 下一段以逗号开头;② 标点还占一个字宽,甩到新行会白白吃掉下一行的容量。
    static func isPunctOnly(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { punctOnly.contains($0) }
    }

    private static let punctOnly: Set<Character> = [
        "，", "。", "、", "；", "：", "！", "？", "…", "—",
        ",", ".", "!", "?", ";", ":", ")", "）", "」", "』", "》", "”", "’", "\"",
    ]

    /// 以 ASCII 起头 ⇒ 拼接时前面要加空格(中文之间不加)。
    static func isAsciiHead(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        return first.value < 128
    }

    /// 一行开头**一小段**(够一个汉字行宽)用于判行宽 —— 只取首条会误判混排小条目。
    private static func headWindow(_ words: [TranscribedWord], from: Int) -> String {
        var head = ""
        var k = from
        while k < words.count, head.count < cjkChars {
            head += words[k].text
            k += 1
        }
        return head
    }
}
