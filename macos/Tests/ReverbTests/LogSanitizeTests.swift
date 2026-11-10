import XCTest
@testable import Reverb

/// 日志里不许出现完整 URL(隐私政策第二节的承诺),只留 scheme://host。
/// 这条在 `Log.write` 统一做,所以这里直接测那个函数。
final class LogSanitizeTests: XCTestCase {
    func testUrlIsCollapsedToEndpoint() {
        let line = "GET https://user:pass@example.com:8443/a?x=1 failed"
        XCTAssertEqual(Log.sanitize(line), "GET https://example.com failed")
    }

    func testMultipleUrlsAreAllCollapsed() {
        let line = "a https://one.example.com/x b http://two.example.org/y"
        XCTAssertEqual(Log.sanitize(line), "a https://one.example.com b http://two.example.org")
    }

    func testTextWithoutUrlIsUnchanged() {
        XCTAssertEqual(Log.sanitize("count=7 dropped=10"), "count=7 dropped=10")
    }

    func testIPv6LiteralKeepsBrackets() {
        XCTAssertEqual(Log.endpoint("http://[2001:db8::1]:8080/x"), "http://[2001:db8::1]")
    }
}
