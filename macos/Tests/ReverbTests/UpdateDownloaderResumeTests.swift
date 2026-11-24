import Network
import XCTest
@testable import Reverb

/// 真跑一遍 `UpdateDownloader`:本地服务器第一次只给一段就断开,第二次必须带
/// `Range` + `If-Range` 接上剩余字节。`UpdateResumeTests` 只验决策,这里验 delegate、
/// 追加写与元数据落盘真的串起来了。
final class UpdateDownloaderResumeTests: XCTestCase {

    func testTruncatedFirstAttemptResumesFromPart() async throws {
        let payload = Self.payload(1_500_000)
        let server = try RangeTestServer(payload: payload, truncateFirstAt: 600_000, ignoreRange: false)
        defer { server.stop() }
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }

        let first = await Self.download(server, files, payload)
        XCTAssertFalse(first, "服务器截断后第一次必须判失败")
        let partSize = try XCTUnwrap(Self.fileSize(files.part))
        XCTAssertGreaterThan(partSize, 0)
        XCTAssertLessThan(partSize, Int64(payload.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.meta.path))

        let second = await Self.download(server, files, payload)
        XCTAssertTrue(second, "第二次应从分片续传并下完")
        XCTAssertEqual(try Data(contentsOf: files.part), payload)

        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0]["range"])
        XCTAssertEqual(requests[1]["range"], "bytes=\(partSize)-")
        XCTAssertEqual(requests[1]["if-range"], server.etag)
    }

    func testRangeNotSatisfiableDiscardsPart() async throws {
        let payload = Self.payload(300_000)
        let server = try RangeTestServer(payload: payload, truncateFirstAt: 0,
                                         ignoreRange: false, force416: true)
        defer { server.stop() }
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }

        try Data(payload.prefix(40)).write(to: files.part)
        let meta = UpdateResumeMeta(tag: "9.9.9", etag: server.etag,
                                    lastModified: nil, total: Int64(payload.count))
        try JSONEncoder().encode(meta).write(to: files.meta)

        let ok = await Self.download(server, files, payload)
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.meta.path))
        XCTAssertEqual(server.requests.first?["range"], "bytes=40-")
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        let payload = Self.payload(1_200_000)
        let server = try RangeTestServer(payload: payload, truncateFirstAt: 500_000, ignoreRange: true)
        defer { server.stop() }
        let files = try Self.makeFiles()
        defer { try? FileManager.default.removeItem(at: files.dir) }

        let first = await Self.download(server, files, payload)
        XCTAssertFalse(first)
        let partSize = try XCTUnwrap(Self.fileSize(files.part))
        XCTAssertGreaterThan(partSize, 0)
        XCTAssertLessThan(partSize, Int64(payload.count))

        // 第二次虽然发了 Range,服务器按 200 回整包 —— 分片必须被截断重写,而不是接在后面。
        let second = await Self.download(server, files, payload)
        XCTAssertTrue(second)
        XCTAssertEqual(try Data(contentsOf: files.part), payload)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertNotNil(server.requests[1]["range"])
    }

    // MARK: - Helpers

    private struct Files {
        let dir: URL
        let part: URL
        let meta: URL
    }

    private static func makeFiles() throws -> Files {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reverb-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Files(dir: dir,
                     part: dir.appendingPathComponent("Reverb-test.dmg.part"),
                     meta: dir.appendingPathComponent("Reverb-test.dmg.part.json"))
    }

    private static func download(_ server: RangeTestServer, _ files: Files, _ payload: Data) async -> Bool {
        await UpdateDownloader(
            part: files.part,
            metaURL: files.meta,
            expectedTotal: Int64(payload.count),
            tag: "9.9.9",
            allowedHosts: ["127.0.0.1"],
            onPercent: { _ in }
        ).run(server.url)
    }

    private static func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return n.int64Value
    }
}

/// 最小 HTTP 服务器:第一次请求回 200 后只发一段就断开;之后按 `Range` 回 206(或故意回 200)。
private final class RangeTestServer: @unchecked Sendable {
    let etag = "\"resume-test-etag\""
    private let lastModified = "Sun, 22 Nov 2026 11:06:33 GMT"
    private let payload: Data
    private let truncateFirstAt: Int
    private let ignoreRange: Bool
    private let force416: Bool
    private let listener: NWListener
    private let queue = DispatchQueue(label: "reverb.range-test-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var _requests: [[String: String]] = []
    private var servedFirst = false

    var requests: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    init(payload: Data, truncateFirstAt: Int, ignoreRange: Bool, force416: Bool = false) throws {
        self.payload = payload
        self.truncateFirstAt = truncateFirstAt
        self.ignoreRange = ignoreRange
        self.force416 = force416
        self.listener = try NWListener(using: .tcp, on: .any)
        try start()
    }

    var url: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/Reverb-test.dmg")!
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let failed = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed: failed.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        if failed.wait(timeout: .now() + 3) == .success {
            throw NSError(domain: "RangeTestServer", code: 1)
        }
        if ready.wait(timeout: .now() + 3) == .timedOut {
            throw NSError(domain: "RangeTestServer", code: 2)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        readHeaders(on: connection, buffer: Data())
    }

    private func readHeaders(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            var merged = buffer
            merged.append(data)
            guard let end = merged.range(of: Data("\r\n\r\n".utf8)) else {
                self.readHeaders(on: connection, buffer: merged)
                return
            }
            let head = String(decoding: merged[..<end.lowerBound], as: UTF8.self)
            self.respond(connection, headers: self.parse(head))
        }
    }

    private func parse(_ head: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            out[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private func respond(_ connection: NWConnection, headers: [String: String]) {
        lock.lock()
        _requests.append(headers)
        let first = !servedFirst
        servedFirst = true
        lock.unlock()

        if force416 {
            send(connection, head: "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: Data())
            return
        }
        let requestedStart = headers["range"].flatMap(Self.parseRangeStart) ?? 0
        let truncated = first
        let start = (truncated || ignoreRange) ? 0 : requestedStart
        guard start < payload.count else {
            send(connection, head: "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: Data())
            return
        }
        let fullTail = payload.subdata(in: start..<payload.count)
        let body = truncated ? fullTail.prefix(truncateFirstAt) : fullTail
        let status = truncated ? "200 OK" : (start > 0 ? "206 Partial Content" : "200 OK")
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Length: \(truncated ? payload.count : body.count)\r\n"
        head += "ETag: \(etag)\r\n"
        head += "Last-Modified: \(lastModified)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if start > 0 && !truncated {
            head += "Content-Range: bytes \(start)-\(payload.count - 1)/\(payload.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        send(connection, head: head, body: body, closeAfter: true, delayed: truncated)
    }

    private func send(_ connection: NWConnection, head: String, body: Data,
                      closeAfter: Bool = true, delayed: Bool = false) {
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            connection.send(content: body, completion: .contentProcessed { _ in
                guard closeAfter else { return }
                // 给已入队的数据一点落地时间再断。截断那次要的是"下了半截",正常那次也别在
                // 最后一段还压在协议栈里时 cancel 掉。
                let delay: TimeInterval = delayed ? 0.3 : 0.15
                self?.queue.asyncAfter(deadline: .now() + delay) { connection.cancel() }
            })
        })
    }

    private static func parseRangeStart(_ raw: String) -> Int? {
        guard raw.hasPrefix("bytes="), raw.hasSuffix("-") else { return nil }
        return Int(raw.dropFirst("bytes=".count).dropLast())
    }
}
