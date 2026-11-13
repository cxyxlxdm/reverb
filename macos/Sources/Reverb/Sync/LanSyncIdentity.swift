import Foundation
import CryptoKit

#if os(iOS)
import UIKit
#endif

/// 本机在局域网里的**长期身份**:一串设备 id + 一对 P-256 密钥。
///
/// 与 Android `LanSyncIdentity.kt` 同一个形状,但**文件格式不跨端**:它只在本机读写,
/// 从不进备份、不上传、不写日志。私钥丢了没有任何别处能补 —— 代价只是旧的配对记录失效,
/// 而 P0 本来就不持久化配对记录。
///
/// 设备 id 要跨启动稳定,否则同一台机器每次打开同步都换一个名字,对端列表里会出现一串
/// "幽灵设备"。文件放在 `AppSupport.dir`(与其它 store 同目录),失败时按"没有身份"重建。
final class LanSyncIdentity {
    struct Material {
        let deviceId: String
        let name: String
        let publicKey: Data
        let privateKey: P256PrivateKey
        let createdAt: Date
    }

    /// 只为了避免在共享代码里写很长的 CryptoKit 泛型名;类型本身仍是 CryptoKit 的。
    typealias P256PrivateKey = P256.KeyAgreement.PrivateKey

    private let file = AppSupport.dir.appendingPathComponent("lan_sync.json")
    private let lock = NSLock()
    private var cached: Material?

    var material: Material {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let m = loadOrCreate()
        cached = m
        return m
    }

    private func loadOrCreate() -> Material {
        if let m = read() { return m }
        let key = LanSyncCrypto.generatePrivateKey()
        let id = LanSyncCrypto.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        let m = Material(
            deviceId: id,
            name: defaultName(),
            publicKey: LanSyncCrypto.encodePublicKey(key.publicKey),
            privateKey: key,
            createdAt: Date()
        )
        persist(m)
        Log.i("LanSync.Identity", "生成新的同步身份 id=\(m.deviceId) name=\(m.name)")
        return m
    }

    private func read() -> Material? {
        guard let data = try? Data(contentsOf: file),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["version"] as? Int) == 1,
              let id = o["deviceId"] as? String,
              id.count == 16,
              let pub = (o["publicKey"] as? String).flatMap(LanSyncCrypto.unbase64),
              let priv = (o["privateKey"] as? String).flatMap(LanSyncCrypto.unbase64),
              priv.count == 32,
              pub.count == LanSyncCrypto.publicKeyBytes else {
            return nil
        }
        guard let key = try? LanSyncCrypto.decodePrivateKey(priv) else { return nil }
        let name = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let created = (o["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        return Material(
            deviceId: id,
            name: name.isEmpty ? defaultName() : name,
            publicKey: pub,
            privateKey: key,
            createdAt: created
        )
    }

    private func persist(_ m: Material) {
        let o: [String: Any] = [
            "version": 1,
            "deviceId": m.deviceId,
            "name": m.name,
            "publicKey": LanSyncCrypto.base64(m.publicKey),
            "privateKey": LanSyncCrypto.base64(m.privateKey.rawRepresentation),
            "createdAt": m.createdAt.timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) else { return }
        // `.atomic` 先写临时文件再 rename —— 与 Android 的 writeAtomically 同一个意图:
        // 半截文件宁可当"没有身份"重建,也不要留在那儿。
        try? data.write(to: file, options: .atomic)
    }

    private func defaultName() -> String {
        #if os(iOS)
        let n = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "iPhone" : n
        #else
        if let host = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host
        }
        let n = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Mac" : n
        #endif
    }
}
