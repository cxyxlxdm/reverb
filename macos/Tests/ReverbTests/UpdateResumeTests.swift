import XCTest
@testable import Reverb

/// 断点续传的纯决策:续不续、Range 的起点/总量对不对。
/// 这部分错一次就是把两份不同的字节拼成一份安装包,所以不靠真机碰运气。
final class UpdateResumeTests: XCTestCase {

    func testResumeNeedsValidatorAndMatchingTagAndSize() {
        let ok = UpdateResumeMeta(tag: "1.0.9", etag: "\"abc\"", lastModified: nil, total: 100)
        XCTAssertTrue(UpdateResume.canResume(existing: 40, meta: ok, tag: "1.0.9", expectedTotal: 100))
        XCTAssertTrue(UpdateResume.canResume(existing: 40, meta: ok, tag: "1.0.9", expectedTotal: 0))
        XCTAssertFalse(UpdateResume.canResume(existing: 0, meta: ok, tag: "1.0.9", expectedTotal: 100))
        XCTAssertFalse(UpdateResume.canResume(existing: 40, meta: nil, tag: "1.0.9", expectedTotal: 100))
        XCTAssertFalse(UpdateResume.canResume(existing: 40, meta: ok, tag: "1.0.10", expectedTotal: 100))
        XCTAssertFalse(UpdateResume.canResume(existing: 40, meta: ok, tag: "1.0.9", expectedTotal: 101))
    }

    func testResumeWithoutETagCanUseLastModified() {
        let lastModified = UpdateResumeMeta(tag: "1.0.9", etag: nil,
                                            lastModified: "Sun, 22 Nov 2026 11:06:33 GMT", total: 100)
        XCTAssertTrue(UpdateResume.canResume(existing: 40, meta: lastModified,
                                             tag: "1.0.9", expectedTotal: 100))
        XCTAssertEqual(UpdateResume.ifRange(lastModified), "Sun, 22 Nov 2026 11:06:33 GMT")

        let noValidator = UpdateResumeMeta(tag: "1.0.9", etag: nil, lastModified: nil, total: 100)
        XCTAssertFalse(UpdateResume.canResume(existing: 40, meta: noValidator,
                                              tag: "1.0.9", expectedTotal: 100))
    }

    func testContentRangeParsing() {
        let range = UpdateResume.parseContentRange("bytes 1000-2023/6622867")
        XCTAssertEqual(range?.start, 1000)
        XCTAssertEqual(range?.total, 6622867)
        XCTAssertEqual(UpdateResume.parseContentRange("bytes 0-0/*")?.total, 0)
        XCTAssertNil(UpdateResume.parseContentRange("items 0-0/10"))
        XCTAssertNil(UpdateResume.parseContentRange(nil))
    }
}
