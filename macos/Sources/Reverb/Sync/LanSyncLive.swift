import Foundation

/// 交接时一台设备要告诉对方的播放状态。`episode == nil` 表示"已经没有可交接的内容"。
///
/// **只带播放要用的字段**:`description`(shownotes)在网络里是几十 KB 的常客,
/// 1 Hz 发一遍等于把整篇稿件每秒传一次;接手的设备要的是 id / 标题 / 音频地址 / 封面。
struct LanPlaybackStatus: Equatable {
    var episode: Episode?
    var positionMs: Int
    var durationMs: Int
    var playing: Bool
    var rate: Double
    /// 发送者的墙钟毫秒。**只用于显示外推**,不参与任何排序(排序在合并层用墓碑/HLC 口径)。
    var atMs: Int64

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// 线格式。四端逐字段一致:`{t, ep?, pos, dur, playing, rate, at}`。
    func frame(_ type: String) -> [String: Any] {
        var f: [String: Any] = [
            "t": type,
            "pos": positionMs,
            "dur": durationMs,
            "playing": playing,
            "rate": rate,
            "at": atMs
        ]
        if let ep = episode, let obj = Self.episodeObject(ep) { f["ep"] = obj }
        return f
    }

    /// 解析失败(缺 pos)返回 nil —— 调用方按「对方没有内容」处理,不把半条帧当状态。
    static func parse(_ f: [String: Any]) -> LanPlaybackStatus? {
        guard let pos = (f["pos"] as? NSNumber)?.intValue else { return nil }
        let ep: Episode? = (f["ep"] as? [String: Any]).flatMap { episode(from: $0) }
        return LanPlaybackStatus(
            episode: ep,
            positionMs: pos,
            durationMs: (f["dur"] as? NSNumber)?.intValue ?? 0,
            playing: (f["playing"] as? Bool) ?? false,
            rate: (f["rate"] as? NSNumber)?.doubleValue ?? 1.0,
            atMs: (f["at"] as? NSNumber)?.int64Value ?? 0
        )
    }

    /// Episode 与三端备份/历史用的是同一份 JSON(`EpisodeJson` 的同义字段),
    /// 所以这里直接走 Codable,不再手写一张映射表 —— 手写的那张迟早漏字段(H259 同族)。
    private static func episodeObject(_ ep: Episode) -> [String: Any]? {
        var compact = ep
        compact.description = ""
        guard let data = try? JSONEncoder().encode(compact),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func episode(from obj: [String: Any]) -> Episode? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(Episode.self, from: data)
    }
}

/// 界面拿到的「另一台设备」状态。位置已按估计的时钟偏差外推到**现在**。
struct LanPeerHint: Equatable {
    let episode: Episode
    let positionMs: Int
    let playing: Bool
    /// 时钟样本不足 / 往返太大 ⇒ 位置只当参考,界面写「约 12:34」。
    let approximate: Bool
}

/// ping-pong 四时间戳的偏差估计。
///
/// `offset` 是「对端时钟 − 本机时钟」的毫秒数;`rtt` 用于判断这组样本值不值得信。
/// 取最近几组的中位数:单次样本会被某次 GC / 调度尖峰拉偏,中位数不会被一组坏样本带走。
struct LanClockSample: Equatable {
    var offsetMs: Double
    var rttMs: Double
}

struct LanClockEstimator: Equatable {
    private(set) var samples: [LanClockSample] = []
    static let capacity = 5

    var offsetMs: Double { Self.median(samples.map(\.offsetMs)) }
    var rttMs: Double { Self.median(samples.map(\.rttMs)) }
    /// 少于两组就不外推:只有一组时无法判断它是不是恰好被调度尖峰拉偏。
    var usable: Bool { samples.count >= 2 }

    mutating func add(_ s: LanClockSample) {
        guard s.rttMs.isFinite, s.rttMs >= 0, s.rttMs <= 2_000 else { return }
        samples.append(s)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// t0 = 本机发出 ping,t1 = 对端收到,t2 = 对端发出 pong,t3 = 本机收到。
    static func sample(t0: Int64, t1: Int64, t2: Int64, t3: Int64) -> LanClockSample? {
        let rtt = (t3 - t0) - (t2 - t1)
        guard rtt >= 0, rtt <= 2_000 else { return nil }
        let offset = (Double(t1 - t0) + Double(t2 - t3)) / 2.0
        return LanClockSample(offsetMs: offset, rttMs: Double(rtt))
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// 交接的实时通道。同步完成之后**复用同一条已认证的 TCP**,不再配对一次。
///
/// 产品边界(见 `docs/research/2026-11-11-lan-sync.md` §6):
/// - 只在「正在播放」时 1 Hz 发状态;暂停/跳转/切集立即补一条;
/// - **不自动接管** —— 必须对方屏幕上点「在此设备继续」;
/// - 交接流程固定为「请求方 take → 播放方先暂停并回 taken(带最终位置)→ 请求方 seek 再播」,
///   所以两台设备不会同时出声;
/// - 面板关掉socket 就断,这也是「不在后台常驻」承诺的实现方式。
///
/// 用 actor 而不是锁:`run()` 阻塞在 `receive()` 上时,`take()` 仍能插进来发帧。
actor LanSyncLive {
    typealias Send = @Sendable ([String: Any]) async throws -> Void
    typealias Receive = @Sendable () async throws -> [String: Any]
    typealias Provider = @Sendable () async -> LanPlaybackStatus?
    typealias PauseForTake = @Sendable () async -> LanPlaybackStatus?
    typealias OnPeer = @Sendable (LanPeerHint?, LanClockEstimator) async -> Void
    typealias OnTaken = @Sendable (Episode, Int) async -> Void
    typealias OnEnded = @Sendable () async -> Void

    private let send: Send
    private let receive: Receive
    private let provider: Provider
    private let pauseForTake: PauseForTake
    private let onPeer: OnPeer
    private let onTaken: OnTaken
    private let onEnded: OnEnded

    private var ticker: Task<Void, Never>?
    private var stopped = false
    private var clock = LanClockEstimator()
    private var lastSignature = "none"
    private var lastSentAt: Int64 = 0
    private var lastPositionMs = 0
    private var takeSentAt: Int64?
    private var takeTimedOut = false

    init(
        send: @escaping Send,
        receive: @escaping Receive,
        provider: @escaping Provider,
        pauseForTake: @escaping PauseForTake,
        onPeer: @escaping OnPeer,
        onTaken: @escaping OnTaken,
        onEnded: @escaping OnEnded
    ) {
        self.send = send
        self.receive = receive
        self.provider = provider
        self.pauseForTake = pauseForTake
        self.onPeer = onPeer
        self.onTaken = onTaken
        self.onEnded = onEnded
    }

    func run() async {
        ticker = Task { await self.tick() }
        do {
            while !stopped {
                let frame = try await receive()
                try await handle(frame)
            }
        } catch {
            if !stopped {
                // 对端关面板 / 老版本在同步完就断开,都走到这里。不是错误,不弹窗。
                Log.i("LanSync.Live", "交接通道结束:\(error.localizedDescription)")
            }
        }
        ticker?.cancel()
        ticker = nil
        await onEnded()
    }

    func stop() {
        stopped = true
        ticker?.cancel()
        ticker = nil
    }

    /// 用户点「在此设备继续」。**只发请求,不先播** —— 等对方的 `taken` 带最终位置回来。
    func take() async throws {
        if takeSentAt != nil || takeTimedOut { return }
        takeSentAt = LanPlaybackStatus.nowMs()
        try await send(["t": "take"])
    }

    /// 超时后取消这次请求:迟到的 `taken` 不再把播放器拽走。
    func cancelTake() {
        takeSentAt = nil
        takeTimedOut = true
    }

    func allowTakeAgain() {
        takeTimedOut = false
    }

    // MARK: - 帧

    private func handle(_ frame: [String: Any]) async throws {
        switch frame["t"] as? String ?? "" {
        case "pb":
            if let status = LanPlaybackStatus.parse(frame) {
                await onPeer(hint(from: status), clock)
            } else {
                // 「对方现在没有在播的内容」:清掉上一份,否则下一次 pong 会把旧提示又推回来。
                lastPeerStatus = nil
                await onPeer(nil, clock)
            }

        case "ping":
            let t1 = LanPlaybackStatus.nowMs()
            let pong: [String: Any] = [
                "t": "pong",
                "t0": (frame["t0"] as? NSNumber)?.int64Value ?? 0,
                "t1": t1,
                "t2": LanPlaybackStatus.nowMs()
            ]
            try await send(pong)

        case "pong":
            guard let t0 = (frame["t0"] as? NSNumber)?.int64Value,
                  let t1 = (frame["t1"] as? NSNumber)?.int64Value,
                  let t2 = (frame["t2"] as? NSNumber)?.int64Value else { return }
            if let sample = LanClockEstimator.sample(
                t0: t0, t1: t1, t2: t2, t3: LanPlaybackStatus.nowMs()
            ) {
                clock.add(sample)
                await onPeer(currentPeerHint, clock)
            }

        case "take":
            if let status = await pauseForTake() {
                try await send(status.frame("taken"))
            } else {
                try await send(["t": "taken", "none": true])
            }

        case "taken":
            let sentAt = takeSentAt
            takeSentAt = nil
            guard sentAt != nil else { return }
            if (frame["none"] as? Bool) == true { return }
            guard let status = LanPlaybackStatus.parse(frame), let ep = status.episode else { return }
            let rtt = max(0, LanPlaybackStatus.nowMs() - (sentAt ?? 0))
            let target = Self.handoffPosition(
                positionMs: status.positionMs,
                rttMs: Int(rtt),
                rate: status.rate,
                durationMs: status.durationMs
            )
            await onTaken(ep, target)

        default:
            break
        }
    }

    private var lastPeerStatus: LanPlaybackStatus?

    private var currentPeerHint: LanPeerHint? {
        lastPeerStatus.flatMap { hint(from: $0) }
    }

    private func hint(from status: LanPlaybackStatus) -> LanPeerHint? {
        lastPeerStatus = status
        guard let ep = status.episode else { return nil }
        let approximate = !clock.usable || clock.rttMs > 2_000
        var pos = Double(status.positionMs)
        if !approximate && status.playing {
            let peerNow = Double(status.atMs) + clock.offsetMs
            let elapsed = (Double(LanPlaybackStatus.nowMs()) - peerNow) / 1000.0
            // 外推只在一分钟内可信;对端时钟被改过 / 休眠很久时不要画出离谱的位置。
            if elapsed > -5, elapsed < 60 { pos += elapsed * status.rate }
        }
        if status.durationMs > 0 { pos = min(max(0, pos), Double(status.durationMs)) }
        return LanPeerHint(
            episode: ep,
            positionMs: max(0, Int(pos)),
            playing: status.playing,
            approximate: approximate
        )
    }

    /// 交接位置 = 对方暂停时的位置 + 这次 `take` 往返的一半 × 对方速率。
    /// 为什么用往返一半而不是时钟偏差:整条路径里只需要知道「消息在网线里走了多久」,
    /// 两台的墙钟差多少与这件事无关。末尾留 1.5 秒余量,避免刚好落在结尾被判成已播完。
    static func handoffPosition(positionMs: Int, rttMs: Int, rate: Double, durationMs: Int) -> Int {
        let advance = Double(max(0, rttMs)) / 2.0 * max(0.1, rate)
        var target = max(0, Int(Double(positionMs) + advance))
        if durationMs > 1_500 { target = min(target, durationMs - 1_500) }
        return target
    }

    // MARK: - 本机状态推送

    private func tick() async {
        var nextPing: Int64 = 0
        var burst = 0
        while !Task.isCancelled && !stopped {
            let now = LanPlaybackStatus.nowMs()
            if now >= nextPing {
                try? await send(["t": "ping", "t0": now])
                if burst < 5 {
                    burst += 1
                    nextPing = now + 400
                } else {
                    nextPing = now + 5_000
                }
            }
            await pushLocal(now)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func pushLocal(_ now: Int64) async {
        let status = await provider()
        let signature: String
        if let status {
            signature = "\(status.episode?.id ?? "")|\(status.playing)|\(Int((status.rate * 100).rounded()))"
        } else {
            signature = "none"
        }
        var seeked = false
        if let status, status.playing, signature == lastSignature, lastSentAt > 0 {
            let dt = Double(now - lastSentAt) / 1000.0
            let expected = Double(lastPositionMs) + dt * status.rate * 1000.0
            seeked = abs(Double(status.positionMs) - expected) > 2_500
        }
        let due = signature != lastSignature
            || seeked
            || (status?.playing == true && now - lastSentAt >= 1_000)
        guard due else { return }
        if let status {
            try? await send(status.frame("pb"))
            lastPositionMs = status.positionMs
        } else {
            lastPositionMs = 0
            try? await send(["t": "pb"])
        }
        lastSignature = signature
        lastSentAt = now
    }
}
