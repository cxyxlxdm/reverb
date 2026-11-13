import XCTest
@testable import Reverb

/// 逐字稿时间轴的两条不变式(H60 / 硬规矩 10):起点 >= 0 且单调不减;
/// 拼接文本与词表一致。三端同一份口径,行宽也必须是同一个数。
final class TranscriptLinesTests: XCTestCase {
    func testMonotonicWordsKeepsGoodInput() {
        let words = [
            TranscribedWord(text: "a", startMs: 0, endMs: 100),
            TranscribedWord(text: "b", startMs: 100, endMs: 200)
        ]
        XCTAssertEqual(TranscriptLines.monotonicWords(words), words)
    }

    func testMonotonicWordsClampsBackwardsAndNegative() {
        let fixed = TranscriptLines.monotonicWords([
            TranscribedWord(text: "a", startMs: 100, endMs: 200),
            TranscribedWord(text: "b", startMs: 50, endMs: 300),
            TranscribedWord(text: "c", startMs: -5, endMs: 10)
        ])
        XCTAssertEqual(fixed.map(\.startMs), [100, 100, 100])
        for (a, b) in zip(fixed, fixed.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.startMs, a.startMs)
        }
        for w in fixed {
            XCTAssertGreaterThanOrEqual(w.startMs, 0)
            XCTAssertGreaterThanOrEqual(w.endMs, w.startMs)
        }
    }

    func testMergeWordsInsertsAsciiSpaces() {
        let merged = TranscriptLines.mergeWords([
            TranscribedWord(text: "Hello", startMs: 0, endMs: 100),
            TranscribedWord(text: "world", startMs: 100, endMs: 200)
        ], spaced: true)
        XCTAssertEqual(merged.map(\.text).joined(), "Hello world")
    }

    func testMergeWordsPreservesTextWithoutSpacedMode() {
        let merged = TranscriptLines.mergeWords([
            TranscribedWord(text: "你", startMs: 0, endMs: 100),
            TranscribedWord(text: "好", startMs: 100, endMs: 200)
        ], spaced: false)
        XCTAssertEqual(merged.map(\.text).joined(), "你好")
    }

    /// 行宽是**跨端共用的尺子**,不是一个随手能改的显示参数:它比一台手机真能放下的字数
    /// 小两格,段落才不会"一行铺满 + 下一行一个字"(见 H280)。
    func testLineWidthsAreTheSharedNumbers() {
        XCTAssertEqual(TranscriptLines.cjkChars, 18)
        XCTAssertEqual(TranscriptLines.westChars, 38)
        XCTAssertEqual(TranscriptLines.targetChars("这是一段中文"), 18)
        XCTAssertEqual(TranscriptLines.targetChars("this is english"), 38)
    }

    /// 24 个汉字必须断成两条(24 > 18),而且每条都放得进一行 —— 任何一条超出去,
    /// 手机上就会多出半行孤字。
    func testCjkRunNeverExceedsOneLine() {
        let words = (0..<24).map { i in
            TranscribedWord(text: "字", startMs: i * 100, endMs: i * 100 + 90)
        }
        let segs = TranscriptLines.mergeWords(words, spaced: false)
        XCTAssertGreaterThanOrEqual(segs.count, 2)
        for s in segs {
            XCTAssertLessThanOrEqual(s.text.count, TranscriptLines.cjkChars)
        }
        XCTAssertEqual(segs.map(\.text).joined(), String(repeating: "字", count: 24))
    }

    /// 长度是**加之前**判的:一条 3 个字的词卡在边界上时,旧写法会产出 21 字
    /// (18 加完再看),而 Android 正文一行只放得下 20 个。
    func testMultiCharTokensDoNotOverflowLine() {
        let words = (0..<8).map { i in
            TranscribedWord(text: "三个字", startMs: i * 500, endMs: i * 500 + 400)
        }
        for s in TranscriptLines.mergeWords(words, spaced: false) {
            XCTAssertLessThanOrEqual(s.text.count, TranscriptLines.cjkChars, s.text)
        }
    }

    /// 中文排版不允许一行以「，」起头:长度到点那一刻正好轮到逗号时,逗号要黏在上一行尾。
    func testPunctuationNeverStartsALine() {
        var words = (0..<18).map { i in
            TranscribedWord(text: "字", startMs: i * 100, endMs: i * 100 + 90)
        }
        words.append(TranscribedWord(text: "，", startMs: 1800, endMs: 1900))
        words += (0..<6).map { i in
            TranscribedWord(text: "后", startMs: 2000 + i * 100, endMs: 2050 + i * 100)
        }
        let segs = TranscriptLines.mergeWords(words, spaced: false)
        for s in segs {
            XCTAssertFalse(TranscriptLines.isPunctOnly(String(s.text.prefix(1))), s.text)
        }
        XCTAssertTrue(segs[0].text.hasSuffix("，"))
    }

    /// 27 字的 cue 早先整条进稿(`split` 的提前返回放宽到 1.5 倍行宽),上屏折成两行、
    /// 第二行只剩几个字 —— 与"一行铺满 + 下一行一个字"同一个形状(H280)。
    func testOverlongCueIsSplit() {
        let text = "这是一句刚好超过一行的稿件内容用来验证切分"
        XCTAssertGreaterThan(text.count, TranscriptLines.cjkChars)
        let segs = TranscriptLines.split(text, startMs: 0, endMs: 1000)
        XCTAssertGreaterThanOrEqual(segs.count, 2)
        for s in segs {
            XCTAssertLessThanOrEqual(s.text.count, TranscriptLines.cjkChars, s.text)
        }
        XCTAssertEqual(segs.map(\.text).joined(), text)
    }

    /// 中英混排里汉字不到一半,但按字宽折算已超过一行 —— 按西文的 38 切就会折行。
    func testMixedTextUsesCjkWidth() {
        let mixed = "元今年 open a i 一度在部分收入指标上落后于 anropic 彭"
        let cjk = mixed.unicodeScalars.filter {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }.count
        XCTAssertLessThan(cjk * 2, mixed.count)
        XCTAssertEqual(TranscriptLines.targetChars(mixed), TranscriptLines.cjkChars)
    }

    /// 首条是「4分之1。」这种混排小条目时,行宽不能只看它 —— 单看首条会判成西文 38 字,
    /// 同一行后面再接汉字就撑到 25 字,上屏折两行(2026-11-13 Android 装机实测)。
    func testMixedDigitHeadStillUsesCjkWidth() {
        let words = ["4分之1。", "另外，", "面对签约运动员姆巴佩引发的", "争议，", "昂跑联席CEO表示，"]
            .enumerated().map { i, t in
                TranscribedWord(text: t, startMs: i * 100, endMs: i * 100 + 90)
            }
        for s in TranscriptLines.mergeWords(words, spaced: false) {
            XCTAssertLessThanOrEqual(s.text.count,
                                     TranscriptLines.cjkChars + TranscriptLines.glueOverhang, s.text)
        }
    }

    /// 行首 18 个字符被英文占满时,`headWindow` 会把整行判成西文 38 字,于是一条 38 字的混排行
    /// 上屏折两行(2026-11-13 鸿蒙装机实测)。`fitOneLine` 按整行重判后必须切开。
    func testLatinHeavyHeadStillSplitsToCjkWidth() {
        let words = ["亿美元今年", " open a i ", "一度在部分收入指标上落后于", " anropic 彭"]
            .enumerated().map { i, t in
                TranscribedWord(text: t, startMs: i * 100, endMs: i * 100 + 90)
            }
        for s in TranscriptLines.mergeWords(words, spaced: false) {
            XCTAssertLessThanOrEqual(s.text.count,
                                     TranscriptLines.cjkChars + TranscriptLines.glueOverhang, s.text)
        }
    }

    /// 并句的上限:18 字的行再并 11 字就超一行,宁可让那 11 字自己成行。
    /// (旧判据"碎片不足 12 字就并"会并出 29 字,换行后第二行只剩孤字。)
    func testGlueStopsAtOneLine() {
        let segs = TranscriptLines.glueOrphans([
            TranscribedSegment(text: String(repeating: "甲", count: 18), startMs: 0, endMs: 1000),
            TranscribedSegment(text: String(repeating: "乙", count: 11), startMs: 1100, endMs: 2000)
        ])
        XCTAssertEqual(segs.count, 2)
    }

    func testAsciiHead() {
        XCTAssertTrue(TranscriptLines.isAsciiHead("Hello"))
        XCTAssertFalse(TranscriptLines.isAsciiHead("中文"))
        XCTAssertFalse(TranscriptLines.isAsciiHead(""))
    }
}
