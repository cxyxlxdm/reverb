package com.yuyin.reverb.sync

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 端到端协议测试:**真 TCP + 真 ECDH + 真 AES-GCM**,只是把"快照"换成两张内存表。
 *
 * 这一层要证明的是四件事:
 * 1. 两端算出的配对码一致(密钥协商对上了);
 * 2. 双向合并后**两边都是并集**(不是只有发起方拿到数据);
 * 3. 快照超过一个分块仍能完整送达(分块 + SHA-256 校验);
 * 4. 一端拒绝配对时,另一端看到的是"对端取消",而不是超时或解密失败 ——
 *    这条决定用户在界面上读到的是"已取消"还是"网络中断"。
 */
class LanSyncSessionTest {

    @Test
    fun `两端配对码一致且合并成并集`() {
        val alice = identity("alice", "Alice 的手机")
        val bob = identity("bob", "Bob 的电脑")
        val aliceItems = mutableListOf("共同订阅", "Alice 独有")
        val bobItems = mutableListOf("共同订阅", "Bob 独有")
        val aliceCodes = CopyOnWriteArrayList<String>()
        val bobCodes = CopyOnWriteArrayList<String>()

        val (aliceResult, bobResult) = runPair(alice, bob, aliceItems, aliceCodes, bobItems, bobCodes)

        assertEquals("两端屏幕上的六位数必须相同", aliceCodes.single(), bobCodes.single())
        assertEquals(6, aliceCodes.single().length)
        assertEquals(setOf("共同订阅", "Alice 独有", "Bob 独有"), aliceItems.toSet())
        assertEquals(setOf("共同订阅", "Alice 独有", "Bob 独有"), bobItems.toSet())
        // 应方(Alice)新增 1 条;发起方(Bob)先并入了应方快照,新增 1 条(Alice 独有)。
        assertEquals(1, aliceResult.subscriptions)
        assertEquals(1, bobResult.subscriptions)
    }

    @Test
    fun `超过一个分块的快照也能完整送达`() {
        val alice = identity("alice", "Alice")
        val bob = identity("bob", "Bob")
        // 一条 200 字节 × 2000 条 ≈ 400 KB,超过 256 KiB 的单块上限。
        val padding = "x".repeat(180)
        val aliceItems = mutableListOf<String>().apply {
            for (i in 0 until 1000) add("A-$i-$padding")
        }
        val bobItems = mutableListOf<String>().apply {
            for (i in 0 until 1000) add("B-$i-$padding")
        }
        val (aliceResult, bobResult) = runPair(
            alice, bob, aliceItems, CopyOnWriteArrayList(), bobItems, CopyOnWriteArrayList()
        )
        // 两端最终都是并集:应方也会被第二轮写回,所以它的表也变成 2000 条。
        assertEquals(2000, aliceItems.size)
        assertEquals(2000, bobItems.size)
        assertEquals(aliceItems.toSet(), bobItems.toSet())
        // Bob(发起方)收到 Alice 的 1000 条;Alice(应方)收到合并后的 2000 条,其中 1000 条是新的。
        assertEquals(1000, bobResult.subscriptions)
        assertEquals(1000, aliceResult.subscriptions)
    }

    @Test
    fun `一端拒绝时另一端看到对端取消`() {
        val alice = identity("alice", "Alice")
        val bob = identity("bob", "Bob")
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val pool = Executors.newFixedThreadPool(2)
        try {
            val aliceFuture = pool.submit<Any> {
                val socket = server.accept()
                try {
                    runBlocking {
                        session(alice, socket, initiator = false, items = mutableListOf(), codes = CopyOnWriteArrayList()) { true }
                            .run()
                    }
                } catch (e: Exception) {
                    e
                }
            }
            val bobFuture = pool.submit<Any> {
                val socket = Socket().apply {
                    connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), 3000)
                }
                try {
                    runBlocking {
                        session(bob, socket, initiator = true, items = mutableListOf(), codes = CopyOnWriteArrayList()) { false }
                            .run()
                    }
                } catch (e: Exception) {
                    e
                }
            }
            val aliceOutcome = aliceFuture.get(15, TimeUnit.SECONDS)
            val bobOutcome = bobFuture.get(15, TimeUnit.SECONDS)
            assertTrue("发起方应以 CANCELLED 结束,实际:$bobOutcome", bobOutcome is LanSyncException && bobOutcome.fail == LanSyncFail.CANCELLED)
            assertTrue(
                "应方应以 PEER_CANCELLED 结束,实际:$aliceOutcome",
                aliceOutcome is LanSyncException && aliceOutcome.fail == LanSyncFail.PEER_CANCELLED
            )
        } finally {
            pool.shutdownNow()
            runCatching { server.close() }
        }
    }

    // ---- 工具 ----

    private fun runPair(
        alice: LanSyncIdentity.Material,
        bob: LanSyncIdentity.Material,
        aliceItems: MutableList<String>,
        aliceCodes: MutableList<String>,
        bobItems: MutableList<String>,
        bobCodes: MutableList<String>
    ): Pair<LanSyncResult, LanSyncResult> {
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val pool = Executors.newFixedThreadPool(2)
        try {
            val responder = pool.submit<LanSyncResult> {
                val socket = server.accept()
                runBlocking {
                    session(alice, socket, initiator = false, aliceItems, aliceCodes) { true }.run()
                }
            }
            val initiator = pool.submit<LanSyncResult> {
                val socket = Socket().apply {
                    connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), 3000)
                }
                runBlocking {
                    session(bob, socket, initiator = true, bobItems, bobCodes) { true }.run()
                }
            }
            val a = responder.get(30, TimeUnit.SECONDS)
            val b = try {
                initiator.get(30, TimeUnit.SECONDS)
            } catch (e: ExecutionException) {
                throw e.cause ?: e
            }
            return a to b
        } finally {
            pool.shutdownNow()
            runCatching { server.close() }
        }
    }

    private fun session(
        identity: LanSyncIdentity.Material,
        socket: Socket,
        initiator: Boolean,
        items: MutableList<String>,
        codes: MutableList<String>,
        decide: suspend (String) -> Boolean = { true }
    ): LanSyncSession {
        val ui = object : LanSyncUiBridge {
            override suspend fun confirm(peerName: String, code: String): Boolean {
                codes.add(code)
                return decide(code)
            }

            override fun stage(peerName: String, stage: LanSyncStage, percent: Int) = Unit
        }
        return LanSyncSession(
            identity = identity,
            socket = socket,
            initiator = initiator,
            ui = ui,
            buildSnapshot = {
                JSONObject().put("version", 1).put("items", JSONArray(items)).toString()
            },
            applySnapshot = { json ->
                val arr = JSONObject(json).getJSONArray("items")
                val before = items.size
                for (i in 0 until arr.length()) {
                    val s = arr.getString(i)
                    if (s !in items) items.add(s)
                }
                intArrayOf(items.size - before, 0, 0, 0, 0, 0)
            }
        )
    }

    private fun identity(id: String, name: String): LanSyncIdentity.Material {
        return LanSyncIdentity.Material(
            deviceId = id.padEnd(16, '0').take(16),
            name = name,
            createdAt = 0
        )
    }
}
