package com.yuyin.reverb.sync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec

/**
 * 局域网同步密码学底座的**已知答案测试**。
 *
 * 这里的每条期望值都由一份独立的 Node.js / OpenSSL 实现算出(脚本用的就是标准
 * P-256 + HKDF-SHA256 + AES-256-GCM),不是从本实现自己打印出来抄回去的 ——
 * 否则"输出什么就断言什么"永远绿,跨端契约却可能从一开始就是错的。
 *
 * 四端逐字节对齐的就是这些常量。任何一条断言变红,先查字节口径(公钥 65 字节未压缩点 /
 * SHA-256 拼接顺序 / info 字符串),别改期望值。
 */
class LanSyncCryptoTest {

    // ---- 固定向量(来源:Node 26 / OpenSSL 的标准实现) ----
    private val alicePriv = hex("2bd806c97f0e00af1a1fc3328fa763a9269723c8db8fac4f93af71db186d6e90")
    private val alicePub = hex(
        "04081fbae3d40d1109c27a370a02855eaf2b2846ffbbe336e801c61a7117b873159bc7ab938787d5e2c64458a8aed752" +
            "cbf455d38a9d2d4be17e10181fc197f6a0"
    )
    private val bobPriv = hex("81b637d8fcd2c6da6359e6963113a1170de795e4b725b84d1e0b4cfd9ec58ce9")
    private val bobPub = hex(
        "04aa0f860cbbd91f4542455489f1cc374b60aeb1775335daa886c5805544439a86471e0af8478a3016fd006071936c" +
            "db296141c1af1b2fc005b91b23882daaac5f"
    )
    private val expectedShared = hex("6fc4941ebb7fcd045823cdd727b75d249338b3f9c28cd0eab0a710429f8dc82a")
    private val clientNonce = hex("00112233445566778899aabbccddeeff")
    private val serverNonce = hex("ffeeddccbbaa99887766554433221100")
    private val expectedSalt = hex("ef49150b2c15cdf7c6db8f653111a7d9651c58dab66ade314aee2a3d7a3c85d3")
    private val expectedSessionKey = hex("d42e60c0e11b4d66ca0ffa697e96b46dbc09cac02b977371214b56ec1fabbe9e")
    private val expectedSasBytes = hex("a8d07d91")
    private val gcmNonce = hex("0f0e0d0c0b0a090807060504")
    private val plaintext = "{\"type\":\"auth\",\"deviceId\":\"alice\"}".toByteArray()
    private val expectedCiphertextAndTag = hex(
        "262d7a57ea6c9d93b823938281090a827a677e61166e84e0ab33095a83b5ed263d13" +
            "d15e397171ef7ff7301a11efd88714ef"
    )

    @Test
    fun `公钥导出为 65 字节未压缩点并可往返`() {
        val pub = LanSyncCrypto.decodePublicKey(alicePub)
        assertArrayEquals(alicePub, LanSyncCrypto.encodePublicKey(pub))
        // 另一端交来的也必须能直接解成同一个点。
        assertArrayEquals(alicePub, LanSyncCrypto.encodePublicKey(LanSyncCrypto.decodePublicKey(alicePub)))
    }

    @Test
    fun `固定向量：ECDH 共享密钥与会话密钥`() {
        val shared = LanSyncCrypto.sharedSecret(privateKey(alicePriv, alicePub), bobPub)
        assertArrayEquals(expectedShared, shared)
        assertArrayEquals(expectedSalt, LanSyncCrypto.sha256(clientNonce + serverNonce))
        val key = LanSyncCrypto.sessionKey(shared, clientNonce, serverNonce)
        assertArrayEquals(expectedSessionKey, key)

        // 反向也算一次:两端算出的共享密钥必须相同,否则会话密钥会不同、配对码也会不同。
        val reverse = LanSyncCrypto.sharedSecret(privateKey(bobPriv, bobPub), alicePub)
        assertArrayEquals(expectedShared, reverse)
    }

    @Test
    fun `固定向量：六位配对码`() {
        val sasBytes = LanSyncCrypto.hkdf(
            ikm = expectedShared,
            salt = ByteArray(32),
            info = "reverb-sas".toByteArray(Charsets.UTF_8),
            length = 4
        )
        assertArrayEquals(expectedSasBytes, sasBytes)
        assertEquals("235921", LanSyncCrypto.sasCode(expectedShared))
    }

    @Test
    fun `固定向量：AES-256-GCM 密文与 tag 拼接`() {
        val sealed = LanSyncCrypto.encrypt(expectedSessionKey, gcmNonce, plaintext)
        assertArrayEquals(expectedCiphertextAndTag, sealed)
        // 末 16 字节是 tag;解密取回原文。
        assertArrayEquals(plaintext, LanSyncCrypto.decrypt(expectedSessionKey, gcmNonce, sealed))
    }

    @Test
    fun `篡改密文必须解密失败`() {
        val sealed = LanSyncCrypto.encrypt(expectedSessionKey, gcmNonce, plaintext)
        sealed[0] = (sealed[0].toInt() xor 1).toByte()
        assertThrows(Exception::class.java) {
            LanSyncCrypto.decrypt(expectedSessionKey, gcmNonce, sealed)
        }
    }

    @Test
    fun `随机密钥对两端算出的共享密钥一致`() {
        val a = LanSyncCrypto.generateKeyPair()
        val b = LanSyncCrypto.generateKeyPair()
        val aRaw = LanSyncCrypto.encodePublicKey(a.public)
        val bRaw = LanSyncCrypto.encodePublicKey(b.public)
        assertEquals(LanSyncCrypto.PUBLIC_KEY_BYTES, aRaw.size)
        val ab = LanSyncCrypto.sharedSecret(a.private, bRaw)
        val ba = LanSyncCrypto.sharedSecret(b.private, aRaw)
        assertEquals(32, ab.size)
        assertArrayEquals(ab, ba)
    }

    @Test
    fun `HKDF 支持任意长度且同输入同输出`() {
        for (len in intArrayOf(1, 16, 32, 48, 64)) {
            val one = LanSyncCrypto.hkdf(expectedShared, expectedSalt, "reverb-lan-v1".toByteArray(), len)
            val two = LanSyncCrypto.hkdf(expectedShared, expectedSalt, "reverb-lan-v1".toByteArray(), len)
            assertEquals(len, one.size)
            assertArrayEquals(one, two)
        }
    }

    @Test
    fun `Base64URL 无填充往返`() {
        val bytes = LanSyncCrypto.randomBytes(65)
        val text = LanSyncCrypto.base64(bytes)
        assertEquals(false, text.contains('='))
        assertArrayEquals(bytes, LanSyncCrypto.unbase64(text))
    }

    // ---- 工具 ----

    private fun hex(text: String): ByteArray =
        text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    /**
     * 用固定向量里的 32 字节标量构造 `PrivateKey`。
     *
     * JVM 的 EC KeyFactory 只收 PKCS#8,而跨端契约里传的是裸标量 / 裸点 —— 所以这里
     * 手搭一层 DER 外壳。**只出现在测试里**:生产侧私钥一直是 PKCS#8 落盘。
     */
    private fun privateKey(scalar: ByteArray, publicPoint: ByteArray): PrivateKey {
        fun len(n: Int): ByteArray = when {
            n < 0x80 -> byteArrayOf(n.toByte())
            n < 0x100 -> byteArrayOf(0x81.toByte(), n.toByte())
            else -> byteArrayOf(0x82.toByte(), (n shr 8).toByte(), n.toByte())
        }
        fun tlv(tag: Int, body: ByteArray): ByteArray =
            byteArrayOf(tag.toByte()) + len(body.size) + body

        val sec1 = tlv(
            0x30,
            tlv(0x02, byteArrayOf(1)) +
                tlv(0x04, scalar) +
                // [1] 显式带上公钥点:部分提供方会拿它做一致性校验。
                tlv(0xA1, tlv(0x03, byteArrayOf(0) + publicPoint))
        )
        val ecPublicKeyOid = tlv(0x06, hex("2a8648ce3d0201"))
        val prime256v1Oid = tlv(0x06, hex("2a8648ce3d030107"))
        val der = tlv(0x30, tlv(0x02, byteArrayOf(0)) + tlv(0x30, ecPublicKeyOid + prime256v1Oid) + tlv(0x04, sec1))
        return KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(der))
    }
}
