import Foundation
import Network

/// 同步中的阶段。UI 只按阶段换一句文案,不解析协议。
enum LanSyncStage: Equatable {
    case sending
    case receiving
    case merging
}

/// 一次同步的**增量**读数。`total` 为 0 时界面上不该出现"新增 0 · 0 · 0"。
struct LanSyncResult: Equatable {
    let peerName: String
    let subscriptions: Int
    let favorites: Int
    let stamps: Int
    let notes: Int
    let history: Int
    let stats: Int

    var total: Int { subscriptions + favorites + stamps + notes + history + stats }
}

/// 一次完整的配对 + 合并会话。**两端跑的是同一份代码,只有 initiator 一个布尔量的差别**:
///
/// ```text
/// 双方:  hello(明文, 公钥 + nonce)
/// 双方:  各自算共享密钥 / 会话密钥 / 六位配对码 → 人眼比对
/// 双方:  confirm(密封)          ← 能解开对方的 confirm 就证明会话密钥一致
/// 发起方: request               → 应方把自己的快照分成块发过来
/// 发起方: 并入 → 把**合并后的全集**发回应方
/// 应方:  并入 → ack
/// ```
///
/// 为什么第二程发的是"合并后的全集"而不是"我这边新增的那部分":全集天然幂等,
/// 而且不需要跟踪"上次同步到哪"(P0 没有同步游标)。代价是多传一遍数据 —— 局域网里可以接受。
///
/// 快照的"怎么取、怎么并"由调用方注入,本类只管传输:这样单测可以在内存表上跑完整协议,
/// 不必起应用容器。整份快照先算 SHA-256 再校验,半截数据不会进 `apply`。
final class LanSyncSession {
    typealias BuildSnapshot = () async throws -> String
    typealias ApplySnapshot = (String) async throws -> [Int]
    typealias Confirm = (_ peerName: String, _ code: String) async -> Bool
    typealias Stage = (_ peerName: String, _ stage: LanSyncStage, _ percent: Int) async -> Void

    private let identity: LanSyncIdentity.Material
    private let channel: LanSyncChannel
    private let initiator: Bool
    private let buildSnapshot: BuildSnapshot
    private let applySnapshot: ApplySnapshot
    private let confirm: Confirm
    private let stage: Stage

    private var peerName = ""

    init(
        identity: LanSyncIdentity.Material,
        connection: NWConnection,
        initiator: Bool,
        buildSnapshot: @escaping BuildSnapshot,
        applySnapshot: @escaping ApplySnapshot,
        confirm: @escaping Confirm,
        stage: @escaping Stage
    ) {
        self.identity = identity
        self.channel = LanSyncChannel(connection)
        self.initiator = initiator
        self.buildSnapshot = buildSnapshot
        self.applySnapshot = applySnapshot
        self.confirm = confirm
        self.stage = stage
    }

    func run() async throws -> LanSyncResult {
        try await channel.start(timeout: 6)
        let shared = try await greet()
        let code = LanSyncCrypto.sasCode(shared: shared)
        Log.i("LanSync.Session", "配对开始 peer=\(peerName) initiator=\(initiator) code=\(code)")
        let accepted = await confirm(peerName, code)
        if !accepted {
            try? await channel.send(["t": "cancel"])
            throw LanSyncException(.cancelled, "本机取消")
        }
        try await channel.send(["t": "confirm"])
        _ = try await expect("confirm")

        let result = initiator ? try await runInitiator() : try await runResponder()
        Log.i("LanSync.Session", "同步完成 peer=\(peerName) added subs=\(result.subscriptions) favs=\(result.favorites) stamps=\(result.stamps) notes=\(result.notes) history=\(result.history) stats=\(result.stats)")
        return result
    }

    func close() {
        channel.close()
    }

    // MARK: - 握手

    private func greet() async throws -> Data {
        let nonce = LanSyncCrypto.randomBytes(16)
        try await channel.sendPlain([
            "t": "hello",
            "v": LanSyncWire.version,
            "id": identity.deviceId,
            "name": identity.name,
            "pub": LanSyncCrypto.base64(identity.publicKey),
            "nonce": LanSyncCrypto.base64(nonce)
        ])
        let hello: [String: Any]
        do {
            hello = try await channel.receivePlain()
        } catch {
            throw LanSyncException(.io, "没有收到对方的问候", error)
        }
        guard (hello["t"] as? String) == "hello" else {
            throw LanSyncException(.protocolProblem, "对方第一帧不是 hello")
        }
        let remoteVersion = hello["v"] as? Int ?? 0
        guard remoteVersion == LanSyncWire.version else {
            throw LanSyncException(.version, "对方协议版本 \(remoteVersion)")
        }
        // 发现层有时会看见自己(名字冲突时系统还会把服务名改掉,按名字排不掉),这里按设备 id 再挡一次。
        if (hello["id"] as? String) == identity.deviceId {
            throw LanSyncException(.protocolProblem, "对端就是本机")
        }
        guard let pubText = hello["pub"] as? String,
              let peerPub = LanSyncCrypto.unbase64(pubText) else {
            throw LanSyncException(.protocolProblem, "对方公钥不是 base64")
        }
        guard peerPub.count == LanSyncCrypto.publicKeyBytes else {
            throw LanSyncException(.protocolProblem, "对方公钥长度 \(peerPub.count)")
        }
        guard let nonceText = hello["nonce"] as? String,
              let peerNonce = LanSyncCrypto.unbase64(nonceText) else {
            throw LanSyncException(.protocolProblem, "对方 nonce 不是 base64")
        }
        guard peerNonce.count == 16 else {
            throw LanSyncException(.protocolProblem, "对方 nonce 长度 \(peerNonce.count)")
        }
        let clientNonce = initiator ? nonce : peerNonce
        let serverNonce = initiator ? peerNonce : nonce
        let shared = try LanSyncCrypto.sharedSecret(identity.privateKey, peerPublicKeyRaw: peerPub)
        channel.useKey(LanSyncCrypto.sessionKey(shared: shared, clientNonce: clientNonce, serverNonce: serverNonce))
        let raw = (hello["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        peerName = String(raw.prefix(64)).isEmpty ? "设备" : String(raw.prefix(64))
        return shared
    }

    // MARK: - 两程

    private func runInitiator() async throws -> LanSyncResult {
        try await channel.send(["t": "request"])
        await stage(peerName, .receiving, 0)
        let remote = try await receiveSnapshot { [weak self] p in
            guard let self else { return }
            await self.stage(self.peerName, .receiving, p)
        }
        await stage(peerName, .merging, 0)
        let added = try await applySnapshot(remote)
        await stage(peerName, .sending, 0)
        try await sendSnapshot { [weak self] p in
            guard let self else { return }
            await self.stage(self.peerName, .sending, p)
        }
        _ = try await expect("ack")
        return result(added)
    }

    private func runResponder() async throws -> LanSyncResult {
        _ = try await expect("request")
        try await sendSnapshot { [weak self] p in
            guard let self else { return }
            await self.stage(self.peerName, .sending, p)
        }
        await stage(peerName, .receiving, 0)
        let merged = try await receiveSnapshot { [weak self] p in
            guard let self else { return }
            await self.stage(self.peerName, .receiving, p)
        }
        await stage(peerName, .merging, 0)
        let added = try await applySnapshot(merged)
        try await channel.send(["t": "ack"])
        return result(added)
    }

    // MARK: - 快照

    private func sendSnapshot(progress: @escaping @Sendable (Int) async -> Void) async throws {
        let data = Data(try await buildSnapshot().utf8)
        guard data.count <= LanSyncWire.maxSnapshot else {
            throw LanSyncException(.protocolProblem, "本机快照 \(data.count) 字节,超过上限")
        }
        let chunk = LanSyncWire.chunkBytes
        let chunks = max(1, (data.count + chunk - 1) / chunk)
        try await channel.send([
            "t": "offer",
            "size": data.count,
            "chunks": chunks,
            "sha256": LanSyncCrypto.base64(LanSyncCrypto.sha256(data))
        ])
        for i in 0..<chunks {
            let from = i * chunk
            let to = min(data.count, from + chunk)
            let piece = data.subdata(in: from..<to)
            try await channel.send(["t": "chunk", "i": i, "d": LanSyncCrypto.base64(piece)])
            if i % 8 == 0 { await progress((i + 1) * 100 / chunks) }
        }
    }

    private func receiveSnapshot(progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        let offer = try await expect("offer")
        let size = offer["size"] as? Int ?? -1
        let chunks = offer["chunks"] as? Int ?? -1
        guard size >= 0 && size <= LanSyncWire.maxSnapshot else {
            throw LanSyncException(.protocolProblem, "对方快照大小 \(size) 不合法")
        }
        guard chunks >= 1 && chunks <= LanSyncWire.maxSnapshot / LanSyncWire.chunkBytes + 1 else {
            throw LanSyncException(.protocolProblem, "对方分块数 \(chunks) 不合法")
        }
        var out = Data()
        out.reserveCapacity(size)
        for i in 0..<chunks {
            let frame = try await expect("chunk")
            guard (frame["i"] as? Int) == i else {
                throw LanSyncException(.protocolProblem, "分块顺序错乱:期待 \(i),收到 \(frame["i"] as? Int ?? -1)")
            }
            guard let text = frame["d"] as? String, let piece = LanSyncCrypto.unbase64(text) else {
                throw LanSyncException(.protocolProblem, "分块不是 base64")
            }
            out.append(piece)
            if out.count > LanSyncWire.maxSnapshot {
                throw LanSyncException(.protocolProblem, "对方发来的数据超过上限")
            }
            if i % 8 == 0 { await progress((i + 1) * 100 / chunks) }
        }
        guard out.count == size else {
            throw LanSyncException(.protocolProblem, "收到 \(out.count) 字节,对方声明 \(size)")
        }
        guard let expectedText = offer["sha256"] as? String,
              let expected = LanSyncCrypto.unbase64(expectedText) else {
            throw LanSyncException(.protocolProblem, "校验值不是 base64")
        }
        guard expected == LanSyncCrypto.sha256(out) else {
            throw LanSyncException(.protocolProblem, "快照校验值不一致")
        }
        guard let text = String(data: out, encoding: .utf8) else {
            throw LanSyncException(.protocolProblem, "快照不是 UTF-8")
        }
        return text
    }

    private func expect(_ type: String) async throws -> [String: Any] {
        let frame: [String: Any]
        do {
            frame = try await channel.receive()
        } catch let e as LanSyncException {
            throw e
        } catch {
            throw LanSyncException(.io, "等待对端失败", error)
        }
        let t = frame["t"] as? String ?? ""
        if t == "cancel" { throw LanSyncException(.peerCancelled, "对端取消") }
        guard t == type else {
            throw LanSyncException(.protocolProblem, "期待 \(type),收到 \(t)")
        }
        return frame
    }

    private func result(_ added: [Int]) -> LanSyncResult {
        func at(_ i: Int) -> Int { i < added.count ? added[i] : 0 }
        return LanSyncResult(
            peerName: peerName,
            subscriptions: at(0),
            favorites: at(1),
            stamps: at(2),
            notes: at(3),
            history: at(4),
            stats: at(5)
        )
    }
}
