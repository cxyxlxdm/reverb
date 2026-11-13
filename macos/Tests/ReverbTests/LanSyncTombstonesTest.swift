import XCTest
@testable import Reverb

/// 墓碑账本的**纯函数**判据(归一化与订阅键)。
///
/// `record/merge` 会直接写进真实的 `~/Library/Application Support/Reverb/sync_tombstones.json`,
/// 而这一层没有可注入的目录 —— 为了一条单测去写用户的账本(或留下一份假删除)不划算。
/// 落盘与合并语义由 Android 的 `SyncTombstonesTest` 覆盖:两端的 key / 保留期 / 覆盖顺序
/// 是同一份契约,归一化这一条最容易各自跑偏,所以两边都测。
@MainActor
final class LanSyncTombstonesTest: XCTestCase {

    func testNormalizeFeedIgnoresSchemeHostCaseAndTrailingSlash() {
        XCTAssertEqual(LanSyncTombstones.normalizeFeed("HTTPS://A.com/f/"), "https://a.com/f")
        // 路径大小写敏感:不能跟着一起小写。
        XCTAssertEqual(LanSyncTombstones.normalizeFeed("https://A.com/F"), "https://a.com/F")
        XCTAssertEqual(LanSyncTombstones.normalizeFeed("https://A.com"), "https://a.com")
        XCTAssertEqual(LanSyncTombstones.normalizeFeed("https://A.com/p?X=1"), "https://a.com/p?X=1")
        XCTAssertEqual(LanSyncTombstones.normalizeFeed(" Feed/ "), "Feed")
        XCTAssertNil(LanSyncTombstones.normalizeFeed("   "))
    }

    func testSubscriptionKeyFallsBackToId() {
        XCTAssertEqual(
            LanSyncTombstones.subscriptionKey(feedUrl: "HTTPS://A.com/f/", id: "whatever"),
            "https://a.com/f"
        )
        XCTAssertEqual(LanSyncTombstones.subscriptionKey(feedUrl: "  ", id: "collection-42"), "collection-42")
    }
}
