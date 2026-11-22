import XCTest
@testable import Reverb

/// 「检查更新」里唯一一段纯逻辑:GitHub release 列表 → 该下哪一条。
///
/// 为什么值得单测:这条链路上网络失败在日志里至少有三种写法(transport/http/parse),
/// 而「拿到了 JSON 但挑错条目或挑不出来」只会在用户侧表现成同一句「检查更新失败」——
/// 拿真实接口形状的夹具把它钉住,比下次再去 curl 一遍快。
final class SelfUpdateParseTests: XCTestCase {

    /// 字段形状取自 2026-11-19 实测的 `releases?per_page=20` 响应,只留选择逻辑用得上的键:
    /// 最新的那条是 prerelease(必须跳过)、次新的只有 apk(必须跳过)、再往下才是带 dmg 的 1.0.8。
    private func fixture() -> Data {
        let json = """
        [
          {"tag_name": "1.0.10-beta", "draft": false, "prerelease": true,
           "assets": [{"name": "Reverb.dmg", "size": 111, "id": 1,
                       "digest": "sha256:aa", "browser_download_url": "https://example.com/a.dmg"}]},
          {"tag_name": "1.0.9", "draft": false, "prerelease": false,
           "assets": [{"name": "reverb.apk", "size": 222, "id": 2,
                       "digest": "sha256:bb", "browser_download_url": "https://example.com/a.apk"}]},
          {"tag_name": "1.0.8", "draft": false, "prerelease": false,
           "assets": [{"name": "reverb.apk", "size": 333, "id": 3},
                      {"name": "Reverb.dmg", "size": 444, "id": 4,
                       "digest": "sha256:cc", "browser_download_url": "https://example.com/r.dmg"}]},
          {"tag_name": "1.0.7", "draft": true, "prerelease": false,
           "assets": [{"name": "Reverb.dmg", "size": 555, "id": 5,
                       "digest": "sha256:dd", "browser_download_url": "https://example.com/o.dmg"}]}
        ]
        """
        return Data(json.utf8)
    }

    func testPicksNewestNonPrereleaseWithDmg() {
        let rel = SelfUpdate.parseReleases(fixture())
        XCTAssertEqual(rel?.tag, "1.0.8")
        XCTAssertEqual(rel?.size, 444)
        XCTAssertEqual(rel?.sha256, "cc")
        // API 端点排第一,直链是退路 —— 顺序是契约,不是实现细节。
        XCTAssertEqual(rel?.urls.first, "https://api.github.com/repos/cxyxlxdm/revert-cast/releases/assets/4")
        XCTAssertEqual(rel?.urls.count, 2)
    }

    func testNoDmgMeansNil() {
        let json = """
        [{"tag_name": "1.0.9", "draft": false, "prerelease": false,
          "assets": [{"name": "reverb.apk", "size": 1, "id": 9}]}]
        """
        XCTAssertNil(SelfUpdate.parseReleases(Data(json.utf8)))
    }

    func testGarbageIsNilNotCrash() {
        XCTAssertNil(SelfUpdate.parseReleases(Data("<html>403</html>".utf8)))
    }

    func testVersionCompareIsNumericPerSegment() {
        // 字符串比大小会把 1.0.10 判成比 1.0.9 旧 —— 这正是这个方法存在的理由。
        XCTAssertTrue(SelfUpdate.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(SelfUpdate.isNewer("v1.0.9", than: "1.0.8"))
        XCTAssertFalse(SelfUpdate.isNewer("1.0.8", than: "1.0.8"))
        XCTAssertFalse(SelfUpdate.isNewer("1.0.9", than: "1.0.10"))
    }
}
