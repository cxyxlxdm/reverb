import Foundation

#if os(iOS)
import UIKit
#endif

/// 本机在局域网里的**长期身份**:只有一串设备 id 与显示名。
///
/// 与 Android `LanSyncIdentity.kt` 同一个形状,但**文件格式不跨端**:它只在本机读写,
/// 从不进备份、不上传、不写日志。
///
/// ⚠️ **这里不存密钥**。旧版本曾把一对长期 P-256 密钥也写进来并直接拿去做 ECDH,
/// 结果同一对设备每次配对的六位码都一样、也没有前向保密(H278)。现在密钥对在
/// **每次会话里现生成**(见 `LanSyncSession.greet`),身份只负责"我是谁"。
/// 旧文件里多出来的 publicKey/privateKey 会被忽略,下次写入时自然消失。
///
/// 设备 id 要跨启动稳定,否则同一台机器每次打开同步都换一个名字,对端列表里会出现一串
/// "幽灵设备"。文件放在 `AppSupport.dir`(与其它 store 同目录),失败时按"没有身份"重建。
final class LanSyncIdentity {
    struct Material {
        let deviceId: String
        let name: String
        let createdAt: Date
    }

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
        let id = LanSyncCrypto.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        let m = Material(
            deviceId: id,
            name: defaultName(),
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
              id.count == 16 else {
            return nil
        }
        let name = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let created = (o["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        return Material(
            deviceId: id,
            name: name.isEmpty ? defaultName() : name,
            createdAt: created
        )
    }

    private func persist(_ m: Material) {
        let o: [String: Any] = [
            "version": 1,
            "deviceId": m.deviceId,
            "name": m.name,
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
