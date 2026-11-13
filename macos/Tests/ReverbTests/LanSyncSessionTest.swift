import XCTest
import CryptoKit
import Network
@testable import Reverb

/// 局域网同步的端到端判据(Apple 侧):真实 loopback TCP、真实握手、真实分块。
///
/// 与 Android `LanSyncSessionTest.kt` 同一组场景 —— 两端跑的是同一份协议,
/// 所以这里的每一条都应该能在 Android 上找到对应断言:
/// 配对码一致、双向并集、跨块传输、取消语义。
@MainActor
final class LanSyncSessionTest: XCTestCase {

    // MARK: - 配对与双向合并

    func testPairAndUnionMergeOverLoopback() async throws {
        let alice = Self.material(name: "Mac")
        let bob = Self.material(name: "iPhone")
        let aliceStore = IntStore(ids: Array(0..<1000))
        let bobStore = IntStore(ids: Array(1000..<2000))

        let codes = CodeBox()
        let (resultA, resultB) = try await runPair(
            alice: alice, bob: bob, aliceStore: aliceStore, bobStore: bobStore, codes: codes, confirm: true
        )

        XCTAssertEqual(codes.alice, codes.bob, "两端各自算出的六位配对码必须相同")
        XCTAssertEqual(codes.alice?.count, 6)
        XCTAssertEqual(aliceStore.ids.sorted(), Array(0..<2000))
        XCTAssertEqual(bobStore.ids.sorted(), Array(0..<2000))
        // 应方把「发起方合并后的全集」再并一遍,新增读数是 1000(它自己没有的那一半)。
        XCTAssertEqual(resultA.total, 1000)
        XCTAssertEqual(resultB.total, 1000)
    }

    /// 快照超过 256 KiB 时必须分块。30000 个 5 位 id 的 JSON 约 300 KB。
    func testSnapshotLargerThanOneChunk() async throws {
        let alice = Self.material(name: "Mac")
        let bob = Self.material(name: "iPhone")
        let aliceStore = IntStore(ids: Array(0..<30000))
        let bobStore = IntStore(ids: Array(30000..<60000))
        let codes = CodeBox()

        _ = try await runPair(
            alice: alice, bob: bob, aliceStore: aliceStore, bobStore: bobStore, codes: codes, confirm: true
        )

        XCTAssertEqual(aliceStore.ids.count, 60000)
        XCTAssertEqual(bobStore.ids.count, 60000)
    }

    /// 本机拒绝时,对端必须收到"对方取消",而不是干等到超时。
    func testLocalCancelReachesPeer() async throws {
        let alice = Self.material(name: "Mac")
        let bob = Self.material(name: "iPhone")
        let aliceStore = IntStore(ids: [1])
        let bobStore = IntStore(ids: [2])
        let codes = CodeBox()

        do {
            _ = try await runPair(
                alice: alice, bob: bob, aliceStore: aliceStore, bobStore: bobStore, codes: codes, confirm: false
            )
            XCTFail("本机拒绝后不应返回成功")
        } catch let error as LanSyncException {
            XCTAssertTrue(error.fail == .cancelled || error.fail == .peerCancelled, "实际是 \(error.fail):\(error.message)")
        }
        // 双方都没有真的合并。
        XCTAssertEqual(aliceStore.ids, [1])
        XCTAssertEqual(bobStore.ids, [2])
    }

    // MARK: - 纯判据

    func testManualTargetParsing() {
        XCTAssertEqual(LanSyncController.parseTarget("192.168.1.5:47820")?.host, "192.168.1.5")
        XCTAssertEqual(LanSyncController.parseTarget("192.168.1.5:47820")?.port, 47820)
        XCTAssertEqual(LanSyncController.parseTarget("192.168.1.5")?.port, 47820)
        XCTAssertEqual(LanSyncController.parseTarget(" http://192.168.1.5:9000/ ")?.port, 9000)
        XCTAssertNil(LanSyncController.parseTarget(""))
        XCTAssertNil(LanSyncController.parseTarget("192.168.1.5:70000"))
        XCTAssertNil(LanSyncController.parseTarget("fe80::1"))
    }

    func testFeedUrlNormalizationRules() {
        // 协议与主机名大小写、尾部斜杠不构成另一个源;路径大小写敏感。
        XCTAssertEqual(LanSyncMerge.normalize("HTTPS://Example.COM/Feed.XML/"), "https://example.com/Feed.XML")
        XCTAssertNotEqual(LanSyncMerge.normalize("https://example.com/Feed.XML"), LanSyncMerge.normalize("https://example.com/feed.xml"))
        XCTAssertEqual(LanSyncMerge.normalize(" https://example.com/a?x=1 "), "https://example.com/a?x=1")
        XCTAssertNil(LanSyncMerge.normalize("   "))
    }

    // MARK: - 搭台

    private func runPair(
        alice: LanSyncIdentity.Material,
        bob: LanSyncIdentity.Material,
        aliceStore: IntStore,
        bobStore: IntStore,
        codes: CodeBox,
        confirm: Bool
    ) async throws -> (LanSyncResult, LanSyncResult) {
        let (listener, accepted) = try await startListener()
        defer { listener.cancel() }

        let port = NWEndpoint.Port(rawValue: listener.port!.rawValue)!
        let outgoing = NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: .tcp)
        // 先发起连接,再去等监听侧 accept —— 否则 accepted.wait 会先超时,而客户端根本还没启动。
        outgoing.start(queue: DispatchQueue(label: "cn.cxyxl.reverb.test.outgoing"))
        let incoming = try await accepted.wait(timeout: 5)

        let aliceSession = LanSyncSession(
            identity: alice,
            connection: outgoing,
            initiator: true,
            buildSnapshot: { aliceStore.json() },
            applySnapshot: { text in aliceStore.merge(text) },
            confirm: { _, code in codes.alice = code; return confirm },
            stage: { _, _, _ in }
        )
        let bobSession = LanSyncSession(
            identity: bob,
            connection: incoming,
            initiator: false,
            buildSnapshot: { bobStore.json() },
            applySnapshot: { text in bobStore.merge(text) },
            confirm: { _, code in codes.bob = code; return confirm },
            stage: { _, _, _ in }
        )

        async let ra = aliceSession.run()
        async let rb = bobSession.run()
        do {
            let pair = try await (ra, rb)
            aliceSession.close()
            bobSession.close()
            return pair
        } catch {
            aliceSession.close()
            bobSession.close()
            throw error
        }
    }

    private func startListener() async throws -> (NWListener, AcceptedConnection) {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = AcceptedConnection()
        listener.newConnectionHandler = { connection in
            // 不主动 start:交给 LanSyncChannel(它在连接仍处于 .setup 时启动)。
            accepted.deliver(connection)
        }
        listener.start(queue: DispatchQueue(label: "cn.cxyxl.reverb.test.listener"))
        for _ in 0..<200 {
            if listener.state == .ready, listener.port != nil {
                return (listener, accepted)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        listener.cancel()
        throw LanSyncException(.connect, "测试监听器没有就绪")
    }

    private static func material(name: String) -> LanSyncIdentity.Material {
        let id = LanSyncCrypto.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        return LanSyncIdentity.Material(
            deviceId: id,
            name: name,
            createdAt: Date()
        )
    }
}

// MARK: - 测试替身

/// 内存表:快照就是 id 数组的 JSON,合并就是并集 —— 与协议层的 `buildSnapshot/applySnapshot` 对齐。
private final class IntStore: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ids: [Int]

    init(ids: [Int]) { self.ids = ids }

    func json() -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = try! JSONSerialization.data(withJSONObject: ["version": 1, "ids": ids])
        return String(data: data, encoding: .utf8)!
    }

    /// 返回各分区新增条数;这个测试只有一"区",其余位置补 0。
    func merge(_ text: String) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        let before = ids.count
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let incoming = (object?["ids"] as? [Int]) ?? []
        ids = Array(Set(ids).union(incoming)).sorted()
        return [ids.count - before, 0, 0, 0, 0, 0]
    }
}

private final class CodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var a: String?
    private var b: String?
    var alice: String? {
        get { lock.lock(); defer { lock.unlock() }; return a }
        set { lock.lock(); a = newValue; lock.unlock() }
    }
    var bob: String? {
        get { lock.lock(); defer { lock.unlock() }; return b }
        set { lock.lock(); b = newValue; lock.unlock() }
    }
}

private final class AcceptedConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<NWConnection, Error>?

    func deliver(_ c: NWConnection) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: c)
            return
        }
        connection = c
        lock.unlock()
    }

    func wait(timeout: TimeInterval) async throws -> NWConnection {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let c = connection {
                connection = nil
                lock.unlock()
                cont.resume(returning: c)
                return
            }
            continuation = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let c = self.continuation {
                    self.continuation = nil
                    self.lock.unlock()
                    c.resume(throwing: LanSyncException(.connect, "等待连接超时"))
                } else {
                    self.lock.unlock()
                }
            }
        }
    }
}
