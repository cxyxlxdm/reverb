package com.yuyin.reverb.sync

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.Logger
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.Socket
import java.net.SocketTimeoutException

/** 同步中的阶段。UI 只按阶段换一句文案,不解析协议。 */
enum class LanSyncStage { SENDING, RECEIVING, MERGING }

/** 一次同步的**增量**读数。`total` 为 0 时界面上不该出现"新增 0 · 0 · 0"。 */
data class LanSyncResult(
    val peerName: String,
    val subscriptions: Int,
    val favorites: Int,
    val stamps: Int,
    val notes: Int,
    val history: Int,
    val stats: Int
) {
    val total: Int get() = subscriptions + favorites + stamps + notes + history + stats
}

/** 会话与界面之间的桥。确认码必须由**人**比对,不能自动确认 —— 否则这一层加密只挡了路人。 */
interface LanSyncUiBridge {
    suspend fun confirm(peerName: String, code: String): Boolean
    fun stage(peerName: String, stage: LanSyncStage, percent: Int)
}

/**
 * 一次完整的配对 + 合并会话。**两端跑的是同一份代码,只有 initiator 一个布尔量的差别**:
 *
 * ```text
 * 双方:  hello(明文, 公钥 + nonce)
 * 双方:  各自算共享密钥 / 会话密钥 / 六位配对码 → 人眼比对
 * 双方:  confirm(密封)          ← 能解开对方的 confirm 就证明会话密钥一致
 * 发起方: request               → 应方把自己的快照分成块发过来
 * 发起方: 并入 → 把**合并后的全集**发回应方
 * 应方:  并入 → ack
 * ```
 *
 * 为什么第二程发的是"合并后的全集"而不是"我这边新增的那部分":全集天然幂等,
 * 而且不需要跟踪"上次同步到哪"(P0 没有同步游标)。代价是多传一遍数据 —— 局域网里可以接受。
 *
 * 快照的"怎么取、怎么并"由调用方注入([buildSnapshot] / [applySnapshot]),本类只管传输:
 * 这样单测可以在纯 JVM 上用两张内存表跑完整协议,不必起 Android 容器。
 * 整份快照先算 SHA-256 再校验,半截数据不会进 `apply`。
 */
class LanSyncSession(
    private val identity: LanSyncIdentity.Material,
    private val socket: Socket,
    private val initiator: Boolean,
    private val ui: LanSyncUiBridge,
    private val buildSnapshot: () -> String,
    private val applySnapshot: (String) -> IntArray
) {

    private val channel = LanSyncChannel(socket)
    private lateinit var peerName: String
    private lateinit var shared: ByteArray

    /**
     * 对端是否声明支持「同步之后的播放交接」(`hello.live`)。
     *
     * 这是**加时赛**不是新协议:老版本没有这个键,读到 false 就不进交接,
     * 也就不用担心把一条老版本的会话拖在一个永远等不到帧的读上。
     */
    var peerSupportsLive: Boolean = false
        private set

    suspend fun run(): LanSyncResult {
        socket.tcpNoDelay = true
        socket.soTimeout = TIMEOUT_MS
        greet()
        val code = LanSyncCrypto.sasCode(shared)
        Logger.i(TAG, "配对开始 peer=$peerName initiator=$initiator code=$code")
        if (!ui.confirm(peerName, code)) {
            runCatching { channel.send(LanSyncWire.json("t" to "cancel")) }
            throw LanSyncException(LanSyncFail.CANCELLED, "本机取消")
        }
        channel.send(LanSyncWire.json("t" to "confirm"))
        expect("confirm")

        val result = if (initiator) runInitiator() else runResponder()
        Logger.i(
            TAG,
            "同步完成 peer=$peerName added subs=${result.subscriptions} favs=${result.favorites} " +
                "stamps=${result.stamps} notes=${result.notes} history=${result.history} stats=${result.stats}"
        )
        return result
    }

    fun close() {
        channel.close()
    }

    private fun greet() {
        val nonce = LanSyncCrypto.randomBytes(NONCE_BYTES)
        // **每次会话现生成一对临时密钥**(H278)。曾经直接拿身份里的长期密钥做 ECDH,
        // 于是同一对设备每轮配对码都一样、也没有前向保密 —— 与注释和文档的承诺相反。
        val ephemeral = LanSyncCrypto.generateKeyPair()
        channel.sendPlain(
            LanSyncWire.json(
                "t" to "hello",
                "v" to LanSyncWire.VERSION,
                "id" to identity.deviceId,
                "name" to identity.name,
                "pub" to LanSyncCrypto.base64(LanSyncCrypto.encodePublicKey(ephemeral.public)),
                "nonce" to LanSyncCrypto.base64(nonce),
                // 交接是同步之后的**加时赛**:同一把会话密钥、同一条 TCP。
                // 老版本忽略这个键,同步完就断开;我们这边读到 false 就不进读循环。
                "live" to true
            )
        )
        val hello = runCatching { channel.receivePlain() }.getOrElse {
            throw LanSyncException(LanSyncFail.IO, "没有收到对方的问候", it)
        }
        if (hello.optString("t") != "hello") {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对方第一帧不是 hello")
        }
        if (hello.optInt("v", 0) != LanSyncWire.VERSION) {
            throw LanSyncException(LanSyncFail.VERSION, "对方协议版本 ${hello.optInt("v", 0)}")
        }
        // 发现层有时会看见自己(名字冲突时系统还会把服务名改掉,按名字排不掉),这里按设备 id 再挡一次。
        if (hello.optString("id") == identity.deviceId) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对端就是本机")
        }
        val peerPub = runCatching { LanSyncCrypto.unbase64(hello.getString("pub")) }.getOrElse {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对方公钥不是 base64", it)
        }
        if (peerPub.size != LanSyncCrypto.PUBLIC_KEY_BYTES) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对方公钥长度 ${peerPub.size}")
        }
        val peerNonce = runCatching { LanSyncCrypto.unbase64(hello.getString("nonce")) }.getOrElse {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对方 nonce 不是 base64", it)
        }
        if (peerNonce.size != NONCE_BYTES) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对方 nonce 长度 ${peerNonce.size}")
        }
        val clientNonce = if (initiator) nonce else peerNonce
        val serverNonce = if (initiator) peerNonce else nonce
        shared = LanSyncCrypto.sharedSecret(ephemeral.private, peerPub)
        channel.useKey(LanSyncCrypto.sessionKey(shared, clientNonce, serverNonce))
        peerSupportsLive = hello.optBoolean("live", false)
        peerName = hello.optString("name").trim().take(64).ifBlank { "设备" }
    }

    /**
     * 同步完成之后进入「播放交接」通道。对端不支持时返回 null(界面就不出现交接区)。
     *
     * 这里顺手把 socket 读超时关掉:交接期间对端暂停时可能长时间只发心跳,
     * 30 秒那条同步期超时会把一条好连接判成"网络中断"。结束时靠关闭 socket 收尾。
     */
    fun makeLive(
        provider: suspend () -> LanPlaybackStatus?,
        pauseForTake: suspend () -> LanPlaybackStatus?,
        onPeer: suspend (LanPeerHint?, LanClockEstimator) -> Unit,
        onTaken: suspend (Episode, Long) -> Unit,
        onEnded: suspend () -> Unit
    ): LanSyncLive? {
        if (!peerSupportsLive) return null
        runCatching { socket.soTimeout = 0 }
        return LanSyncLive(
            send = { channel.send(it) },
            receive = { channel.receive() },
            provider = provider,
            pauseForTake = pauseForTake,
            onPeer = onPeer,
            onTaken = onTaken,
            onEnded = onEnded
        )
    }

    private suspend fun runInitiator(): LanSyncResult {
        channel.send(LanSyncWire.json("t" to "request"))
        ui.stage(peerName, LanSyncStage.RECEIVING, 0)
        val remote = receiveSnapshot { ui.stage(peerName, LanSyncStage.RECEIVING, it) }
        ui.stage(peerName, LanSyncStage.MERGING, 0)
        val added = applySnapshot(remote)
        ui.stage(peerName, LanSyncStage.SENDING, 0)
        sendSnapshot { ui.stage(peerName, LanSyncStage.SENDING, it) }
        expect("ack")
        return result(added)
    }

    private suspend fun runResponder(): LanSyncResult {
        expect("request")
        sendSnapshot { ui.stage(peerName, LanSyncStage.SENDING, it) }
        ui.stage(peerName, LanSyncStage.RECEIVING, 0)
        val merged = receiveSnapshot { ui.stage(peerName, LanSyncStage.RECEIVING, it) }
        ui.stage(peerName, LanSyncStage.MERGING, 0)
        val added = applySnapshot(merged)
        channel.send(LanSyncWire.json("t" to "ack"))
        return result(added)
    }

    private fun sendSnapshot(progress: (Int) -> Unit) {
        val bytes = buildSnapshot().toByteArray(Charsets.UTF_8)
        if (bytes.size > LanSyncWire.MAX_SNAPSHOT) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "本机快照 ${bytes.size} 字节,超过上限")
        }
        val chunks = maxOf(1, (bytes.size + CHUNK_BYTES - 1) / CHUNK_BYTES)
        channel.send(
            LanSyncWire.json(
                "t" to "offer",
                "size" to bytes.size,
                "chunks" to chunks,
                "sha256" to LanSyncCrypto.base64(LanSyncCrypto.sha256(bytes))
            )
        )
        for (i in 0 until chunks) {
            val from = i * CHUNK_BYTES
            val to = minOf(bytes.size, from + CHUNK_BYTES)
            channel.send(
                LanSyncWire.json(
                    "t" to "chunk",
                    "i" to i,
                    "d" to LanSyncCrypto.base64(bytes.copyOfRange(from, to))
                )
            )
            if (i % PROGRESS_EVERY == 0) progress((i + 1) * 100 / chunks)
        }
    }

    private fun receiveSnapshot(progress: (Int) -> Unit): String {
        val offer = expect("offer")
        val size = offer.optInt("size", -1)
        val chunks = offer.optInt("chunks", -1)
        if (size < 0 || size > LanSyncWire.MAX_SNAPSHOT) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对方快照大小 $size 不合法")
        }
        if (chunks < 1 || chunks > LanSyncWire.MAX_SNAPSHOT / CHUNK_BYTES + 1) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "对方分块数 $chunks 不合法")
        }
        val out = ByteArrayOutputStream(size)
        for (i in 0 until chunks) {
            val frame = expect("chunk")
            if (frame.optInt("i", -1) != i) {
                throw LanSyncException(LanSyncFail.PROTOCOL, "分块顺序错乱:期待 $i,收到 ${frame.optInt("i", -1)}")
            }
            val data = runCatching { LanSyncCrypto.unbase64(frame.getString("d")) }.getOrElse {
                throw LanSyncException(LanSyncFail.PROTOCOL, "分块不是 base64", it)
            }
            out.write(data)
            if (out.size() > LanSyncWire.MAX_SNAPSHOT) {
                throw LanSyncException(LanSyncFail.PROTOCOL, "对方发来的数据超过上限")
            }
            if (i % PROGRESS_EVERY == 0) progress((i + 1) * 100 / chunks)
        }
        val bytes = out.toByteArray()
        if (bytes.size != size) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "收到 ${bytes.size} 字节,对方声明 $size")
        }
        val expected = runCatching { LanSyncCrypto.unbase64(offer.getString("sha256")) }.getOrElse {
            throw LanSyncException(LanSyncFail.PROTOCOL, "校验值不是 base64", it)
        }
        if (!LanSyncCrypto.constantTimeEquals(expected, LanSyncCrypto.sha256(bytes))) {
            throw LanSyncException(LanSyncFail.PROTOCOL, "快照校验值不一致")
        }
        return String(bytes, Charsets.UTF_8)
    }

    private fun expect(type: String): JSONObject {
        val frame = try {
            channel.receive()
        } catch (e: SocketTimeoutException) {
            throw LanSyncException(LanSyncFail.IO, "等待对端超时", e)
        }
        when (frame.optString("t")) {
            "cancel" -> throw LanSyncException(LanSyncFail.PEER_CANCELLED, "对端取消")
            type -> return frame
            else -> throw LanSyncException(
                LanSyncFail.PROTOCOL,
                "期待 $type,收到 ${frame.optString("t")}"
            )
        }
    }

    private fun result(added: IntArray) = LanSyncResult(
        peerName = peerName,
        subscriptions = added[0],
        favorites = added[1],
        stamps = added[2],
        notes = added[3],
        history = added[4],
        stats = added[5]
    )

    private companion object {
        const val TAG = "LanSync.Session"
        const val TIMEOUT_MS = 30_000
        const val NONCE_BYTES = 16
        const val CHUNK_BYTES = LanSyncWire.CHUNK_BYTES
        const val PROGRESS_EVERY = 8
    }
}
