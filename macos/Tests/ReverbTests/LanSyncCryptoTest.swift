private func lanHex(_ text: String) -> Data {
    var out = Data()
    var i = text.startIndex
    while i < text.endIndex {
        let j = text.index(i, offsetBy: 2)
        out.append(UInt8(text[i..<j], radix: 16)!)
        i = j
    }
    return out
}

import XCTest
import CryptoKit
@testable import Reverb

/// 局域网同步密码学底座的**已知答案测试**(Apple 侧)。
///
/// 期望值与 Android `LanSyncCryptoTest.kt` **逐条相同**,来源是一份独立的 Node.js / OpenSSL
/// 实现(标准 P-256 + HKDF-SHA256 + AES-256-GCM),不是从本实现自己打印出来抄回去的 ——
/// 否则"输出什么就断言什么"永远绿,跨端契约却可能从一开始就是错的。
///
/// 任何一条断言变红,先查字节口径(公钥 65 字节未压缩点 / SHA-256 拼接顺序 / info 字符串),
/// 别改期望值。
final class LanSyncCryptoTest: XCTestCase {

    // ---- 固定向量(与 Android 那份同一组) ----
    private let alicePriv = lanHex("2bd806c97f0e00af1a1fc3328fa763a9269723c8db8fac4f93af71db186d6e90")
    private let alicePub = lanHex(
        "04081fbae3d40d1109c27a370a02855eaf2b2846ffbbe336e801c61a7117b873159bc7ab938787d5e2c64458a8aed752"
        + "cbf455d38a9d2d4be17e10181fc197f6a0"
    )
    private let bobPriv = lanHex("81b637d8fcd2c6da6359e6963113a1170de795e4b725b84d1e0b4cfd9ec58ce9")
    private let bobPub = lanHex(
        "04aa0f860cbbd91f4542455489f1cc374b60aeb1775335daa886c5805544439a86471e0af8478a3016fd006071936c"
        + "db296141c1af1b2fc005b91b23882daaac5f"
    )
    private let expectedShared = lanHex("6fc4941ebb7fcd045823cdd727b75d249338b3f9c28cd0eab0a710429f8dc82a")
    private let clientNonce = lanHex("00112233445566778899aabbccddeeff")
    private let serverNonce = lanHex("ffeeddccbbaa99887766554433221100")
    private let expectedSalt = lanHex("ef49150b2c15cdf7c6db8f653111a7d9651c58dab66ade314aee2a3d7a3c85d3")
    private let expectedSessionKey = lanHex("d42e60c0e11b4d66ca0ffa697e96b46dbc09cac02b977371214b56ec1fabbe9e")
    private let expectedSasBytes = lanHex("a8d07d91")
    private let gcmNonce = lanHex("0f0e0d0c0b0a090807060504")
    private let plaintext = Data(#"{"type":"auth","deviceId":"alice"}"#.utf8)
    private let expectedCiphertextAndTag = lanHex(
        "262d7a57ea6c9d93b823938281090a827a677e61166e84e0ab33095a83b5ed263d13"
        + "d15e397171ef7ff7301a11efd88714ef"
    )

    func testPublicKeyIs65ByteUncompressedPoint() throws {
        let alice = try P256.KeyAgreement.PrivateKey(rawRepresentation: alicePriv)
        XCTAssertEqual(LanSyncCrypto.encodePublicKey(alice.publicKey), alicePub)
        let decoded = try LanSyncCrypto.decodePublicKey(alicePub)
        XCTAssertEqual(LanSyncCrypto.encodePublicKey(decoded), alicePub)
    }

    func testECDHSharedSecretAndSessionKeyMatchKnownVector() throws {
        let alice = try P256.KeyAgreement.PrivateKey(rawRepresentation: alicePriv)
        let bob = try P256.KeyAgreement.PrivateKey(rawRepresentation: bobPriv)
        let shared = try LanSyncCrypto.sharedSecret(alice, peerPublicKeyRaw: bobPub)
        XCTAssertEqual(shared, expectedShared)
        XCTAssertEqual(LanSyncCrypto.sha256(clientNonce + serverNonce), expectedSalt)
        let key = LanSyncCrypto.sessionKey(shared: shared, clientNonce: clientNonce, serverNonce: serverNonce)
        XCTAssertEqual(key, expectedSessionKey)

        // 反向也算一次:两端算出的共享密钥必须相同,否则会话密钥会不同、配对码也会不同。
        let reverse = try LanSyncCrypto.sharedSecret(bob, peerPublicKeyRaw: alicePub)
        XCTAssertEqual(reverse, expectedShared)
    }

    func testSasCodeMatchesKnownVector() {
        let sasBytes = LanSyncCrypto.hkdf(
            ikm: expectedShared,
            salt: Data(count: 32),
            info: Data("reverb-sas".utf8),
            length: 4
        )
        XCTAssertEqual(sasBytes, expectedSasBytes)
        XCTAssertEqual(LanSyncCrypto.sasCode(shared: expectedShared), "235921")
    }

    func testAESGCMAppendsTagToCiphertext() throws {
        let sealed = try LanSyncCrypto.encrypt(key: expectedSessionKey, nonce: gcmNonce, plaintext: plaintext)
        XCTAssertEqual(sealed, expectedCiphertextAndTag)
        XCTAssertEqual(try LanSyncCrypto.decrypt(key: expectedSessionKey, nonce: gcmNonce, ciphertextAndTag: sealed), plaintext)
    }

    func testTamperedCiphertextFailsDecryption() throws {
        let sealed = try LanSyncCrypto.encrypt(key: expectedSessionKey, nonce: gcmNonce, plaintext: plaintext)
        // 不要直接 `sealed[0] ^= 1`:macOS 27 / Xcode 27 上,对 CryptoKit 返回的 Data 做下标赋值
        // 会 **EXC_BREAKPOINT**(索引基址不是零,Data 的 subscript 在越界分支里 trap)。
        // 先转成数组再改,是这条测试唯一可靠的做法(2026-11-11 实测)。
        var bytes = [UInt8](sealed)
        bytes[0] ^= 1
        XCTAssertThrowsError(try LanSyncCrypto.decrypt(key: expectedSessionKey, nonce: gcmNonce, ciphertextAndTag: Data(bytes)))
    }

    func testRandomKeysAgreeAndPrivateKeyRoundTrips() throws {
        let a = LanSyncCrypto.generatePrivateKey()
        let b = LanSyncCrypto.generatePrivateKey()
        let aRaw = LanSyncCrypto.encodePublicKey(a.publicKey)
        let bRaw = LanSyncCrypto.encodePublicKey(b.publicKey)
        XCTAssertEqual(aRaw.count, LanSyncCrypto.publicKeyBytes)
        let ab = try LanSyncCrypto.sharedSecret(a, peerPublicKeyRaw: bRaw)
        let ba = try LanSyncCrypto.sharedSecret(b, peerPublicKeyRaw: aRaw)
        XCTAssertEqual(ab.count, 32)
        XCTAssertEqual(ab, ba)
        // 私钥落盘再读回还能用:身份是跨启动复用的,每次启动换密钥会让已配对记录全失效。
        let restored = try LanSyncCrypto.decodePrivateKey(a.rawRepresentation)
        XCTAssertEqual(try LanSyncCrypto.sharedSecret(restored, peerPublicKeyRaw: bRaw), ab)
    }

    func testHKDFSupportsArbitraryLengthsDeterministically() {
        for len in [1, 16, 32, 48, 64] {
            let one = LanSyncCrypto.hkdf(ikm: expectedShared, salt: expectedSalt, info: Data("reverb-lan-v1".utf8), length: len)
            let two = LanSyncCrypto.hkdf(ikm: expectedShared, salt: expectedSalt, info: Data("reverb-lan-v1".utf8), length: len)
            XCTAssertEqual(one.count, len)
            XCTAssertEqual(one, two)
        }
    }

    func testBase64URLRoundTripWithoutPadding() {
        let bytes = LanSyncCrypto.randomBytes(65)
        let text = LanSyncCrypto.base64(bytes)
        XCTAssertFalse(text.contains("="))
        XCTAssertEqual(LanSyncCrypto.unbase64(text), bytes)
    }

    func testSasIsUnsigned() {
        // Android 曾在这里踩过有符号溢出的坑:高位为 1 时 `%` 出负数。
        // 这组向量的首字节 0xa8(最高位为 1)正好覆盖那个分支。
        XCTAssertEqual(LanSyncCrypto.sasCode(shared: expectedShared), "235921")
        XCTAssertGreaterThanOrEqual(Int(LanSyncCrypto.sasCode(shared: expectedShared))!, 0)
    }

}
