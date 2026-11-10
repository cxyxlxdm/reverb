import XCTest
@testable import Reverb

/// 私有订阅源的第一道边界:userinfo 必须从落库的 URL 里剥掉,凭据只单独保存。
/// 另两个断言盯住 401 重试的门槛 —— 用 `needsUtf8` 当门槛会漏掉 `é` 这类字符(H253)。
final class CredentialTests: XCTestCase {
    func testSplitUrlStripsUserInfo() {
        let (url, credential) = FeedCredential.splitUrl("https://user:pa%3Ass@example.com/feed.xml")
        XCTAssertEqual(url, "https://example.com/feed.xml")
        XCTAssertEqual(credential?.username, "user")
        XCTAssertEqual(credential?.password, "pa:ss")
    }

    func testSplitUrlWithoutUserInfoReturnsTrimmed() {
        let (url, credential) = FeedCredential.splitUrl("  https://example.com/feed.xml  ")
        XCTAssertEqual(url, "https://example.com/feed.xml")
        XCTAssertNil(credential)
    }

    func testHeaderIsBasicBase64() {
        let credential = FeedCredential(username: "user", password: "pass")
        XCTAssertEqual(credential.header(utf8: false), "Basic dXNlcjpwYXNz")
    }

    func testEncodingDiffersOnlyWhenBytesDiffer() {
        XCTAssertFalse(FeedCredential(username: "user", password: "pass").encodingDiffers)
        // é 在 Latin-1 与 UTF-8 下字节不同,401 之后值得重试
        XCTAssertTrue(FeedCredential(username: "user", password: "café").encodingDiffers)
        // 中文在 Swift 里 Latin-1 编码失败,两发都落成 UTF-8,重试没有意义
        XCTAssertFalse(FeedCredential(username: "用户", password: "密码").encodingDiffers)
    }

    func testNeedsUtf8IsAboutRepresentability() {
        XCTAssertFalse(FeedCredential(username: "user", password: "café").needsUtf8)
        XCTAssertTrue(FeedCredential(username: "用户", password: "密码").needsUtf8)
    }
}
