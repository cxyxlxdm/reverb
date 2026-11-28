import XCTest
@testable import Reverb

/// 备用源 altFeeds 的编解码兼容(H311)。旧缓存/备份里没有这个键,必须解成空数组;
/// 有这个键的必须能原样往返 —— 换源逻辑依赖它按 seed 里的顺序逐个尝试。
final class FeedAlternatesTests: XCTestCase {
    func testLegacyPodcastWithoutAltFeedsDecodesToEmpty() throws {
        let json = """
        {"id":"1493503146","title":"忽左忽右","author":"JustPod","artworkUrl":"",
         "feedUrl":"https://feed.xyzfm.space/cv4bkgpuglwp","description":"","genre":"社会与文化",
         "isPaid":false,"fundingUrl":"","fundingLabel":""}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(p.altFeeds, [])
    }

    func testAltFeedsRoundTrip() throws {
        let p = Podcast(
            id: "1493503146", title: "忽左忽右", author: "JustPod", artworkUrl: "",
            feedUrl: "https://feed.xyzfm.space/cv4bkgpuglwp",
            altFeeds: ["https://www.ximalaya.com/album/12817863.xml",
                       "https://feed.xyzfm.space/cv4bkgpuglwp"]
        )
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Podcast.self, from: data)
        XCTAssertEqual(back.altFeeds.count, 2)
        XCTAssertEqual(back.altFeeds.first, "https://www.ximalaya.com/album/12817863.xml")
        XCTAssertEqual(back.altFeeds.last, p.feedUrl, "小宇宙必须垫底")
    }

    func testSeedResourceHasAlternatesForHuzuoYouyou() throws {
        // 随包种子清单里,"忽左忽右"必须带 altFeeds 且第一个候选不是小宇宙。
        // 这条把 H311 的"可达优先、小宇宙垫底"钉在产物上,防止有人重跑 gen-seed 时冲掉。
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReverbTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("Resources/seed_podcasts.json")
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let lists = root["lists"] as! [String: [[String: Any]]]
        let hits = lists.values.flatMap { $0 }.filter { $0["title"] as? String == "忽左忽右" }
        XCTAssertEqual(hits.count, 1)
        let alts = hits.first?["altFeeds"] as? [String] ?? []
        XCTAssertFalse(alts.isEmpty, "忽左忽右必须有备用源")
        XCTAssertFalse(alts.first?.contains("feed.xyzfm.space") ?? true,
                       "第一个候选不能是小宇宙")
    }
}
