import Foundation
import CryptoKit
import Security

/// 局域网同步的密码学底座(Apple 侧)。
///
/// 与 Android `LanSyncCrypto.kt` / 鸿蒙那份**逐字节对齐**,这里任何一个常量改动都会让四端
/// 互相解不开,而且**不会报错** —— 只会表现成"配对码不一致 / 收到的都是乱码"。跨端契约:
///
/// - 公钥:`0x04 || X(32) || Y(32)` 的 P-256 未压缩点(65 字节),不是 X.509;
/// - 共享密钥:ECDH P-256 的 X 坐标(32 字节);
/// - 会话密钥:HKDF-SHA256(共享密钥, salt=SHA256(clientNonce||serverNonce), info="reverb-lan-v1", 32);
/// - 配对码:HKDF-SHA256(共享密钥, salt=32 个 0, info="reverb-sas", 4) 取**无符号**大端整数 % 1_000_000;
/// - AES-GCM:12 字节随机 nonce,16 字节 tag,密文与 tag 拼接后整段传输。
///
/// 为什么用 CryptoKit 而不是手搓:ECDH / HKDF / GCM 都是系统实现,满足"不接三方 SDK"这条上游约束;
/// 而 `P256.KeyAgreement.PublicKey.x963Representation` 恰好就是 Android 那边导出的 65 字节,
/// 不用再自己拼坐标。**注意别用 `rawRepresentation` 导私钥后当成"跨端可读"** —— 它只是本机
/// 身份文件里的字段,从不在网络上传输(网络上只传公钥)。
enum LanSyncCrypto {
    static let publicKeyBytes = 65
    static let nonceBytes = 12
    static let tagBits = 128
    static let sessionKeyBytes = 32

    // MARK: - 密钥

    static func generatePrivateKey() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    /// 公钥只导出成 **65 字节未压缩点**。`x963Representation` 在 CryptoKit 里就是这个形状;
    /// 这里仍断言一次前缀与长度 —— 若系统哪天换了编码,宁可当场失败,也不要等到对端解不开。
    static func encodePublicKey(_ key: P256.KeyAgreement.PublicKey) -> Data {
        let data = key.x963Representation
        precondition(data.count == publicKeyBytes && data.first == 0x04, "P-256 公钥必须是 65 字节未压缩点")
        return data
    }

    static func decodePublicKey(_ raw: Data) throws -> P256.KeyAgreement.PublicKey {
        guard raw.count == publicKeyBytes, raw.first == 0x04 else {
            throw LanSyncException(.protocolProblem, "P-256 公钥必须是 65 字节未压缩点")
        }
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: raw)
        } catch {
            throw LanSyncException(.protocolProblem, "P-256 公钥格式不合法", error)
        }
    }

    static func decodePrivateKey(_ raw: Data) throws -> P256.KeyAgreement.PrivateKey {
        do {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        } catch {
            throw LanSyncException(.io, "本机私钥读取失败", error)
        }
    }

    /// ECDH,返回 32 字节 X 坐标。CryptoKit 的 `SharedSecret` 就是这个值(不是带前缀的 KDF 输出)。
    static func sharedSecret(_ privateKey: P256.KeyAgreement.PrivateKey, peerPublicKeyRaw: Data) throws -> Data {
        let peer = try decodePublicKey(peerPublicKeyRaw)
        let secret: SharedSecret
        do {
            secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw LanSyncException(.protocolProblem, "ECDH 失败", error)
        }
        return secret.withUnsafeBytes { Data($0) }
    }

    // MARK: - KDF

    static func hkdf(ikm: Data, salt: Data?, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt ?? Data(count: 32),
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sessionKey(shared: Data, clientNonce: Data, serverNonce: Data) -> Data {
        hkdf(
            ikm: shared,
            salt: sha256(clientNonce + serverNonce),
            info: Data("reverb-lan-v1".utf8),
            length: sessionKeyBytes
        )
    }

    /// 六位配对码。两端各自算,不经过网络传输 —— 传的是"我算出来是多少"的证明,不是码本身。
    ///
    /// **必须按无符号 32 位算**:Android 那边用的是无符号,若这里写成 Int32 / 带符号移位,
    /// 高位为 1 时会得到负数,`%` 出来的码与对端不是一个(Android 已经踩过这个坑)。
    static func sasCode(shared: Data) -> String {
        let b = hkdf(ikm: shared, salt: Data(count: 32), info: Data("reverb-sas".utf8), length: 4)
        let bytes = [UInt8](b)
        let n = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return String(format: "%06d", Int(n % 1_000_000))
    }

    // MARK: - AES-GCM

    /// 加密结果 = ciphertext || tag。AES-GCM 的 tag 不跟着 nonce 走 —— nonce 单独走信封字段。
    static func encrypt(key: Data, nonce: Data, plaintext: Data) throws -> Data {
        guard nonce.count == nonceBytes else {
            throw LanSyncException(.protocolProblem, "nonce 必须是 12 字节")
        }
        do {
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
            return box.ciphertext + box.tag
        } catch {
            throw LanSyncException(.protocolProblem, "加密失败", error)
        }
    }

    static func decrypt(key: Data, nonce: Data, ciphertextAndTag: Data) throws -> Data {
        guard nonce.count == nonceBytes else {
            throw LanSyncException(.protocolProblem, "nonce 必须是 12 字节")
        }
        guard ciphertextAndTag.count >= 16 else {
            throw LanSyncException(.decrypt, "密文短于 tag")
        }
        // 必须复制成独立的 `Data`,不能把 `prefix/suffix` 的切片直接交给 SealedBox:
        // 在 macOS 27 / Xcode 27 实测,切片形式的 ciphertext 会让 CryptoKit **直接 SIGTRAP**,
        // 而不是抛 authenticationFailure(2026-11-11 由"篡改密文必须解密失败"这条测试抓出来)。
        let ct = Data(ciphertextAndTag.prefix(ciphertextAndTag.count - 16))
        let tag = Data(ciphertextAndTag.suffix(16))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw LanSyncException(.decrypt, "密文校验失败", error)
        }
    }

    // MARK: - 工具

    static func randomBytes(_ size: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        let status = SecRandomCopyBytes(kSecRandomDefault, size, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes 失败")
        return Data(bytes)
    }

    static func base64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64(_ text: String) -> Data? {
        var s = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s += String(repeating: "=", count: pad) }
        return Data(base64Encoded: s)
    }
}
