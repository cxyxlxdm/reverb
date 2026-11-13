package com.yuyin.reverb.sync

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.Socket
import java.net.SocketTimeoutException

/** 同步失败的可展示分类。UI 把它映射成文案,不再把异常原文直接摆给用户。 */
enum class LanSyncFail {
    CONNECT, VERSION, PROTOCOL, DECRYPT, IO, CANCELLED, PEER_CANCELLED
}

class LanSyncException(
    val fail: LanSyncFail,
    override val message: String,
    cause: Throwable? = null
) : Exception(message, cause)

/**
 * 局域网同步的线格式。四端逐字节一致,改动必须四端同时改:
 *
 * - 每一帧 = **4 字节大端长度** + UTF-8 JSON;
 * - JSON 帧最大 8 MiB;数据快照切成 256 KiB 的块,再各自包进一帧;
 * - 握手帧是明文;密钥建立之后所有帧都是密封信封 `{"n":<nonce b64>,"c":<密文+tag b64>}`。
 *
 * 为什么用长度前缀而不是换行分隔:密文里什么字节都可能出现(包括 0x0A),文本分隔线在加密层
 * 就不成立。长度前缀对二进制也是同一条读法。
 */
object LanSyncWire {
    const val VERSION = 1
    const val MAX_FRAME = 8 * 1024 * 1024
    const val CHUNK_BYTES = 256 * 1024
    const val MAX_SNAPSHOT = 64 * 1024 * 1024

    fun json(vararg pairs: Pair<String, Any?>): JSONObject {
        val o = JSONObject()
        for ((k, v) in pairs) o.put(k, v)
        return o
    }
}

/**
 * 一条已经建立的 TCP 连接上的帧读写。
 *
 * 密钥只在 hello 之后装进来([useKey])。**装进来之后就不允许再出现明文帧** ——
 * 否则一个中间人可以诱导某一端退回明文。这条判据放在 [receive] 里,而不是靠调用方自觉。
 */
class LanSyncChannel(private val socket: Socket) : Closeable {

    private val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
    private val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))

    @Volatile
    private var key: ByteArray? = null

    fun useKey(key: ByteArray) {
        this.key = key
    }

    fun sendPlain(obj: JSONObject) {
        writeFrame(obj.toString().toByteArray(Charsets.UTF_8))
    }

    fun receivePlain(): JSONObject =
        JSONObject(String(readFrame(), Charsets.UTF_8))

    fun send(obj: JSONObject) {
        val k = key ?: throw LanSyncException(LanSyncFail.PROTOCOL, "还没建立密钥就发了加密帧")
        val nonce = LanSyncCrypto.randomBytes(LanSyncCrypto.NONCE_BYTES)
        val body = LanSyncCrypto.encrypt(k, nonce, obj.toString().toByteArray(Charsets.UTF_8))
        val envelope = LanSyncWire.json(
            "n" to LanSyncCrypto.base64(nonce),
            "c" to LanSyncCrypto.base64(body)
        )
        writeFrame(envelope.toString().toByteArray(Charsets.UTF_8))
    }

    fun receive(): JSONObject {
        val k = key ?: throw LanSyncException(LanSyncFail.PROTOCOL, "还没建立密钥就收到了加密帧")
        val envelope = JSONObject(String(readFrame(), Charsets.UTF_8))
        if (!envelope.has("n") || !envelope.has("c")) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "加密阶段收到了明文帧")
        }
        val nonce = LanSyncCrypto.unbase64(envelope.getString("n"))
        val body = LanSyncCrypto.unbase64(envelope.getString("c"))
        val plain = try {
            LanSyncCrypto.decrypt(k, nonce, body)
        } catch (e: Exception) {
            throw LanSyncException(LanSyncFail.DECRYPT, "密文校验失败", e)
        }
        return JSONObject(String(plain, Charsets.UTF_8))
    }

    private fun writeFrame(bytes: ByteArray) {
        if (bytes.size > LanSyncWire.MAX_FRAME) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "单帧 ${bytes.size} 字节,超过上限")
        }
        output.writeInt(bytes.size)
        output.write(bytes)
        output.flush()
    }

    private fun readFrame(): ByteArray {
        val size = try {
            input.readInt()
        } catch (e: EOFException) {
            throw LanSyncException(LanSyncFail.IO, "对端已断开", e)
        }
        if (size < 0 || size > LanSyncWire.MAX_FRAME) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对端声明了非法帧长 $size")
        }
        val bytes = ByteArray(size)
        try {
            input.readFully(bytes)
        } catch (e: EOFException) {
            throw LanSyncException(LanSyncFail.IO, "帧没有读完就断开了", e)
        } catch (e: SocketTimeoutException) {
            throw LanSyncException(LanSyncFail.IO, "等待对端超时", e)
        }
        return bytes
    }

    override fun close() {
        runCatching { socket.close() }
    }
}
