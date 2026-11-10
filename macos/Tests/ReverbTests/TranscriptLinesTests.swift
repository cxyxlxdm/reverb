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

    func testLineWidthsAreTheSharedNumbers() {
        XCTAssertEqual(TranscriptLines.cjkChars, 24)
        XCTAssertEqual(TranscriptLines.westChars, 42)
        XCTAssertEqual(TranscriptLines.targetChars("这是一段中文"), 24)
        XCTAssertEqual(TranscriptLines.targetChars("this is english"), 42)
    }

    func testAsciiHead() {
        XCTAssertTrue(TranscriptLines.isAsciiHead("Hello"))
        XCTAssertFalse(TranscriptLines.isAsciiHead("中文"))
        XCTAssertFalse(TranscriptLines.isAsciiHead(""))
    }
}
