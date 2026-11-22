import XCTest
@testable import Reverb

/// 电台数据契约的单测:七键往返、缺键兜底、坏条目逐条丢弃、目录解析口径。
/// 这些都是四端共用判据,改任何一端之前先看这里断言的是哪一条。
final class StationTests: XCTestCase {
    private func decode(_ json: String) -> [Station] {
        StationList.decodeLossy(Data(json.utf8))
    }

    func testSevenKeyRoundtrip() throws {
        let s = Station(id: "local:abc", name: "测试台", url: "https://example.com/live.mp3",
                        logo: "https://example.com/logo.png", group: "news",
                        country: "CN", source: Station.sourceManual)
        let data = try JSONEncoder().encode([s])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(obj[0].keys), ["id", "name", "url", "logo", "group", "country", "source"])
        let back = StationList.decodeLossy(data)
        XCTAssertEqual(back, [s])
    }

    func testMissingKeysFallBack() {
        let list = decode("[{\"url\":\" https://a.example/live \"}]")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "local:https://a.example/live")
        XCTAssertEqual(list[0].name, "https://a.example/live")
        XCTAssertEqual(list[0].source, Station.sourceManual)
        XCTAssertEqual(list[0].group, "")
    }

    func testBlankUrlIsDroppedOneByOne() {
        let list = decode("""
        [{"url":"https://ok.example/a","name":"A"},
         {"url":"   ","name":"坏"},
         "不是对象",
         {"url":"https://ok.example/b","name":"B"}]
        """)
        XCTAssertEqual(list.map(\.name), ["A", "B"])
    }

    func testGroupIsNormalized() {
        XCTAssertEqual(Station.normalizeGroup(" NEWS "), "news")
        XCTAssertEqual(Station.normalizeGroup("jazz"), "")
        XCTAssertEqual(Station.normalizeGroup(""), "")
    }

    func testSeedParseUsesDeterministicId() throws {
        let json = """
        {"version":1,"stations":[
          {"name":"甲","url":"https://seed.example/a","group":"MUSIC","country":""},
          {"name":"乙","url":"https://seed.example/a"},
          {"name":"","url":"https://seed.example/c"},
          {"name":"丙","url":"https://seed.example/d","country":"CN"}
        ]}
        """
        let list = StationJson.seed(from: Data(json.utf8))
        XCTAssertEqual(list.map(\.id), ["seed:https://seed.example/a", "seed:https://seed.example/d"])
        XCTAssertEqual(list[0].source, Station.sourceSeed)
        XCTAssertEqual(list[0].group, "music")
        XCTAssertEqual(list[0].country, "CN")
        XCTAssertEqual(list[1].country, "CN")
    }

    func testDirectoryParsePrefersResolvedAndFilters() throws {
        let json = """
        [{"stationuuid":"u1","name":"甲","url":"https://old.example/a",
          "url_resolved":"https://new.example/a","favicon":"https://f/1.png",
          "country":"China","lastcheckok":1},
         {"stationuuid":"u2","name":"坏","url":"https://broken.example","lastcheckok":0},
         {"stationuuid":"u3","name":"无地址","url":"","lastcheckok":1},
         {"stationuuid":"u4","name":"重复","url":"https://new.example/a","lastcheckok":1},
         {"stationuuid":"","name":"无 uuid","url":"https://plain.example/b","lastcheckok":1}]
        """
        let list = RadioBrowserSource.parse(Data(json.utf8))
        XCTAssertEqual(list.map(\.id), ["rb:u1", "rb:https://plain.example/b"])
        XCTAssertEqual(list[0].url, "https://new.example/a")
        XCTAssertEqual(list[0].logo, "https://f/1.png")
        XCTAssertEqual(list[0].source, Station.sourceDirectory)
        XCTAssertEqual(list[1].country, "")
    }

    func testDirectoryParseRejectsNonArray() {
        XCTAssertTrue(RadioBrowserSource.parse(Data("{\"error\":1}".utf8)).isEmpty)
        XCTAssertTrue(RadioBrowserSource.parse(Data("<html>".utf8)).isEmpty)
    }

    func testEndpointKeepsQuerySeparatorsInsideValues() throws {
        let url = try XCTUnwrap(RadioBrowserSource.endpoint(host: "de1.example", params: [
            ("name", "AT&T"), ("limit", "5")
        ]))
        // 值里的 & 必须编码 —— 否则服务端会把它读成两条参数(HTTPClient.encode 的同一条教训)。
        XCTAssertTrue(url.absoluteString.contains("name=AT%26T"))
        XCTAssertTrue(url.absoluteString.hasSuffix("/json/stations/search?name=AT%26T&limit=5"))
    }
}
