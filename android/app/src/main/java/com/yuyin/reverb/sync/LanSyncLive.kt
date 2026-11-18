package com.yuyin.reverb.sync

import com.yuyin.reverb.data.local.EpisodeJson
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.SocketTimeoutException

/**
 * 交接时一台设备要告诉对方的播放状态。`episode == null` 表示"已经没有可交接的内容"。
 *
 * **只带播放要用的字段**:`description`(shownotes)是几十 KB 的常客,1 Hz 发一遍等于
 * 把整篇稿件每秒传一次;接手的设备要的是 id / 标题 / 音频地址 / 封面。
 * 字段名与 Apple `LanPlaybackStatus` 逐字相同 —— 两端互相解对方的帧。
 */
data class LanPlaybackStatus(
    val episode: Episode?,
    val positionMs: Long,
    val durationMs: Long,
    val playing: Boolean,
    val rate: Float,
    /** 发送者的墙钟毫秒。**只用于显示外推**,不参与任何排序。 */
    val atMs: Long
) {
    /** 线格式:`{t, ep?, pos, dur, playing, rate, at}`。 */
    fun frame(type: String): JSONObject {
        val f = LanSyncWire.json(
            "t" to type,
            "pos" to positionMs,
            "dur" to durationMs,
            "playing" to playing,
            "rate" to rate.toDouble(),
            "at" to atMs
        )
        episode?.let { f.put("ep", EpisodeJson.toJson(it).put("description", "")) }
        return f
    }

    companion object {
        fun nowMs(): Long = System.currentTimeMillis()

        /** 解析失败(缺 pos)返回 null —— 调用方按「对方没有内容」处理,不把半条帧当状态。 */
        fun parse(f: JSONObject): LanPlaybackStatus? {
            if (!f.has("pos")) return null
            val ep = f.optJSONObject("ep")?.let {
                runCatching { EpisodeJson.fromJson(it) }.getOrNull()
            }
            return LanPlaybackStatus(
                episode = ep,
                positionMs = f.optLong("pos", 0),
                durationMs = f.optLong("dur", 0),
                playing = f.optBoolean("playing", false),
                rate = f.optDouble("rate", 1.0).toFloat(),
                atMs = f.optLong("at", 0)
            )
        }
    }
}

/** 界面拿到的「另一台设备」状态。位置已按估计的时钟偏差外推到**现在**。 */
data class LanPeerHint(
    val episode: Episode,
    val positionMs: Long,
    val playing: Boolean,
    /** 时钟样本不足 / 往返太大 ⇒ 位置只当参考,界面写「约 12:34」。 */
    val approximate: Boolean
)

/** ping-pong 四时间戳的偏差估计。`offset` 是「对端时钟 − 本机时钟」的毫秒数。 */
data class LanClockSample(val offsetMs: Double, val rttMs: Double)

class LanClockEstimator {
    private val samples = mutableListOf<LanClockSample>()

    val offsetMs: Double get() = median(samples.map { it.offsetMs })
    val rttMs: Double get() = median(samples.map { it.rttMs })

    /** 少于两组就不外推:只有一组时无法判断它是不是恰好被调度尖峰拉偏。 */
    val usable: Boolean get() = samples.size >= 2

    fun add(s: LanClockSample) {
        if (!s.rttMs.isFinite() || s.rttMs < 0 || s.rttMs > 2_000) return
        samples += s
        if (samples.size > CAPACITY) samples.subList(0, samples.size - CAPACITY).clear()
    }

    companion object {
        const val CAPACITY = 5

        /** t0 = 本机发出 ping,t1 = 对端收到,t2 = 对端发出 pong,t3 = 本机收到。 */
        fun sample(t0: Long, t1: Long, t2: Long, t3: Long): LanClockSample? {
            val rtt = (t3 - t0) - (t2 - t1)
            if (rtt < 0 || rtt > 2_000) return null
            val offset = ((t1 - t0).toDouble() + (t2 - t3).toDouble()) / 2.0
            return LanClockSample(offset, rtt.toDouble())
        }

        fun median(values: List<Double>): Double {
            if (values.isEmpty()) return 0.0
            val sorted = values.sorted()
            val mid = sorted.size / 2
            return if (sorted.size % 2 == 0) (sorted[mid - 1] + sorted[mid]) / 2 else sorted[mid]
        }
    }
}

/**
 * 交接的实时通道。同步完成之后**复用同一条已认证的 TCP**,不再配对一次。
 *
 * 产品边界(见 `docs/research/2026-11-11-lan-sync.md` §6):
 * - 只在「正在播放」时 1 Hz 发状态;暂停/跳转/切集立即补一条;
 * - **不自动接管** —— 必须对方屏幕上点「在此设备继续」;
 * - 交接流程固定为「请求方 take → 播放方先暂停并回 taken(带最终位置)→ 请求方 seek 再播」,
 *   所以两台设备不会同时出声;
 * - 面板关掉 socket 就断,这也是「不在后台常驻」承诺的实现方式。
 *
 * 与 Apple `LanSyncLive` 是同一份协议的两份实现:读循环与发心跳并行,
 * 所以 `take()` 只动一行状态、不碰 IO 线程。
 */
class LanSyncLive(
    private val send: suspend (JSONObject) -> Unit,
    private val receive: suspend () -> JSONObject,
    private val provider: suspend () -> LanPlaybackStatus?,
    private val pauseForTake: suspend () -> LanPlaybackStatus?,
    private val onPeer: suspend (LanPeerHint?, LanClockEstimator) -> Unit,
    private val onTaken: suspend (Episode, Long) -> Unit,
    private val onEnded: suspend () -> Unit
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()

    @Volatile private var stopped = false
    private var ticker: Job? = null

    private val clock = LanClockEstimator()
    private var lastPeerStatus: LanPlaybackStatus? = null
    private var lastSignature = "none"
    private var lastSentAt = 0L
    private var lastPositionMs = 0L
    private var takeSentAt: Long? = null
    private var takeTimedOut = false

    /** 读循环。阻塞在对端帧上;对端关面板 / 本端关闭 socket 时返回。 */
    suspend fun run() {
        ticker = scope.launch { tick() }
        try {
            while (!stopped) {
                val frame = try {
                    receive()
                } catch (e: SocketTimeoutException) {
                    // 帧边界上的超时空转一圈即可:对端暂停时本来就长时间不说话。
                    continue
                }
                handle(frame)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!stopped) {
                // 对端关面板 / 老版本在同步完就断开,都走到这里。不是错误,不弹窗。
                Logger.i(TAG, "交接通道结束:${e.message}")
            }
        } finally {
            ticker?.cancel()
            ticker = null
        }
        onEnded()
    }

    fun stop() {
        stopped = true
        ticker?.cancel()
        ticker = null
        scope.cancel()
    }

    /** 用户点「在此设备继续」。**只发请求,不先播** —— 等对方的 `taken` 带最终位置回来。 */
    suspend fun take() {
        synchronized(lock) {
            if (takeSentAt != null || takeTimedOut) return
            takeSentAt = LanPlaybackStatus.nowMs()
        }
        send(LanSyncWire.json("t" to "take"))
    }

    /** 超时后取消这次请求:迟到的 `taken` 不再把播放器拽走。 */
    fun cancelTake() {
        synchronized(lock) {
            takeSentAt = null
            takeTimedOut = true
        }
    }

    fun allowTakeAgain() {
        synchronized(lock) { takeTimedOut = false }
    }

    // ---- 帧 ----

    private suspend fun handle(frame: JSONObject) {
        when (frame.optString("t")) {
            "pb" -> {
                val status = LanPlaybackStatus.parse(frame)
                if (status != null) {
                    synchronized(lock) { lastPeerStatus = status }
                    onPeer(hint(status), clock)
                } else {
                    // 「对方现在没有在播的内容」:清掉上一份,否则下一次 pong 会把旧提示又推回来。
                    synchronized(lock) { lastPeerStatus = null }
                    onPeer(null, clock)
                }
            }

            "ping" -> {
                val t1 = LanPlaybackStatus.nowMs()
                send(
                    LanSyncWire.json(
                        "t" to "pong",
                        "t0" to frame.optLong("t0", 0),
                        "t1" to t1,
                        "t2" to LanPlaybackStatus.nowMs()
                    )
                )
            }

            "pong" -> {
                val s = LanClockEstimator.sample(
                    t0 = frame.optLong("t0", 0),
                    t1 = frame.optLong("t1", 0),
                    t2 = frame.optLong("t2", 0),
                    t3 = LanPlaybackStatus.nowMs()
                )
                if (s != null) {
                    clock.add(s)
                    val current = synchronized(lock) { lastPeerStatus }
                    onPeer(current?.let { hint(it) }, clock)
                }
            }

            "take" -> {
                val status = pauseForTake()
                send(status?.frame("taken") ?: LanSyncWire.json("t" to "taken", "none" to true))
            }

            "taken" -> {
                val sentAt = synchronized(lock) {
                    val v = takeSentAt
                    takeSentAt = null
                    v
                } ?: return
                if (frame.optBoolean("none", false)) return
                val status = LanPlaybackStatus.parse(frame) ?: return
                val ep = status.episode ?: return
                val rtt = (LanPlaybackStatus.nowMs() - sentAt).coerceAtLeast(0)
                onTaken(
                    ep,
                    handoffPosition(status.positionMs, rtt, status.rate, status.durationMs)
                )
            }
        }
    }

    private fun hint(status: LanPlaybackStatus): LanPeerHint? {
        synchronized(lock) { lastPeerStatus = status }
        val ep = status.episode ?: return null
        val approximate = !clock.usable || clock.rttMs > 2_000
        var pos = status.positionMs.toDouble()
        if (!approximate && status.playing) {
            val peerNow = status.atMs.toDouble() + clock.offsetMs
            val elapsed = (LanPlaybackStatus.nowMs().toDouble() - peerNow) / 1000.0
            // 外推只在一分钟内可信;对端时钟被改过 / 休眠很久时不要画出离谱的位置。
            if (elapsed > -5 && elapsed < 60) pos += elapsed * status.rate
        }
        if (status.durationMs > 0) pos = pos.coerceIn(0.0, status.durationMs.toDouble())
        return LanPeerHint(
            episode = ep,
            positionMs = pos.toLong().coerceAtLeast(0),
            playing = status.playing,
            approximate = approximate
        )
    }

    // ---- 本机状态推送 ----

    private suspend fun tick() {
        var nextPing = 0L
        var burst = 0
        while (!stopped) {
            val now = LanPlaybackStatus.nowMs()
            if (now >= nextPing) {
                runCatching { send(LanSyncWire.json("t" to "ping", "t0" to now)) }
                if (burst < 5) {
                    burst++
                    nextPing = now + 400
                } else {
                    nextPing = now + 5_000
                }
            }
            pushLocal(now)
            delay(250)
        }
    }

    private suspend fun pushLocal(now: Long) {
        val status = provider()
        val signature = if (status == null) "none" else {
            "${status.episode?.id ?: ""}|${status.playing}|${(status.rate * 100).toInt()}"
        }
        var seeked = false
        if (status != null && status.playing && signature == lastSignature && lastSentAt > 0) {
            val dt = (now - lastSentAt) / 1000.0
            val expected = lastPositionMs + dt * status.rate * 1000.0
            seeked = kotlin.math.abs(status.positionMs - expected) > 2_500
        }
        val due = signature != lastSignature ||
            seeked ||
            (status?.playing == true && now - lastSentAt >= 1_000)
        if (!due) return
        runCatching {
            if (status != null) send(status.frame("pb")) else send(LanSyncWire.json("t" to "pb"))
        }
        lastPositionMs = status?.positionMs ?: 0L
        lastSignature = signature
        lastSentAt = now
    }

    companion object {
        private const val TAG = "LanSync.Live"

        /**
         * 交接位置 = 对方暂停时的位置 + 这次 `take` 往返的一半 × 对方速率。
         * 为什么用往返一半而不是时钟偏差:整条路径里只需要知道「消息在网线里走了多久」,
         * 两台的墙钟差多少与这件事无关。末尾留 1.5 秒余量,避免刚好落在结尾被判成已播完。
         */
        fun handoffPosition(positionMs: Long, rttMs: Long, rate: Float, durationMs: Long): Long {
            val advance = rttMs.coerceAtLeast(0) / 2.0 * rate.coerceAtLeast(0.1f)
            var target = (positionMs.coerceAtLeast(0) + advance).toLong()
            if (durationMs > 1_500) target = minOf(target, durationMs - 1_500)
            return target.coerceAtLeast(0)
        }
    }
}
