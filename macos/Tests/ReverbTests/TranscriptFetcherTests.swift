import XCTest
@testable import Reverb

/// 发布方官方稿的三种格式解析(Podcast Index JSON / WebVTT / SRT)。
///
/// 这条路从 1.0.6(macOS M10,88b4ec7)起就在跑,但此前**一条单测都没有** ——
/// 运行侧只拿一份 JSON 夹具验过一次(ROADMAP 三-A2 ⑧)。解析器是纯函数,
/// 手机端的 Android 那套也只靠真机跑过,所以这里把三格式与「type 标错时靠内容嗅探」
/// 这两类判据钉住,避免以后改断句阈值时静默改掉三端的行数(H150)。
///
/// 不断言具体行数与切分位置:那是 `TranscriptLinesTests` 的域,这里只认
/// 「格式认不认得出、时间换算对不对、正文有没有被洗干净」。
final class TranscriptFetcherTests: XCTestCase {

    // MARK: - WebVTT

    func testVTTWithHeaderNoteAndCueIdentifier() {
        let vtt = """
        WEBVTT

        NOTE 这不是字幕块

        cue-1
        00:00:01.000 --> 00:00:03.000 align:start position:0%
        <v Alice>Hello</v> &nbsp;world

        00:04.500 --> 00:00:06.000
        Second cue
        """
        let segs = TranscriptFetcher.parse(vtt, declaredType: "text/vtt")
        XCTAssertEqual(segs?.count, 2)
        XCTAssertEqual(segs?.first?.startMs, 1000)
        // `<v Alice>`、`&nbsp;` 都要洗掉;`&nbsp;` 原样换成一个空格,
        // 与原文那个空格连起来会留双空格 —— **三端都这样**,别单端折叠(会改行宽与跨端行数)
        let first = segs?.first?.text ?? ""
        XCTAssertEqual(first.split(whereSeparator: \.isWhitespace).joined(separator: " "), "Hello world")
        XCTAssertFalse(first.contains("<v"))
        XCTAssertFalse(first.contains("&nbsp;"))
        XCTAssertEqual(segs?.last?.startMs, 4500)
        XCTAssertEqual(segs?.last?.text, "Second cue")
        XCTAssertFalse(segs?.contains { $0.text.contains("NOTE") } ?? true)
    }

    func testVTTWithBOMAndMissingHours() {
        // BOM 不剥掉的话 "WEBVTT" 前缀判断会失手;VTT 允许省略小时段
        let vtt = "\u{FEFF}WEBVTT\n\n01:02.500 --> 01:04.000\nHi"
        let segs = TranscriptFetcher.parse(vtt, declaredType: "text/plain")
        XCTAssertEqual(segs?.count, 1)
        XCTAssertEqual(segs?.first?.startMs, 62_500)
        XCTAssertEqual(segs?.first?.endMs, 64_000)
    }

    func testVTTStylingBlocksAreNotCues() {
        let vtt = """
        WEBVTT

        STYLE
        ::cue { color: red }

        REGION
        id:fred width:40%

        00:00:01.000 --> 00:00:02.000
        Real line
        """
        let segs = TranscriptFetcher.parse(vtt, declaredType: "text/vtt")
        XCTAssertEqual(segs?.map(\.text), ["Real line"])
    }

    // MARK: - SRT

    func testSRTCommaMillisAndIndexLines() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,500
        Hello there.

        2
        00:00:03,200 --> 00:00:05,000
        General Kenobi.
        """
        let segs = TranscriptFetcher.parse(srt, declaredType: "application/x-subrip")
        XCTAssertEqual(segs?.count, 2)
        XCTAssertEqual(segs?.first?.startMs, 0)
        XCTAssertEqual(segs?.first?.endMs, 2500)
        XCTAssertEqual(segs?.last?.startMs, 3200)
        // 序号行与时间行不能混进正文
        XCTAssertEqual(segs?.map(\.text), ["Hello there.", "General Kenobi."])
    }

    func testSRTWithoutAnyTimingIsRejected() {
        let plain = "这是一段没有时间轴的纯文本稿。\n第二行。"
        XCTAssertNil(TranscriptFetcher.parse(plain, declaredType: "text/plain"))
        XCTAssertNil(TranscriptFetcher.parse(plain, declaredType: "application/json"))
    }

    // MARK: - 时间换算

    func testParseClock() {
        XCTAssertEqual(TranscriptFetcher.parseClock("00:00:01.000"), 1000)
        XCTAssertEqual(TranscriptFetcher.parseClock("00:01:02,500"), 62_500)
        XCTAssertEqual(TranscriptFetcher.parseClock(" 01:02.500 "), 62_500)
        // 单独一个数字不是时间(正文里混进的 "5" 曾被当成 5 秒,见 H150)
        XCTAssertNil(TranscriptFetcher.parseClock("5"))
        XCTAssertNil(TranscriptFetcher.parseClock("abc"))
        XCTAssertNil(TranscriptFetcher.parseClock(""))
    }

    // MARK: - Podcast Index JSON

    func testJSONStandardShape() {
        let json = """
        {"version":"1.0.0","segments":[
          {"startTime":0,"endTime":1.5,"body":"Hello"},
          {"startTime":1.5,"endTime":2.8,"text":"world"}
        ]}
        """
        let segs = TranscriptFetcher.parse(json, declaredType: "application/json")
        XCTAssertEqual(segs?.count, 1)
        XCTAssertEqual(segs?.first?.text, "Hello world")
        XCTAssertEqual(segs?.first?.startMs, 0)
        XCTAssertEqual(segs?.first?.endMs, 2800)
        // 合了多条才留词级时间,否则整句高亮就够
        XCTAssertEqual(segs?.first?.words?.count, 2)
    }

    func testJSONRootArrayWithMsKeys() {
        let json = """
        [{"body":"Hi","startMs":1000,"endMs":2000}]
        """
        let segs = TranscriptFetcher.parse(json, declaredType: "application/octet-stream")
        XCTAssertEqual(segs?.count, 1)
        XCTAssertEqual(segs?.first?.text, "Hi")
        XCTAssertEqual(segs?.first?.startMs, 1000)
        XCTAssertNil(segs?.first?.words)   // 单条不需要词级时间
    }

    func testJSONStringNumbersAndRounding() {
        let json = """
        {"segments":[{"body":"A","startTime":"2.5","endTime":"3.0005"}]}
        """
        let segs = TranscriptFetcher.parse(json, declaredType: "application/json")
        XCTAssertEqual(segs?.first?.startMs, 2500)
        XCTAssertEqual(segs?.first?.endMs, 3001)   // 四舍五入,不截断
    }

    func testJSONSkipsNegativeAndEmptyEntries() {
        XCTAssertNil(TranscriptFetcher.parse("""
        {"segments":[{"body":"x","startTime":-1,"endTime":2}]}
        """, declaredType: "application/json"))
        XCTAssertNil(TranscriptFetcher.parse("""
        {"segments":[{"body":"  ","startTime":0,"endTime":2}]}
        """, declaredType: "application/json"))
    }

    func testMalformedJSONDeclaredAsJSONIsRejected() {
        XCTAssertNil(TranscriptFetcher.parse("{\"segments\": [", declaredType: "application/json"))
        XCTAssertNil(TranscriptFetcher.parse("<html><body>404</body></html>", declaredType: "application/json"))
    }

    // MARK: - 嗅探顺序

    func testContentSniffingBeatsDeclaredType() {
        // 真实 feed 里 type 标错很常见:VTT 被标成 text/plain、JSON 被标成 octet-stream
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi"
        XCTAssertNotNil(TranscriptFetcher.parse(vtt, declaredType: "text/plain"))
        XCTAssertNotNil(TranscriptFetcher.parse(vtt, declaredType: "application/json"))

        let json = "{\"segments\":[{\"body\":\"Hi\",\"startTime\":0,\"endTime\":1}]}"
        XCTAssertNotNil(TranscriptFetcher.parse(json, declaredType: "text/plain"))
    }
}
