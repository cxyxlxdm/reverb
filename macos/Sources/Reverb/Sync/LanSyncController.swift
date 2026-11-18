import Foundation
import Network
import Combine
#if os(iOS)
import UIKit
#endif

/// 同步界面的状态机。UI 只读它,不碰协议。
enum LanSyncState: Equatable {
    case idle
    case listening(deviceName: String, addresses: [String], peers: [LanSyncPeer])
    case connecting(target: String)
    case confirm(peerName: String, code: String)
    case syncing(peerName: String, stage: LanSyncStage, percent: Int)
    case done(LanSyncResult)
    case failed(peerName: String?, fail: LanSyncFail, detail: String)
}

/// 局域网同步的总控:一台设备上**同时**做服务端和客户端。
///
/// 这不是"文件互传",是**双向合并**:任何一端发起,双方最终都拿到并集。所以界面上只需要
/// "在任意一台设备上点对方" —— 被点的那台会自动进入配对码确认,不用再点一次。
///
/// 生命周期跟界面绑定:`start()` 打开,关掉界面 `stop()` —— 不在后台常驻监听。
/// (用户明确说过 P0 不做锁屏/后台自动接力;这也顺带避开系统对后台网络的限制。)
///
/// 并发只有一条:**同一时刻只跑一个会话**。两端同时点对方时会各失败一次(对端的监听正在忙),
/// 界面上提示"只在一台设备上点连接",重试即可 —— 比让两端各跑两个会话、弹两次配对码清楚。
@MainActor
final class LanSyncController: ObservableObject {
    @Published private(set) var state: LanSyncState = .idle

    // 同步完成之后的「加时赛」:另一台在播什么、能不能接过来。
    // 与 `state` 分开,是因为同步结果不再变,而这几项每秒都在动(硬规矩 7 的同一条道理:
    // 别把高频状态塞进那个只在阶段变化时换值的枚举里)。
    @Published private(set) var peerHint: LanPeerHint?
    @Published private(set) var handoffLive = false
    @Published private(set) var handoffNote: String?
    @Published private(set) var takingOver = false
    @Published private(set) var localEpisodeId: String?
    @Published private(set) var localPlayingNow = false

    private let env: AppEnvironment
    private let identity = LanSyncIdentity()
    private var material: LanSyncIdentity.Material?
    private var listener: NWListener?
    private var discovery: LanSyncDiscovery?
    private var session: LanSyncSession?
    private var sessionTask: Task<Void, Never>?
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var peers: [LanSyncPeer] = []
    private var currentPeer: String?
    private var running = false
    private var stopping = false
    private var live: LanSyncLive?
    private var takeTimeout: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init(env: AppEnvironment) {
        self.env = env
        // 界面要知道「本机是不是已经在播这一集」:同一集刚被接手时不该再摆一颗「在此设备继续」。
        env.player.$current
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] in self?.localEpisodeId = $0 }
            .store(in: &bag)
        env.player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] in self?.localPlayingNow = $0 }
            .store(in: &bag)
    }

    var isBusy: Bool { sessionTask != nil }

    /// 打开面板:绑端口 + 广播 + 开始发现。可重复调用。
    func start() {
        guard !running else { return }
        running = true
        stopping = false
        Task { await begin() }
    }

    /// 关闭面板:停服务、停发现、断开当前会话。
    func stop() {
        stopping = true
        running = false
        discovery?.stop()
        discovery = nil
        listener?.cancel()
        listener = nil
        session?.close()
        session = nil
        sessionTask?.cancel()
        sessionTask = nil
        // `LanSyncLive` 是 actor,stop() 是隔离方法:同步上下文里只能甩出去,
        // 不能等它 —— 面板关闭不该卡在主线程上。
        let dying = live
        live = nil
        if let dying { Task { await dying.stop() } }
        takeTimeout?.cancel()
        takeTimeout = nil
        confirmContinuation?.resume(returning: false)
        confirmContinuation = nil
        peers = []
        currentPeer = nil
        peerHint = nil
        handoffLive = false
        handoffNote = nil
        takingOver = false
        state = .idle
        Log.i("LanSync", "已停止监听")
    }

    /// 人眼比对之后的唯一出口。拒绝时两端都会看到"已取消"。
    func confirm(_ accept: Bool) {
        let c = confirmContinuation
        confirmContinuation = nil
        c?.resume(returning: accept)
    }

    /// 点按发现到的设备。端点直接交给 Network.framework,不先解析 IP。
    func connect(to peer: LanSyncPeer) {
        connect(endpoint: peer.endpoint, label: peer.name)
    }

    /// 手动连接。接受 `192.168.1.5:47820` / `192.168.1.5`(默认端口)两种写法。
    func connect(manual raw: String) {
        guard let target = Self.parseTarget(raw) else {
            state = .failed(peerName: nil, fail: .connect, detail: "地址格式不对:\(raw)")
            return
        }
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            state = .failed(peerName: nil, fail: .connect, detail: "端口不合法:\(target.port)")
            return
        }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(target.host), port: port),
                label: "\(target.host):\(target.port)")
    }

    // MARK: - 生命周期

    private func begin() async {
        let m = identity.material
        material = m
        do {
            let l = try await startListener(name: m.name, deviceId: m.deviceId)
            listener = l
            let port = l.port?.rawValue ?? 0
            let d = LanSyncDiscovery(
                onPeers: { [weak self] list in self?.onPeers(list) },
                onError: { detail in Log.w("LanSync", "发现不可用:\(detail)") }
            )
            discovery = d
            d.start()
            peers = []
            publishListening(port: port)
            Log.i("LanSync", "开始监听 port=\(port) name=\(m.name) id=\(m.deviceId)")
        } catch {
            let detail = (error as? LanSyncException)?.message ?? error.localizedDescription
            state = .failed(peerName: nil, fail: .io, detail: "本机无法开始监听:\(detail)")
        }
    }

    private func startListener(name: String, deviceId: String) async throws -> NWListener {
        let service = NWListener.Service(
            name: "Reverb-\(deviceId.prefix(8))",
            type: "_reverb._tcp",
            domain: nil,
            txtRecord: NWTXTRecord(["nm": String(name.prefix(32))])
        )
        if let l = try await attemptListener(port: 47820, service: service) {
            return l
        }
        // 固定端口被占用时退到系统分配的端口;界面上会显示实际端口,手动输入照样能用。
        if let l = try await attemptListener(port: nil, service: service) {
            return l
        }
        throw LanSyncException(.io, "端口被占用,且系统没有给出可用端口")
    }

    private func attemptListener(port: UInt16?, service: NWListener.Service) async throws -> NWListener? {
        let endpointPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        let l: NWListener
        do {
            l = try NWListener(using: .tcp, on: endpointPort)
        } catch {
            Log.w("LanSync", "创建监听失败 port=\(port.map(String.init) ?? "auto"):\(error.localizedDescription)")
            return nil
        }
        l.service = service
        l.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        l.start(queue: DispatchQueue(label: "cn.cxyxl.reverb.lansync.listener"))
        let ready = await waitReady(l, timeout: 2)
        if !ready {
            l.cancel()
            return nil
        }
        return l
    }

    private func waitReady(_ listener: NWListener, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch listener.state {
            case .ready:
                return true
            case .failed(let error):
                Log.w("LanSync", "监听失败:\(error.localizedDescription)")
                return false
            case .cancelled:
                return false
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return listener.state == .ready
    }

    // MARK: - 会话

    private func accept(_ connection: NWConnection) {
        guard sessionTask == nil else {
            Log.w("LanSync", "已有会话,拒绝新连接")
            connection.cancel()
            return
        }
        runSession(connection, initiator: false)
    }

    private func connect(endpoint: NWEndpoint, label: String) {
        guard sessionTask == nil else {
            state = .failed(peerName: nil, fail: .connect, detail: "已有一次同步在跑")
            return
        }
        state = .connecting(target: label)
        let connection = NWConnection(to: endpoint, using: .tcp)
        runSession(connection, initiator: true)
    }

    private func runSession(_ connection: NWConnection, initiator: Bool) {
        guard let m = material ?? (running ? identity.material : nil) else {
            connection.cancel()
            state = .failed(peerName: nil, fail: .io, detail: "本机身份还没就绪")
            return
        }
        material = m
        let s = LanSyncSession(
            identity: m,
            connection: connection,
            initiator: initiator,
            buildSnapshot: { [weak self] in
                guard let self else { throw LanSyncException(.io, "界面已关闭") }
                return LanSyncMerge.build(self.env)
            },
            applySnapshot: { [weak self] json in
                guard let self else { throw LanSyncException(.io, "界面已关闭") }
                return try LanSyncMerge.apply(self.env, remoteJson: json)
            },
            confirm: { [weak self] peer, code in
                guard let self else { return false }
                self.currentPeer = peer
                self.state = .confirm(peerName: peer, code: code)
                return await withCheckedContinuation { cont in
                    self.confirmContinuation = cont
                }
            },
            stage: { [weak self] peer, stage, percent in
                guard let self else { return }
                self.currentPeer = peer
                self.state = .syncing(peerName: peer, stage: stage, percent: min(max(percent, 0), 100))
            }
        )
        session = s
        sessionTask = Task { [weak self] in
            do {
                let result = try await s.run()
                guard let self, !self.stopping else { s.close(); return }
                self.state = .done(result)
                if let live = self.makeLive(s) {
                    self.live = live
                    self.handoffLive = true
                    self.handoffNote = nil
                    Log.i("LanSync", "同步完成,进入交接通道 peer=\(result.peerName)")
                    await live.run()
                    self.live = nil
                }
            } catch let e as LanSyncException {
                Log.w("LanSync", "会话结束 \(e.fail):\(e.message)")
                if let self, !self.stopping {
                    self.state = .failed(peerName: self.currentPeer, fail: e.fail, detail: e.message)
                }
            } catch {
                Log.e("LanSync", "会话异常", error: error)
                if let self, !self.stopping {
                    self.state = .failed(peerName: self.currentPeer, fail: .io, detail: error.localizedDescription)
                }
            }
            s.close()
            self?.finishSession()
        }
    }

    /// 把已认证的连接交给交接层。闭包在这里统一往主线程跳一次,
    /// 协议层(actor)不认识 `PlayerController`,也不该认识。
    private func makeLive(_ session: LanSyncSession) -> LanSyncLive? {
        session.makeLive(
            provider: { [weak self] in
                guard let self else { return nil }
                return await MainActor.run { self.localPlaybackStatus() }
            },
            pauseForTake: { [weak self] in
                guard let self else { return nil }
                return await MainActor.run { self.pauseForTake() }
            },
            onPeer: { [weak self] hint, _ in
                guard let self else { return }
                await MainActor.run {
                    self.peerHint = hint
                    if hint != nil, !self.takingOver { self.handoffNote = nil }
                }
            },
            onTaken: { [weak self] episode, positionMs in
                guard let self else { return }
                await MainActor.run { self.applyTaken(episode, positionMs: positionMs) }
            },
            onEnded: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.handoffLive = false
                    self.peerHint = nil
                    self.takingOver = false
                    self.handoffNote = "另一台设备已离开，交接结束。"
                }
            }
        )
    }

    /// 用户点「在此设备继续」。**只发请求**;等对方先暂停并回最终位置,再由 `applyTaken` 起播。
    /// 两台同时出声是这类功能最典型的翻车方式(研究文档 §6),所以这里没有"本机先播"的分支。
    func takePlayback() {
        guard let live, peerHint != nil, !takingOver else { return }
        takingOver = true
        handoffNote = nil
        takeTimeout?.cancel()
        takeTimeout = Task { [weak self, weak live] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let live else { return }
            await live.cancelTake()
            await MainActor.run {
                guard let self, self.takingOver else { return }
                self.takingOver = false
                self.handoffNote = "对方没有回应，可以再试一次。"
            }
        }
        Task { [weak live] in
            guard let live else { return }
            await live.allowTakeAgain()
            do {
                try await live.take()
            } catch {
                Log.w("LanSync", "交接请求发送失败:\(error.localizedDescription)")
            }
        }
    }

    private func localPlaybackStatus() -> LanPlaybackStatus? {
        guard let ep = env.player.current, !ep.isLive else { return nil }
        return LanPlaybackStatus(
            episode: ep,
            positionMs: env.player.positionMs,
            durationMs: env.player.durationMs,
            playing: env.player.isPlaying,
            rate: env.player.speed,
            atMs: LanPlaybackStatus.nowMs()
        )
    }

    private func pauseForTake() -> LanPlaybackStatus? {
        guard let (ep, ms) = env.player.pauseForHandoff() else { return nil }
        return LanPlaybackStatus(
            episode: ep,
            positionMs: ms,
            durationMs: env.player.durationMs,
            playing: false,
            rate: env.player.speed,
            atMs: LanPlaybackStatus.nowMs()
        )
    }

    private func applyTaken(_ episode: Episode, positionMs: Int) {
        takeTimeout?.cancel()
        takeTimeout = nil
        takingOver = false
        handoffNote = "已在这台设备继续。"
        Log.i("LanSync", "交接起播 id=\(episode.id) at=\(positionMs)ms")
        env.player.playAt(episode, startMs: positionMs)
    }

    private func finishSession() {
        session = nil
        sessionTask = nil
        confirmContinuation?.resume(returning: false)
        confirmContinuation = nil
    }

    // MARK: - 地址

    private func onPeers(_ list: [LanSyncPeer]) {
        peers = list
        if case .listening = state {
            publishListening(port: listener?.port?.rawValue ?? 0)
        }
    }

    private func publishListening(port: UInt16) {
        guard let m = material else { return }
        state = .listening(deviceName: m.name, addresses: Self.localAddresses(port: port), peers: peers)
    }

    /// 本机局域网上的 IPv4 地址(不含回环 / 链路本地)。没有地址时返回空表,界面提示检查 Wi-Fi。
    private static func localAddresses(port: UInt16) -> [String] {
        guard port != 0 else { return [] }
        var result = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let code = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard code == 0 else { continue }
            let ip = String(cString: host)
            guard isSiteLocal(ip) else { continue }
            result.insert("\(ip):\(port)")
        }
        return result.sorted()
    }

    private static func isSiteLocal(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    static func parseTarget(_ raw: String) -> (host: String, port: UInt16)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http://") { text.removeFirst(7) }
        if text.hasPrefix("https://") { text.removeFirst(8) }
        if text.hasSuffix("/") { text.removeLast() }
        if text.isEmpty { return nil }
        let colons = text.filter { $0 == ":" }.count
        if colons == 1, let idx = text.lastIndex(of: ":") {
            let host = String(text[..<idx]).trimmingCharacters(in: .whitespaces)
            let portText = String(text[text.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let port = UInt16(portText), port > 0 else { return nil }
            return (host, port)
        }
        guard colons == 0 else { return nil }
        return (text, 47820)
    }
}
