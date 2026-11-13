import Foundation
import Network

/// 同步失败的可展示分类。UI 把它映射成文案,不把底层错误原文直接摆给用户。
enum LanSyncFail: Equatable {
    case connect
    case version
    case protocolProblem
    case decrypt
    case io
    case cancelled
    case peerCancelled
}

struct LanSyncException: LocalizedError {
    let fail: LanSyncFail
    let message: String
    let cause: Error?

    init(_ fail: LanSyncFail, _ message: String, _ cause: Error? = nil) {
        self.fail = fail
        self.message = message
        self.cause = cause
    }

    var errorDescription: String? { message }
}

/// 局域网同步的线格式。四端逐字节一致,改动必须四端同时改:
///
/// - 每一帧 = **4 字节大端长度** + UTF-8 JSON;
/// - JSON 帧最大 8 MiB;数据快照切成 256 KiB 的块,再各自包进一帧;
/// - 握手帧是明文;密钥建立之后所有帧都是密封信封 `{"n":<nonce b64>,"c":<密文+tag b64>}`。
///
/// 为什么用长度前缀而不是换行分隔:密文里什么字节都可能出现(包括 0x0A),文本分隔线在加密层
/// 就不成立。长度前缀对二进制也是同一条读法。
enum LanSyncWire {
    static let version = 1
    static let maxFrame = 8 * 1024 * 1024
    static let chunkBytes = 256 * 1024
    static let maxSnapshot = 64 * 1024 * 1024
}

/// 一条已经建立的 TCP 连接上的帧读写。Network.framework 的异步接口包成"一次一帧"的同步语义。
///
/// 密钥只在 hello 之后装进来(`useKey`)。**装进来之后就不允许再出现明文帧** ——
/// 否则一个中间人可以诱导某一端退回明文。这条判据放在 `receive()` 里,而不是靠调用方自觉。
final class LanSyncChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cn.cxyxl.reverb.lansync.connection")
    private var key: Data?
    private var buffer = Data()
    private var started = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(timeout: TimeInterval) async throws {
        if started { return }
        started = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume()
                case .failed(let error):
                    once.resume(throwing: LanSyncException(.connect, "连接失败", error))
                case .cancelled:
                    once.resume(throwing: LanSyncException(.io, "连接已关闭"))
                case .waiting(let error):
                    // 对端还没起来 / 不可达时 Network.framework 会先给 waiting。
                    // 保留等待,真正的失败交给下面的超时——但在无线网络里它也可能永远不返回。
                    Log.w("LanSync", "连接等待:\(error.localizedDescription)")
                default:
                    break
                }
            }
            // 从 NWListener 拿到的连接可能已经被监听器启动过;再 start 一次会换队列。
            // 也可能在我们挂上 handler 之前就已经 ready —— 那时不会再回调,必须主动补一次。
            if connection.state == .ready {
                once.resume()
            } else if connection.state == .setup {
                connection.start(queue: queue)
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: LanSyncException(.connect, "连接超时"))
            }
        }
    }

    func useKey(_ key: Data) {
        self.key = key
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - 明文 / 密封

    func sendPlain(_ object: [String: Any]) async throws {
        try await writeFrame(try encode(object))
    }

    func receivePlain() async throws -> [String: Any] {
        try decode(try await readFrame(), encrypted: false)
    }

    func send(_ object: [String: Any]) async throws {
        guard let key else {
            throw LanSyncException(.protocolProblem, "还没建立密钥就发了加密帧")
        }
        let nonce = LanSyncCrypto.randomBytes(LanSyncCrypto.nonceBytes)
        let body = try LanSyncCrypto.encrypt(key: key, nonce: nonce, plaintext: try encode(object))
        let envelope: [String: Any] = [
            "n": LanSyncCrypto.base64(nonce),
            "c": LanSyncCrypto.base64(body)
        ]
        try await writeFrame(try encode(envelope))
    }

    func receive() async throws -> [String: Any] {
        guard let key else {
            throw LanSyncException(.protocolProblem, "还没建立密钥就收到了加密帧")
        }
        let frame = try await readFrame()
        guard let envelope = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let n = envelope["n"] as? String,
              let c = envelope["c"] as? String else {
            throw LanSyncException(.protocolProblem, "加密阶段收到了明文帧")
        }
        guard let nonce = LanSyncCrypto.unbase64(n), let body = LanSyncCrypto.unbase64(c) else {
            throw LanSyncException(.protocolProblem, "信封字段不是 base64")
        }
        let plain = try LanSyncCrypto.decrypt(key: key, nonce: nonce, ciphertextAndTag: body)
        return try decode(plain, encrypted: true)
    }

    // MARK: - 帧

    private func encode(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw LanSyncException(.protocolProblem, "帧不是合法 JSON", error)
        }
    }

    private func decode(_ data: Data, encrypted: Bool) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanSyncException(.protocolProblem, "对端发来的不是 JSON 对象")
        }
        return object
    }

    private func writeFrame(_ bytes: Data) async throws {
        guard bytes.count <= LanSyncWire.maxFrame else {
            throw LanSyncException(.protocolProblem, "单帧 \(bytes.count) 字节,超过上限")
        }
        var length = UInt32(bytes.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(bytes)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once(cont)
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    once.resume(throwing: LanSyncException(.io, "发送失败", error))
                } else {
                    once.resume()
                }
            })
        }
    }

    private func readFrame() async throws -> Data {
        let header = [UInt8](try await readExactly(4))
        let size = Int((UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) |
                       (UInt32(header[2]) << 8) | UInt32(header[3]))
        guard size >= 0 && size <= LanSyncWire.maxFrame else {
            throw LanSyncException(.protocolProblem, "对端声明了非法帧长 \(size)")
        }
        return try await readExactly(size)
    }

    private func readExactly(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        while buffer.count < count {
            let more = try await receiveSome(maximum: max(1, count - buffer.count))
            buffer.append(more)
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    private func receiveSome(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once(cont)
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    once.resume(throwing: LanSyncException(.io, "接收失败", error))
                } else if let data, !data.isEmpty {
                    once.resume(returning: data)
                } else if isComplete {
                    once.resume(throwing: LanSyncException(.io, "对端已断开"))
                } else {
                    once.resume(throwing: LanSyncException(.io, "对端没有数据"))
                }
            }
        }
    }
}

/// 把 continuation 包成"只允许结束一次"。超时与网络回调会赛跑,直接 resume 两次会崩。
private final class Once<T> {
    private let lock = NSLock()
    private var finished = false
    private let cont: CheckedContinuation<T, Error>

    init(_ cont: CheckedContinuation<T, Error>) {
        self.cont = cont
    }

    func resume(returning value: T) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        cont.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        cont.resume(throwing: error)
    }
}

private extension Once where T == Void {
    func resume() {
        resume(returning: ())
    }
}
