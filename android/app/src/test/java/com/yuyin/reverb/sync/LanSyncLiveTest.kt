package com.yuyin.reverb.sync

import com.yuyin.reverb.data.model.Episode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

/**
 * 播放交接的判据。与 Apple `LanSyncLiveTest` 同一组场景 —— 两端跑的是同一份线格式。
 *
 * 三层:
 * 1. **纯判据**:时钟样本、交接位置、线格式往返(四端逐字节一致的部分);
 * 2. **端到端**:两个 [LanSyncLive] 用内存通道对跑,验证「A 先暂停、B 拿到 taken 才播」
 *    这个**顺序** —— 两台设备同时出声是这个功能最典型的翻车方式;
 * 3. 对端离开时通道要结束,而不是把界面挂在一个永远等不到帧的读上。
 */
class LanSyncLiveTest {

    // ---- 纯判据:时钟 ----

    @Test
    fun `时钟样本取往返一半`() {
        // t0=1000 t1=1100 t2=1150 t3=1300:去程 100、回程 150 ⇒ rtt 250、偏差 -25。
        val s = LanClockEstimator.sample(t0 = 1000, t1 = 1100, t2 = 1150, t3 = 1300)
        assertNotNull(s)
        assertEquals(250.0, s!!.rttMs, 0.001)
        assertEquals(-25.0, s.offsetMs, 0.001)
    }

    @Test
    fun `垃圾时钟样本不采信`() {
        // 对端"处理"了 900ms 而整趟只走了 200ms ⇒ rtt 为负。
        assertNull(LanClockEstimator.sample(t0 = 0, t1 = 100, t2 = 1_000, t3 = 200))
        // 一次 2.5 秒的尖峰:单这一组不该被采信。
        assertNull(LanClockEstimator.sample(t0 = 0, t1 = 1_250, t2 = 1_250, t3 = 2_500))
    }

    @Test
    fun `中位数`() {
        assertEquals(0.0, LanClockEstimator.median(emptyList()), 0.0)
        assertEquals(7.0, LanClockEstimator.median(listOf(7.0)), 0.0)
        assertEquals(2.0, LanClockEstimator.median(listOf(3.0, 1.0, 2.0)), 0.0)
        assertEquals(2.5, LanClockEstimator.median(listOf(4.0, 1.0, 3.0, 2.0)), 0.0)
    }

    @Test
    fun `两组样本才可用且只留最近五组`() {
        val est = LanClockEstimator()
        assertFalse(est.usable)
        est.add(LanClockSample(100.0, 10.0))
        assertFalse("只有一组样本时不外推位置", est.usable)
        est.add(LanClockSample(120.0, 20.0))
        assertTrue(est.usable)
        assertEquals(110.0, est.offsetMs, 0.0)

        for (i in 0 until 10) est.add(LanClockSample(i.toDouble(), 5.0))
        assertEquals(7.0, est.offsetMs, 0.0) // 最近五组 5,6,7,8,9 的中位数

        est.add(LanClockSample(0.0, 9_999.0))
        assertEquals("超长往返的样本直接丢", 7.0, est.offsetMs, 0.0)
    }

    // ---- 纯判据:交接位置 ----

    @Test
    fun `交接位置加的是往返的一半`() {
        assertEquals(60_000L, LanSyncLive.handoffPosition(60_000, 0, 1f, 3_600_000))
        assertEquals(60_500L, LanSyncLive.handoffPosition(60_000, 1_000, 1f, 3_600_000))
        // 倍速播放时,同样的网线时间对应对端走了两倍的内容。
        assertEquals(61_000L, LanSyncLive.handoffPosition(60_000, 1_000, 2f, 3_600_000))
    }

    @Test
    fun `交接位置在结尾前留一秒半`() {
        // 落点必须离结尾至少 1.5 秒,否则接手的设备会立刻判「已播完」。
        assertEquals(3_598_500L, LanSyncLive.handoffPosition(3_599_800, 1_000, 1f, 3_600_000))
        // 时长本来就不足 1.5 秒(试听片段)时不夹,夹了会得到负数。
        assertEquals(900L, LanSyncLive.handoffPosition(900, 0, 1f, 1_000))
    }

    @Test
    fun `交接位置能容忍异常输入`() {
        assertEquals(10_000L, LanSyncLive.handoffPosition(10_000, -40, 1f, 3_600_000))
        // 速率下限 0.1:0.5× 以下(含 0 / 负数)都按 0.1 算,别把落点算成负的。
        assertEquals(10_050L, LanSyncLive.handoffPosition(10_000, 1_000, 0f, 3_600_000))
    }

    // ---- 纯判据:线格式 ----

    @Test
    fun `状态帧往返且不带 shownotes`() {
        val ep = episode("ep-1", "第 42 集", "shownotes ".repeat(2_000))
        val status = LanPlaybackStatus(ep, 61_000, 3_600_000, true, 1.5f, 1_700_000_000_000)
        val frame = status.frame("pb")
        assertEquals("pb", frame.getString("t"))
        assertEquals("", frame.getJSONObject("ep").getString("description"))

        val back = LanPlaybackStatus.parse(frame)
        assertNotNull(back)
        assertEquals("ep-1", back!!.episode?.id)
        assertEquals("第 42 集", back.episode?.title)
        assertEquals(ep.audioUrl, back.episode?.audioUrl)
        assertEquals(61_000L, back.positionMs)
        assertEquals(3_600_000L, back.durationMs)
        assertTrue(back.playing)
        assertEquals(1.5f, back.rate, 0.001f)
        assertEquals(1_700_000_000_000L, back.atMs)
    }

    @Test
    fun `没有位置的帧解析成没有状态`() {
        // 「对方现在没在播」只发 `{t:"pb"}`:没有 pos 就是没有状态,不能解成 0 秒。
        assertNull(LanPlaybackStatus.parse(org.json.JSONObject().put("t", "pb")))
    }

    // ---- 端到端 ----

    @Test
    fun `take 先让对方暂停再开播`() = runBlocking {
        val a2b = Channel<org.json.JSONObject>(Channel.UNLIMITED)
        val b2a = Channel<org.json.JSONObject>(Channel.UNLIMITED)
        val log = CopyOnWriteArrayList<String>()
        val ep = episode("ep-live", "交接这一集", "很长的 shownotes")
        val taken = AtomicReference<List<Long>>(emptyList())

        // A:正在播(第 60 秒),被 take 时"暂停"并把位置推进到第 61 秒。
        val liveA = LanSyncLive(
            send = { a2b.send(it) },
            receive = { b2a.receive() },
            provider = {
                LanPlaybackStatus(ep, 60_000, 3_600_000, true, 1f, LanPlaybackStatus.nowMs())
            },
            pauseForTake = {
                log += "A.pause"
                LanPlaybackStatus(ep, 61_000, 3_600_000, false, 1f, LanPlaybackStatus.nowMs())
            },
            onPeer = { _, _ -> },
            onTaken = { _, _ -> log += "B.play-A" },
            onEnded = {}
        )
        // B:这时没在播,只有别人把它「接过去」才有内容。
        val liveB = LanSyncLive(
            send = { b2a.send(it) },
            receive = { a2b.receive() },
            provider = { null },
            pauseForTake = { null },
            onPeer = { hint, _ -> if (hint != null) log += "B.peer" },
            onTaken = { e, pos ->
                log += "B.play"
                taken.set(taken.get() + pos)
                assertEquals("ep-live", e.id)
            },
            onEnded = {}
        )

        val aJob = async(Dispatchers.IO) { liveA.run() }
        val bJob = async(Dispatchers.IO) { liveB.run() }
        try {
            // 1) A 的 pb 送到 B 之前不能有任何「开播」。
            waitFor("B 收到 A 的播放状态") { "B.peer" in log }
            assertFalse("没有点「在此设备继续」之前不能自己播", "B.play" in log)

            // 2) 点「在此设备继续」。
            liveB.take()
            waitFor("B 收到 taken") { taken.get().isNotEmpty() }
            waitFor("A 已暂停") { "A.pause" in log }

            // 3) 顺序断言:A 先暂停,B 才播。
            val pauseIdx = log.indexOf("A.pause")
            val playIdx = log.indexOf("B.play")
            assertTrue("A 应该被要求暂停", pauseIdx >= 0)
            assertTrue("B 应该开播", playIdx >= 0)
            assertTrue("B 必须在 A 确认暂停之后才开播", pauseIdx < playIdx)

            // 4) 落点 = A 的最终位置 + 往返的一半(内存通道往返只有几毫秒,留 200ms 宽)。
            val target = taken.get().first()
            assertTrue("落点 $target 不在 61000..61200", target in 61_000L..61_200L)
        } finally {
            liveB.stop()
            liveA.stop()
            a2b.close()
            b2a.close()
            aJob.cancel()
            bJob.cancel()
        }
    }

    @Test
    fun `对端离开时交接通道结束`() = runBlocking {
        val a2b = Channel<org.json.JSONObject>(Channel.UNLIMITED)
        val b2a = Channel<org.json.JSONObject>(Channel.UNLIMITED)
        val ended = AtomicReference(false)
        val ep = episode("ep-x", "随便一集", "")

        val liveA = LanSyncLive(
            send = { a2b.send(it) },
            receive = { b2a.receive() },
            provider = { LanPlaybackStatus(ep, 1_000, 60_000, true, 1f, LanPlaybackStatus.nowMs()) },
            pauseForTake = { null },
            onPeer = { _, _ -> },
            onTaken = { _, _ -> },
            onEnded = { ended.set(true) }
        )

        val job = async(Dispatchers.IO) { liveA.run() }
        try {
            delay(400)
            // 对端关面板 = 连接断开。不是错误,只结束交接。
            b2a.close()
            waitFor("A 收到连接结束") { ended.get() }
        } finally {
            liveA.stop()
            a2b.close()
            job.cancel()
        }
    }

    // ---- 搭台 ----

    private fun episode(id: String, title: String, description: String) = Episode(
        id = id,
        title = title,
        description = description,
        audioUrl = "https://example.com/$id.mp3",
        artworkUrl = "https://example.com/$id.jpg",
        podcastTitle = "余音测试台",
        durationSec = 3_600
    )

    private suspend fun waitFor(what: String, timeoutMs: Long = 5_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            delay(20)
        }
        throw AssertionError("等待超时(${timeoutMs}ms):$what")
    }
}
