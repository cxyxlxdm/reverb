import XCTest
@testable import Reverb

/// `looksLikeStream` 只是搜索框同步路径上的廉价预判;真正的判据在 `resolve` 的响应头里。
/// 这里钉住"什么算候选":http/https 放行,其余一律不放。
final class LiveStreamTests: XCTestCase {
    func testHttpAndHttpsAreCandidates() {
        XCTAssertTrue(LiveStream.looksLikeStream("https://stream.example.com/live.mp3"))
        XCTAssertTrue(LiveStream.looksLikeStream("http://192.0.2.10:8000/stream"))
        XCTAssertTrue(LiveStream.looksLikeStream("https://radio.example.com/hls/station.m3u8"))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertTrue(LiveStream.looksLikeStream("  https://stream.example.com/a  "))
    }

    func testOtherSchemesAreRejected() {
        XCTAssertFalse(LiveStream.looksLikeStream("ftp://example.com/a.mp3"))
        XCTAssertFalse(LiveStream.looksLikeStream("file:///tmp/a.mp3"))
    }

    func testBareHostOrPlainTextIsRejected() {
        XCTAssertFalse(LiveStream.looksLikeStream("example.com/live"))
        XCTAssertFalse(LiveStream.looksLikeStream("随便搜点什么"))
        XCTAssertFalse(LiveStream.looksLikeStream(""))
    }
}
