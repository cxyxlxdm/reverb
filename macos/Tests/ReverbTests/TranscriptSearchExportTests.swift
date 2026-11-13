import XCTest
@testable import Reverb

/// 搜索与导出是纯逻辑,判据与 Android `TranscriptSearchTest` / `TranscriptExportTest` 同一套:
/// 两端对同一段稿必须给出相同的命中句、相同的区间、逐字节相同的导出文本。
final class TranscriptSearchExportTests: XCTestCase {

    private func seg(_ text: String, _ start: Int, _ end: Int) -> TranscribedSegment {
        TranscribedSegment(text: text, startMs: start, endMs: end)
    }

    // MARK: - 搜索

    func testFindsCaseInsensitiveAcrossLines() {
        let segments = [
            seg("Hello world", 0, 5000),
            seg("nothing here", 5000, 9000),
            seg("另一个 PODCAST 与 podcast", 9000, 12000)
        ]
        let result = TranscriptSearch.find(segments: segments, query: "podcast")
        XCTAssertEqual(result.hits.map(\.index), [2])
        XCTAssertEqual(result.rangesByIndex[2], [4..<11, 14..<21])
    }

    func testBlankQueryMatchesNothing() {
        let segments = [seg("hello", 0, 1000)]
        XCTAssertTrue(TranscriptSearch.find(segments: segments, query: "").isEmpty)
    }

    func testOverlappingOccurrencesAreNotDoubleCounted() {
        // "aa" in "aaaa":从上一处末尾继续找 ⇒ 两处,而不是三处(与 Android 同口径)
        XCTAssertEqual(TranscriptSearch.rangesIn(text: "aaaa", query: "aa"), [0..<2, 2..<4])
    }

    func testEmptyTextHasNoRanges() {
        XCTAssertEqual(TranscriptSearch.rangesIn(text: "", query: "a"), [])
    }

    // MARK: - 导出

    private var episode: Episode {
        Episode(id: "ep1", title: "Ep", description: "", audioUrl: "https://example.com/a.mp3",
                artworkUrl: "", podcastTitle: "Ch")
    }

    func testPlainText() {
        let out = TranscriptExport.build(
            episode: episode,
            segments: [seg("第一句", 0, 3000), seg("第二句", 5000, 7000)],
            format: .text)
        XCTAssertEqual(out, "Ep\nCh\n\n[0:00] 第一句\n[0:05] 第二句\n")
    }

    func testMarkdown() {
        let out = TranscriptExport.build(
            episode: episode,
            segments: [seg("Hello", 0, 2000)],
            format: .markdown)
        XCTAssertEqual(out, "# Ep\n\n_Ch_\n\n- [0:00] Hello\n")
    }

    func testStampSwitchesToHoursOnlyWhenWholeEpisodeIsAnHour() {
        XCTAssertEqual(TranscriptExport.stamp(ms: 65_000, withHours: false), "1:05")
        XCTAssertEqual(TranscriptExport.stamp(ms: 3_725_000, withHours: true), "1:02:05")
        XCTAssertEqual(TranscriptExport.stamp(ms: -5, withHours: false), "0:00")
    }

    func testWholeEpisodeOverAnHourUsesHoursEverywhere() {
        let out = TranscriptExport.build(
            episode: episode,
            segments: [seg("a", 0, 1000), seg("b", 3_700_000, 3_705_000)],
            format: .text)
        XCTAssertTrue(out.contains("[0:00:00] a"))
        XCTAssertTrue(out.contains("[1:01:40] b"))
    }

    func testNewlinesCollapseAndTitleFallsBack() {
        let blank = Episode(id: "x", title: "  \n ", description: "", audioUrl: "", artworkUrl: "", podcastTitle: "")
        XCTAssertEqual(TranscriptExport.build(episode: blank, segments: [], format: .text), "Transcript\n\n")
        let multiline = Episode(id: "y", title: "上\n下", description: "", audioUrl: "", artworkUrl: "", podcastTitle: "Ch\n")
        XCTAssertEqual(TranscriptExport.fileName(episode: multiline, format: .text), "上 下.txt")
    }

    func testFileNameStripsPathSeparators() {
        let e = Episode(id: "z", title: "a/b\\c:d*e?f\"g<h>i|j", description: "",
                        audioUrl: "", artworkUrl: "", podcastTitle: "")
        XCTAssertEqual(TranscriptExport.fileName(episode: e, format: .text), "a b c d e f g h i j.txt")
    }

    func testFileNameFallsBackWhenBlank() {
        let e = Episode(id: "z", title: "", description: "", audioUrl: "", artworkUrl: "", podcastTitle: "")
        XCTAssertEqual(TranscriptExport.fileName(episode: e, format: .markdown), "transcript.md")
    }
}
