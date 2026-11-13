package com.yuyin.reverb.sync

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 局域网同步的密码学底座。
 *
 * 只使用 JVM / Android 自带的 EC、ECDH、HMAC-SHA256、HKDF、AES-GCM —— 不引任何三方库,
 * 也不依赖平台证书体系。跨端契约是**字节级**的,和 Swift / 鸿蒙实现逐项对齐:
 *
 * - 公钥:`0x04 || X(32) || Y(32)` 的 P-256 未压缩点(65 字节),不是 X.509;
 * - 共享密钥:ECDH P-256 的 X 坐标(32 字节);
 * - 会话密钥:HKDF-SHA256(共享密钥, salt=SHA256(clientNonce||serverNonce), info="reverb-lan-v1", 32);
 * - 配对码:HKDF-SHA256(共享密钥, salt=32 个 0, info="reverb-sas", 4) 取大端整数 % 1_000_000;
 * - AES-GCM:12 字节随机 nonce,16 字节 tag,密文与 tag 拼接后整段传输。
 *
 * 这些常量不是"随手定的":改任何一个都会让四端互相解不开,而且**不会报错**,
 * 只会表现为"配对码不一致 / 收到的都是乱码"。测试向量见 `LanSyncCryptoTest`。
 */
object LanSyncCrypto {
    const val PUBLIC_KEY_BYTES = 65
    const val NONCE_BYTES = 12
    const val TAG_BITS = 128
    const val SESSION_KEY_BYTES = 32

    private const val CURVE = "secp256r1"

    private val random = SecureRandom()

    /** P-256 参数。只取一次 —— `AlgorithmParameters` 每次实例化都要走一遍 SPI。 */
    private val ecParams: ECParameterSpec by lazy {
        val p = AlgorithmParameters.getInstance("EC")
        p.init(ECGenParameterSpec(CURVE))
        p.getParameterSpec(ECParameterSpec::class.java)
    }

    fun generateKeyPair(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec(CURVE), random)
        return kpg.generateKeyPair()
    }

    /** 私钥的 PKCS#8 编码;落盘时再套一层 Base64。 */
    fun encodePrivateKey(key: PrivateKey): ByteArray = key.encoded

    fun decodePrivateKey(pkcs8: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(pkcs8))

    /**
     * 公钥只导出成 **65 字节未压缩点**。
     *
     * 不要用 `publicKey.encoded`(X.509 SubjectPublicKeyInfo):它带着算法标识与长度前缀,
     * Swift 的 `P256.KeyAgreement.PublicKey(rawRepresentation:)` 不认;反过来 Swift 交来的
     * 65 字节,X.509 解析器也不认。这是本轮最容易在"两端都能跑、但就是连不上"里踩的坑。
     */
    fun encodePublicKey(key: PublicKey): ByteArray {
        val ec = key as ECPublicKey
        val out = ByteArray(PUBLIC_KEY_BYTES)
        out[0] = 0x04
        ec.w.affineX.toFixed(32).copyInto(out, 1)
        ec.w.affineY.toFixed(32).copyInto(out, 33)
        return out
    }

    fun decodePublicKey(raw: ByteArray): ECPublicKey {
        require(raw.size == PUBLIC_KEY_BYTES && raw[0] == 0x04.toByte()) {
            "P-256 公钥必须是 65 字节未压缩点"
        }
        val x = BigInteger(1, raw.copyOfRange(1, 33))
        val y = BigInteger(1, raw.copyOfRange(33, 65))
        return KeyFactory.getInstance("EC")
            .generatePublic(ECPublicKeySpec(ECPoint(x, y), ecParams)) as ECPublicKey
    }

    /** ECDH。返回 32 字节 X 坐标。 */
    fun sharedSecret(privateKey: PrivateKey, peerPublicKeyRaw: ByteArray): ByteArray {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(privateKey)
        agreement.doPhase(decodePublicKey(peerPublicKeyRaw), true)
        return agreement.generateSecret()
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray?, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt ?: ByteArray(32), ikm)
        val okm = ByteArray(length)
        var t = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val take = minOf(t.size, length - offset)
            t.copyInto(okm, offset, 0, take)
            offset += take
            counter++
            check(counter <= 255) { "HKDF 输出过长" }
        }
        return okm
    }

    fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)

    fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun sessionKey(shared: ByteArray, clientNonce: ByteArray, serverNonce: ByteArray): ByteArray =
        hkdf(
            ikm = shared,
            salt = sha256(clientNonce + serverNonce),
            info = "reverb-lan-v1".toByteArray(Charsets.UTF_8),
            length = SESSION_KEY_BYTES
        )

    /** 六位配对码。两端各自算,不经过网络传输 —— 传的是"我算出来是多少"的证明,不是码本身。 */
    fun sasCode(shared: ByteArray): String {
        val b = hkdf(
            ikm = shared,
            salt = ByteArray(32),
            info = "reverb-sas".toByteArray(Charsets.UTF_8),
            length = 4
        )
        // **必须按无符号 32 位算**:`Int` 的 `shl 24` 在高位为 1 时是负数,
        // `% 1_000_000` 会给出负码(-731375 这种),而 Swift / ArkTS 那边用的是无符号。
        // 这个错不会抛任何异常,只会让两端屏幕上的六位数对不上 —— 测试向量抓过一次。
        val n = ((b[0].toLong() and 0xff) shl 24) or
            ((b[1].toLong() and 0xff) shl 16) or
            ((b[2].toLong() and 0xff) shl 8) or
            (b[3].toLong() and 0xff)
        return "%06d".format(n % 1_000_000)
    }

    /** 加密结果 = ciphertext || tag。AES-GCM 的 tag 已在 `doFinal` 尾部。 */
    fun encrypt(key: ByteArray, nonce: ByteArray, plaintext: ByteArray): ByteArray {
        require(nonce.size == NONCE_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        return cipher.doFinal(plaintext)
    }

    fun decrypt(key: ByteArray, nonce: ByteArray, ciphertextAndTag: ByteArray): ByteArray {
        require(nonce.size == NONCE_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        return cipher.doFinal(ciphertextAndTag)
    }

    fun randomBytes(size: Int): ByteArray = ByteArray(size).also { random.nextBytes(it) }

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    fun base64(bytes: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    fun unbase64(text: String): ByteArray = Base64.getUrlDecoder().decode(text)

    private fun BigInteger.toFixed(size: Int): ByteArray {
        val b = toByteArray()
        return when {
            b.size == size -> b
            b.size == size + 1 && b[0] == 0.toByte() -> b.copyOfRange(1, b.size)
            b.size < size -> ByteArray(size).also { b.copyInto(it, size - b.size) }
            else -> b.copyOfRange(b.size - size, b.size)
        }
    }
}
