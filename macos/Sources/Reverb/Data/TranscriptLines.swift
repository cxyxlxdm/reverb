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
    /// 中文一行 24 字、西文 42 字符 —— 都按手机屏宽估的,桌面沿用同一把尺子:
    /// 行数一致比"桌面更宽可以多放几个字"重要,那是跨端核对的基本单位。
    static let cjkChars = 24
    static let westChars = 42
    /// 条目之间静音超过这个值就断句 —— 通常是换气或换人说话
    static let maxGapMs = 900
    /// 不足这么多字算碎片(并回上一行)
    static let orphanChars = 12
    /// 与上一行几乎连着说(间隔小于它)才并 —— 否则本来就是一句短应答
    static let glueGapMs = 400

    /// 句末标点(中西都收)。合并细碎条目与切分长句都按它断。
    private static let sentenceEnd: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";", "…"]

    /// 一行的目标字数。按内容里 CJK 的比例选:多数是汉字就用 24,否则 42。
    static func targetChars(_ text: String) -> Int {
        guard !text.isEmpty else { return westChars }
        var cjk = 0
        for u in text.unicodeScalars {
            let v = u.value
            if (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) { cjk += 1 }
        }
        return cjk * 2 >= text.count ? cjkChars : westChars
    }

    /// 一句太长就切开,时间按字符占比分摊。短句原样返回。
    static func split(_ text: String, startMs: Int, endMs: Int) -> [TranscribedSegment] {
        let target = targetChars(text)
        if text.count <= target * 3 / 2 {
            return [TranscribedSegment(text: text, startMs: startMs, endMs: endMs)]
        }

        let chars = Array(text)
        var chunks: [String] = []
        var pos = 0
        while chars.count - pos > target {
            let windowEnd = min(chars.count, pos + target + target / 4)
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

    /// 把孤零零的碎片行并回上一行。只在**与上一行几乎连着说**时才并,
    /// 否则那本来就是一句短的应答(「Yes.」「我也是。」),独立成行是对的。
    ///
    /// 并完可能略超一行目标字数 —— 这是有意的:多两个词比多一行碎片好看。
    static func glueOrphans(_ lines: [TranscribedSegment]) -> [TranscribedSegment] {
        var out: [TranscribedSegment] = []
        out.reserveCapacity(lines.count)
        for seg in lines {
            guard let prev = out.last,
                  seg.text.count < orphanChars,
                  seg.startMs - prev.endMs < glueGapMs else {
                out.append(seg)
                continue
            }
            // 空格折进被并进来那一段的文本里,维持「words 拼接 == 整句」的不变式;
            // 词级那边也要带上同一个空格,否则卡拉OK会读出 "…andhe's"(H150)。
            let needSpace = isAsciiHead(seg.text)
            let glued = needSpace ? " " + seg.text : seg.text
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
        // 行宽按**这一行的首条**判中西文并锁定:逐条重判会在中文句里夹一个英文词时
        // 突然把行宽从 24 放到 42,断句就一会儿宽一会儿窄。
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
            let text = (spaced && len > 0 && isAsciiHead(w.text)) ? " " + w.text : w.text
            if buf.isEmpty { target = targetChars(text) }
            buf.append(TranscribedWord(text: text, startMs: w.startMs, endMs: w.endMs))
            len += text.count
            let lastNonSpace = text.last { !$0.isWhitespace }
            let endsSentence = lastNonSpace.map { sentenceEnd.contains($0) } ?? false
            let gapNext = i + 1 < words.count ? words[i + 1].startMs - w.endMs : 0
            if endsSentence || len >= target || gapNext > maxGapMs { flush() }
        }
        flush()
        return glueOrphans(out)
    }

    /// 以 ASCII 起头 ⇒ 拼接时前面要加空格(中文之间不加)。
    static func isAsciiHead(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        return first.value < 128
    }
}
