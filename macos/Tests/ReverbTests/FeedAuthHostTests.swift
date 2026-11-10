import XCTest
@testable import Reverb

/// 凭据只发给源自己(含父子域)的判据。放错一个字符,口令就会跟着音频 CDN 的请求发出去。
final class FeedAuthHostTests: XCTestCase {
    func testHostIsLowercasedAndDropsPort() {
        XCTAssertEqual(FeedAuthStore.hostOf("https://Example.COM/feed.xml"), "example.com")
        XCTAssertEqual(FeedAuthStore.hostOf("  https://example.com:8443/x  "), "example.com")
    }

    func testHostOfRejectsNonUrl() {
        XCTAssertNil(FeedAuthStore.hostOf("不是网址"))
    }

    func testParentAndChildDomainsMatch() {
        XCTAssertTrue(FeedAuthStore.hostMatches("a.example.com", "example.com"))
        XCTAssertTrue(FeedAuthStore.hostMatches("example.com", "a.example.com"))
        XCTAssertTrue(FeedAuthStore.hostMatches("example.com", "example.com"))
    }

    func testLookalikesDoNotMatch() {
        XCTAssertFalse(FeedAuthStore.hostMatches("evil-example.com", "example.com"))
        XCTAssertFalse(FeedAuthStore.hostMatches("example.com.evil.net", "example.com"))
        XCTAssertFalse(FeedAuthStore.hostMatches("other.com", "example.com"))
    }

    func testEmptyValuesDoNotMatch() {
        XCTAssertFalse(FeedAuthStore.hostMatches(nil, "example.com"))
        XCTAssertFalse(FeedAuthStore.hostMatches("example.com", nil))
        XCTAssertFalse(FeedAuthStore.hostMatches("", "example.com"))
    }
}
