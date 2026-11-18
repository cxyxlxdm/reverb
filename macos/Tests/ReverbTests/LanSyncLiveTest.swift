import XCTest
@testable import Reverb

/// 播放交接的判据。两层:
/// - **纯判据**:时钟样本、位置外推、线格式往返 —— 这些是四端逐字节一致的部分;
/// - **端到端**:两个 `LanSyncLive` 用内存通道对跑,验证「A 先暂停、B 拿到 taken 才播」
///   这个顺序。顺序才是这个功能的产品承诺,**两台设备同时出声是最典型的翻车方式**。
@MainActor
final class LanSyncLiveTest: XCTestCase {

    // MARK: - 纯判据:时钟

    func testClockSampleMath() {
        // t0=1000 t1=1100 t2=1150 t3=1300:去程 100、回程 150 ⇒ rtt 250、偏差 -25。
        let s = LanClockEstimator.sample(t0: 1000, t1: 1100, t2: 1150, t3: 1300)
        XCTAssertEqual(s?.rttMs, 250)
        XCTAssertEqual(s?.offsetMs, -25)
    }

    func testClockSampleRejectsBadRoundTrips() {
        // 对端"处理"了 900 ms 而整趟只走了 200 ms ⇒ rtt 为负,这组样本是垃圾。
        XCTAssertNil(LanClockEstimator.sample(t0: 0, t1: 100, t2: 1_000, t3: 200))
        // 一次尖峰 2.5 秒:中位数能吸收,但单这一组不该被采信。
        XCTAssertNil(LanClockEstimator.sample(t0: 0, t1: 1_250, t2: 1_250, t3: 2_500))
    }

    func testMedian() {
        XCTAssertEqual(LanClockEstimator.median([]), 0)
        XCTAssertEqual(LanClockEstimator.median([7]), 7)
        XCTAssertEqual(LanClockEstimator.median([3, 1, 2]), 2)
        XCTAssertEqual(LanClockEstimator.median([4, 1, 3, 2]), 2.5)
    }

    func testEstimatorNeedsTwoSamplesAndKeepsLastFive() {
        var est = LanClockEstimator()
        XCTAssertFalse(est.usable, "只有一组样本时不外推位置")
        est.add(LanClockSample(offsetMs: 100, rttMs: 10))
        XCTAssertFalse(est.usable)
        est.add(LanClockSample(offsetMs: 120, rttMs: 20))
        XCTAssertTrue(est.usable)
        XCTAssertEqual(est.offsetMs, 110)

        for i in 0..<10 { est.add(LanClockSample(offsetMs: Double(i), rttMs: 5)) }
        XCTAssertEqual(est.samples.count, LanClockEstimator.capacity)
        XCTAssertEqual(est.offsetMs, 7)   // 最近五组 5,6,7,8,9 的中位数

        est.add(LanClockSample(offsetMs: 0, rttMs: 9_999))
        XCTAssertEqual(est.samples.count, LanClockEstimator.capacity, "超长往返的样本直接丢")
    }

    // MARK: - 纯判据:交接位置

    func testHandoffPositionAddsHalfRoundTrip() {
        XCTAssertEqual(
            LanSyncLive.handoffPosition(positionMs: 60_000, rttMs: 0, rate: 1, durationMs: 3_600_000),
            60_000
        )
        XCTAssertEqual(
            LanSyncLive.handoffPosition(positionMs: 60_000, rttMs: 1_000, rate: 1, durationMs: 3_600_000),
            60_500
        )
        // 倍速播放时,同样的网线时间对应对端走了两倍的内容。
        XCTAssertEqual(
            LanSyncLive.handoffPosition(positionMs: 60_000, rttMs: 1_000, rate: 2, durationMs: 3_600_000),
            61_000
        )
    }

    func testHandoffPositionClampsNearTheEnd() {
        // 落点必须离结尾至少 1.5 秒,否则接手的设备会立刻判「已播完」。
        XCTAssertEqual(
            LanSyncLive.handoffPosition(positionMs: 3_599_800, rttMs: 1_000, rate: 1, durationMs: 3_600_000),
            3_598_500
        )
        // 时长本来就不足 1.5 秒(试听片段)时不夹,夹了会得到负数。
        XCTAssertEqual(
            LanSyncLive.handoffPosition(positionMs: 900, rttMs: 0, rate: 1, durationMs: 1_000),
            900
        )
    }

    func testHandoffPositionToleratesNegativeInputs() {
        XCTAssertEqual(
            LanSyncLive.handoffPosition(positionMs: 10_000, rttMs: -40, rate: 1, durationMs: 3_600_000),
            10_000
        )
        // 速率下限 0.1:0.5× 以下(含负数/0)都按 0.1 算,别把落点算成负的。
        XCTAssertEqual(
            LanSyncLive.handoffPosition(positionMs: 10_000, rttMs: 1_000, rate: 0, durationMs: 3_600_000),
            10_050
        )
    }

    // MARK: - 纯判据:线格式

    func testStatusFrameRoundTripStripsDescription() throws {
        let ep = Self.episode(id: "ep-1", title: "第 42 集", description: String(repeating: "shownotes ", count: 2_000))
        let status = LanPlaybackStatus(
            episode: ep, positionMs: 61_000, durationMs: 3_600_000,
            playing: true, rate: 1.5, atMs: 1_700_000_000_000
        )
        let frame = status.frame("pb")
        XCTAssertEqual(frame["t"] as? String, "pb")
        let epObject = try XCTUnwrap(frame["ep"] as? [String: Any])
        XCTAssertEqual(epObject["description"] as? String, "", "1 Hz 的帧里不能带 shownotes")

        let back = try XCTUnwrap(LanPlaybackStatus.parse(frame))
        XCTAssertEqual(back.episode?.id, "ep-1")
        XCTAssertEqual(back.episode?.title, "第 42 集")
        XCTAssertEqual(back.episode?.audioUrl, ep.audioUrl)
        XCTAssertEqual(back.positionMs, 61_000)
        XCTAssertEqual(back.durationMs, 3_600_000)
        XCTAssertEqual(back.playing, true)
        XCTAssertEqual(back.rate, 1.5)
        XCTAssertEqual(back.atMs, 1_700_000_000_000)
    }

    func testStatusParseRejectsFramesWithoutPosition() {
        // 「对方现在没在播」只发 `{t:"pb"}`:没有 pos 就是没有状态,不能解成 0 秒。
        XCTAssertNil(LanPlaybackStatus.parse(["t": "pb"]))
        XCTAssertNil(LanPlaybackStatus.parse(["t": "pb", "ep": ["id": "x"]]))
    }

    // MARK: - 端到端:take 的先后顺序

    func testTakePausesPeerBeforeReceiverPlays() async throws {
        let inboxA = Inbox()
        let inboxB = Inbox()
        let log = EventLog()
        let ep = Self.episode(id: "ep-live", title: "交接这一集", description: "很长的 shownotes")

        // A:正在播(第 60 秒),被 take 时"暂停"并把位置推进到第 61 秒。
        let statusA = LanPlaybackStatus(
            episode: ep, positionMs: 61_000, durationMs: 3_600_000,
            playing: false, rate: 1, atMs: LanPlaybackStatus.nowMs()
        )
        let liveA = LanSyncLive(
            send: { frame in inboxB.put(frame) },
            receive: { try await inboxA.next() },
            provider: {
                LanPlaybackStatus(
                    episode: ep, positionMs: 60_000, durationMs: 3_600_000,
                    playing: true, rate: 1, atMs: LanPlaybackStatus.nowMs()
                )
            },
            pauseForTake: { await log.append("A.pause"); return statusA },
            onPeer: { _, _ in },
            onTaken: { _, _ in await log.append("A.taken-unexpected") },
            onEnded: {}
        )

        let taken = Locked<[Int]>([])
        let liveB = LanSyncLive(
            send: { frame in inboxA.put(frame) },
            receive: { try await inboxB.next() },
            provider: { nil },
            pauseForTake: { nil },
            onPeer: { hint, _ in if hint != nil { await log.append("B.peer") } },
            onTaken: { episode, positionMs in
                await log.append("B.play")
                taken.set { $0.append(positionMs) }
                XCTAssertEqual(episode.id, "ep-live")
            },
            onEnded: {}
        )

        async let runA: Void = liveA.run()
        async let runB: Void = liveB.run()

        // 1) 先只跑一会儿:A 的 pb 应该送到 B,B 从此进入「可接手」状态。
        await Self.waitUntil("B 收到 A 的播放状态") { await log.has("B.peer") }
        let beforeTake = await log.snapshot

        // 2) 点「在此设备继续」。
        do { try await liveB.take() } catch { XCTFail("发 take 失败:\(error)") }
        await Self.waitUntil("B 收到 taken") { taken.get().isEmpty == false }
        let after = await log.snapshot

        // 3) 先收摊再断言:测试体若在子任务还阻塞在读上时抛错,那个子任务永远等不到
        // 下一帧,async let 就不会结束 —— 整个测试挂死(写这组测试时踩过一次)。
        await liveB.stop()
        await liveA.stop()
        inboxA.close()
        inboxB.close()
        _ = await (runA, runB)

        XCTAssertFalse(beforeTake.contains("B.play"), "没有点「在此设备继续」之前不能自己播")

        let pauseIdx = after.firstIndex(of: "A.pause")
        let playIdx = after.firstIndex(of: "B.play")
        XCTAssertNotNil(pauseIdx, "A 应该被要求暂停")
        XCTAssertNotNil(playIdx, "B 应该开播")
        if let pauseIdx, let playIdx {
            XCTAssertLessThan(pauseIdx, playIdx, "B 必须在 A 确认暂停之后才开播")
        }

        // 落点 = A 的最终位置 + 往返的一半(环回往返只有几毫秒,留 200 ms 宽)。
        if let target = taken.get().first {
            XCTAssertGreaterThanOrEqual(target, 61_000)
            XCTAssertLessThanOrEqual(target, 61_200)
        } else {
            XCTFail("B 没有拿到交接位置")
        }
    }

    func testPeerCloseEndsHandoff() async throws {
        let inboxA = Inbox()
        let inboxB = Inbox()
        let ended = Locked(false)
        let ep = Self.episode(id: "ep-x", title: "随便一集", description: "")

        let liveA = LanSyncLive(
            send: { frame in inboxB.put(frame) },
            receive: { try await inboxA.next() },
            provider: {
                LanPlaybackStatus(
                    episode: ep, positionMs: 1_000, durationMs: 60_000,
                    playing: true, rate: 1, atMs: LanPlaybackStatus.nowMs()
                )
            },
            pauseForTake: { nil },
            onPeer: { _, _ in },
            onTaken: { _, _ in },
            onEnded: { ended.set { $0 = true } }
        )
        let liveB = LanSyncLive(
            send: { frame in inboxA.put(frame) },
            receive: { try await inboxB.next() },
            provider: { nil },
            pauseForTake: { nil },
            onPeer: { _, _ in },
            onTaken: { _, _ in },
            onEnded: {}
        )

        async let runA: Void = liveA.run()
        async let runB: Void = liveB.run()
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 对端关面板 = 连接断开。**关的是 A 读的那一头**(A 才是「对端走了」的观察者);
        // 不是错误,只结束交接。
        inboxA.close()
        await Self.waitUntil("A 收到连接结束") { ended.get() }

        await liveA.stop()
        await liveB.stop()
        inboxA.close()
        inboxB.close()
        _ = await (runA, runB)

        XCTAssertTrue(ended.get(), "对端断开时必须通知界面「交接结束」")
    }

    // MARK: - 搭台

    private static func episode(id: String, title: String, description: String) -> Episode {
        Episode(
            id: id,
            title: title,
            description: description,
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: "https://example.com/\(id).jpg",
            podcastTitle: "余音测试台",
            durationSec: 3_600
        )
    }

    private static func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待超时(\(timeout) 秒):\(what)")
    }
}

// MARK: - 测试替身

/// 一条方向的内存通道:帧先进队列,消费方按序取。`close()` 之后取帧会抛错 ——
/// 对应真实 socket 上「对端关面板」那次读失败。
private final class Inbox: @unchecked Sendable {
    struct Closed: Error {}

    private let lock = NSLock()
    private var items: [[String: Any]] = []
    private var closed = false
    private var waiter: CheckedContinuation<[String: Any], Error>?

    func put(_ frame: [String: Any]) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: frame)
            return
        }
        items.append(frame)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: Closed())
    }

    func next() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !items.isEmpty {
                let f = items.removeFirst()
                lock.unlock()
                cont.resume(returning: f)
                return
            }
            if closed {
                lock.unlock()
                cont.resume(throwing: Closed())
                return
            }
            waiter = cont
            lock.unlock()
        }
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}

/// 有序事件表。交接的核心判据是**顺序**,不是"发生过"。
private actor EventLog {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }
    var snapshot: [String] { events }
    var count: Int { events.count }
    func has(_ event: String) -> Bool { events.contains(event) }
}
