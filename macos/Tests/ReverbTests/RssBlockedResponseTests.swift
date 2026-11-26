import XCTest
@testable import Reverb

/// 平台拦截识别的判据(H307)。小宇宙把 feed 302 到 text/html 拦截页,
/// URLSession 跟随跳转后看到的是 200 + HTML —— 必须在交给 XMLParser 之前认出来。
final class RssBlockedResponseTests: XCTestCase {

    func testHtmlContentTypeIsBlocked() {
        let body = Data("<html><body>暂时无法访问此页面</body></html>".utf8)
        XCTAssertTrue(RssParser.looksBlocked(code: 200, mime: "text/html; charset=utf-8", body: body))
    }

    func testHtmlBodyWithoutMimeIsBlocked() {
        let body = Data("<!DOCTYPE html>\n<html lang=\"zh\"><head></head></html>".utf8)
        XCTAssertTrue(RssParser.looksBlocked(code: 302, mime: "", body: body))
    }

    func testRssAndAtomAreNotBlocked() {
        let rss = Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel/></rss>".utf8)
        XCTAssertFalse(RssParser.looksBlocked(code: 200, mime: "application/rss+xml", body: rss))
        let atom = Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>".utf8)
        XCTAssertFalse(RssParser.looksBlocked(code: 200, mime: "application/atom+xml", body: atom))
    }

    func testUnusualMimeWithXmlBodyIsNotBlocked() {
        // 有些源用 application/octet-stream 发 RSS,不能因为 MIME 不常见就判死。
        let body = Data("<?xml version=\"1.0\"?><rss><channel><title>x</title></channel></rss>".utf8)
        XCTAssertFalse(RssParser.looksBlocked(code: 200, mime: "application/octet-stream", body: body))
    }
}
