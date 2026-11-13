package com.yuyin.reverb.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 墓碑账本的纯判据:归一化、覆盖顺序、过期剪除、本地重加清除。
 *
 * 这里直接跑单例 —— 单测里没有人调 `configure`,所以 `file == null`,`save()` 全是空转,
 * 不会碰盘、也不会污染本机 `filesDir`(与 `AppContainer` 里那句"没配置过时所有操作都是空转"
 * 是同一条承诺)。每个用例用**自己独有的 kind**,避免单例状态在用例之间串。
 *
 * Apple 端(`LanSyncTombstones.swift`)是同一份契约,那边只测纯函数:它的 `record` 会直接
 * 写进真实的 `~/Library/Application Support/Reverb/`,单测里没有可注入的目录,不该为了测试去写用户的账本。
 */
class SyncTombstonesTest {

    /** 用"现在"当基准,再用 ±毫秒偏移构造先后,避免写死时间戳有一天变成"已过期"。 */
    private val base = System.currentTimeMillis()

    private fun kind(tag: String) = "test-$tag-${System.nanoTime()}"

    @Test
    fun `归一化认源不认写法`() {
        // 协议与主机名大小写、尾部斜杠都不该变成两条;路径大小写敏感,不能一起小写。
        assertEquals("https://a.com/f", SyncTombstones.normalizeFeed("HTTPS://A.com/f/"))
        assertEquals("https://a.com/F", SyncTombstones.normalizeFeed("https://A.com/F"))
        assertEquals("https://a.com", SyncTombstones.normalizeFeed("https://A.com"))
        // 查询串/片段不是 authority 的一部分,原样保留。
        assertEquals("https://a.com/p?X=1", SyncTombstones.normalizeFeed("https://A.com/p?X=1"))
        // 没有 `://` 的串(用户名裸串之类)只去空白与尾斜杠。
        assertEquals("Feed", SyncTombstones.normalizeFeed(" Feed/ "))
        assertNull(SyncTombstones.normalizeFeed("   "))
    }

    @Test
    fun `订阅键优先用归一化 feedUrl 否则退回 id`() {
        assertEquals("https://a.com/f", SyncTombstones.subscriptionKey("HTTPS://A.com/f/", "whatever"))
        assertEquals("collection-42", SyncTombstones.subscriptionKey("  ", "collection-42"))
    }

    @Test
    fun `记录后可读出`() {
        val k = kind("record")
        SyncTombstones.record(k, "ep-1", now = base)
        assertEquals(setOf("ep-1"), SyncTombstones.ids(k, now = base + 1))
    }

    @Test
    fun `本地重新添加清掉墓碑`() {
        val k = kind("clear")
        SyncTombstones.record(k, "ep-1", now = base)
        SyncTombstones.clear(k, "ep-1")
        assertTrue(SyncTombstones.ids(k, now = base + 1).isEmpty())
    }

    @Test
    fun `合并取较晚的 deletedAt 且早的不覆盖`() {
        val k = kind("merge")
        SyncTombstones.record(k, "ep-1", now = base)

        // 远端更晚 → 覆盖
        SyncTombstones.merge(
            JSONArray().put(JSONObject().put("kind", k).put("id", "ep-1").put("deletedAt", base + 1_000)),
            now = base + 2_000,
        )
        // 远端更早 → 不覆盖
        SyncTombstones.merge(
            JSONArray().put(JSONObject().put("kind", k).put("id", "ep-1").put("deletedAt", base - 1_000)),
            now = base + 2_000,
        )

        val snap = SyncTombstones.snapshot(now = base + 2_000)
        val at = (0 until snap.length())
            .map { snap.getJSONObject(it) }
            .filter { it.getString("kind") == k && it.getString("id") == "ep-1" }
            .single()
            .getLong("deletedAt")
        assertEquals(base + 1_000, at)
    }

    @Test
    fun `超过保留期自动剪掉`() {
        val k = kind("expire")
        SyncTombstones.record(k, "ep-1", now = base)
        // 90 天后仍然有效
        assertEquals(setOf("ep-1"), SyncTombstones.ids(k, now = base + 89L * 24 * 60 * 60 * 1000))
        // 91 天:剪掉
        assertTrue(SyncTombstones.ids(k, now = base + 91L * 24 * 60 * 60 * 1000).isEmpty())
    }

    @Test
    fun `畸形远端条目被忽略`() {
        val k = kind("malformed")
        SyncTombstones.merge(
            JSONArray()
                .put(JSONObject().put("kind", "").put("id", "ep-1").put("deletedAt", base))
                .put(JSONObject().put("kind", k).put("id", "").put("deletedAt", base))
                .put(JSONObject().put("kind", k).put("id", "ep-1").put("deletedAt", 0))
                .put(JSONObject().put("kind", k)),
            now = base + 1,
        )
        assertTrue(SyncTombstones.ids(k, now = base + 1).isEmpty())
        // 空账本的快照形状固定:是数组,对端不必判空。
        assertTrue(SyncTombstones.snapshot(now = base + 1) is JSONArray)
    }
}
