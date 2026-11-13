import XCTest
@testable import Reverb

/// 章表解析的判据。三端各写一份实现,但规则必须逐条对齐 —— 同一份章表在
/// 手机与桌面上显示的名字、时间、顺序对不上,用户只会以为是数据坏了。
///
/// 这些用例覆盖:两种合法形状(对象 / 裸数组)、两种起点写法(`startTime` 秒 /
/// `start` 时间码)、负数夹到 0、同起点去重、"取不到"与"空表"必须分开。
final class ChaptersFetcherTests: XCTestCase {

    // MARK: - 形状

    func testWrapperObjectWithStartTimeSortsAndDedupes() throws {
        let json = """
        {"version":"1.2.0","chapters":[
          {"startTime":65,"title":"第三段：用 start 时间码的写法","img":"https://cdn.example.com/3.jpg"},
          {"startTime":0,"title":"开场与本期介绍"},
          {"startTime":25.5,"title":"第二段"},
          {"startTime":-3,"title":"负数起点"},
          {"startTime":0,"title":"同起点的重复条目"}
        ]}
        """
        let chapters = try XCTUnwrap(ChaptersFetcher.parse(json))
        XCTAssertEqual(chapters.map(\.startMs), [0, 25_500, 65_000],
                       "负数夹到 0、同起点保留原始顺序的第一条")
        XCTAssertEqual(chapters.map(\.title), ["开场与本期介绍", "第二段", "第三段：用 start 时间码的写法"])
        XCTAssertEqual(chapters[2].imageUrl, "https://cdn.example.com/3.jpg")
    }

    func testBareArrayWithTimecodeAndImageAlias() throws {
        // 裸数组是规范外但很常见的写法;`image` 是 `img` 的别名
        let json = """
        [{"start":"01:05","title":"B","image":"https://cdn.example.com/b.jpg","url":"https://example.com/b"},
         {"start":"0:00","title":"A"}]
        """
        let chapters = try XCTUnwrap(ChaptersFetcher.parse(json))
        XCTAssertEqual(chapters.map(\.startMs), [0, 65_000])
        XCTAssertEqual(chapters[1].imageUrl, "https://cdn.example.com/b.jpg")
        XCTAssertEqual(chapters[1].url, "https://example.com/b")
        XCTAssertEqual(chapters[0].imageUrl, "")
    }

    func testNumericStringStartTimeAccepted() throws {
        // 个别源把秒数写成字符串
        let json = #"{"chapters":[{"startTime":"12.5","title":"前半"}]}"#
        let chapters = try XCTUnwrap(ChaptersFetcher.parse(json))
        XCTAssertEqual(chapters.first?.startMs, 12_500)
    }

    func testDropsUntitledAndStartlessItems() throws {
        let json = """
        {"chapters":[
          {"startTime":0,"title":"   "},
          {"title":"没有起点"},
          {"startTime":30,"title":"留下","url":"https://example.com/x"}
        ]}
        """
        let chapters = try XCTUnwrap(ChaptersFetcher.parse(json))
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "留下")
        XCTAssertEqual(chapters[0].url, "https://example.com/x")
    }

    // MARK: - 失败与空必须分开

    func testNoChaptersKeyIsValidEmptyTable() throws {
        // 形状合法、只是没有章节 —— 界面说「这一集没有章节」,不摆重试
        let chapters = try XCTUnwrap(ChaptersFetcher.parse(#"{"version":"1.2.0"}"#))
        XCTAssertTrue(chapters.isEmpty)
    }

    func testNonChapterPayloadIsFailure() {
        // 解析不了 = nil,界面给重试 —— 与上面那条空表是两回事
        XCTAssertNil(ChaptersFetcher.parse("{\"chapters\": 42}"))
        XCTAssertNil(ChaptersFetcher.parse("not json at all"))
        XCTAssertNil(ChaptersFetcher.parse("\"just a string\""))
    }

    func testBomIsStripped() throws {
        let chapters = try XCTUnwrap(ChaptersFetcher.parse("\u{FEFF}{\"chapters\":[]}"))
        XCTAssertTrue(chapters.isEmpty)
    }
}
