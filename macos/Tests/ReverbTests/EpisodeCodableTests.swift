import XCTest
@testable import Reverb

/// Episode 会被写进历史 / 下载 / 批注 / 播放态 / 备份。旧文件缺 `isLive` 与逐字稿键时,
/// 必须逐键回落 —— 一个缺键让整份历史解码失败,这个学费已经付过一次(H86)。
final class EpisodeCodableTests: XCTestCase {
    func testOldJsonWithoutNewKeysDecodesToDefaults() throws {
        let json = """
        {"id":"e1","title":"旧条目","description":"","audioUrl":"https://cdn.example.com/a.mp3",
         "artworkUrl":"","podcastTitle":"频道"}
        """
        let episode = try JSONDecoder().decode(Episode.self, from: Data(json.utf8))
        XCTAssertEqual(episode.id, "e1")
        XCTAssertFalse(episode.isLive, "老数据没有 isLive,不能读成直播")
        XCTAssertEqual(episode.transcriptUrl, "")
        XCTAssertEqual(episode.transcriptType, "")
        XCTAssertEqual(episode.durationSec, 0)
    }

    func testFullRoundTrip() throws {
        let episode = Episode(
            id: "e2", title: "标题", description: "简介",
            audioUrl: "https://cdn.example.com/a.m4a",
            artworkUrl: "https://cdn.example.com/a.jpg",
            podcastTitle: "频道", durationSec: 3725,
            pubDate: "2026-11-10T08:00:00Z",
            feedUrl: "https://feed.example.com/rss", isLive: true,
            transcriptUrl: "https://feed.example.com/t.json",
            transcriptType: "application/json"
        )
        let data = try JSONEncoder().encode(episode)
        XCTAssertEqual(try JSONDecoder().decode(Episode.self, from: data), episode)
    }

    func testMissingTitleStillDecodes() throws {
        let episode = try JSONDecoder().decode(Episode.self, from: Data("{}".utf8))
        XCTAssertEqual(episode.title, "")
        XCTAssertFalse(episode.isLive)
    }
}
