package com.yuyin.reverb.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 更新检测/续传里不碰网络的那几段纯逻辑。
 *
 * 2026-11-23 加 Atom 兜底与断点续传:前者解析错会把 beta 或旧版推给用户,
 * 后者拼错一次就是把两份不同字节合成一份安装包 —— 都不该靠真机碰运气。
 */
class SelfUpdateResumeTest {

    @Test
    fun `Atom 只认数字版本并按版本降序`() {
        val xml = """
            <feed>
              <title>Release notes from revert-cast</title>
              <entry><title>1.0.8</title></entry>
              <entry><title>1.0.10</title></entry>
              <entry><title>v1.0.9</title></entry>
              <entry><title>1.1.0-beta</title></entry>
              <entry><title>1.0.10</title></entry>
            </feed>
        """.trimIndent()
        assertEquals(listOf("1.0.10", "v1.0.9", "1.0.8"), SelfUpdate.parseAtomTags(xml))
        assertFalse(SelfUpdate.isStableVersionTag("1.1.0-beta"))
        assertFalse(SelfUpdate.isStableVersionTag("Release notes"))
        assertTrue(SelfUpdate.isStableVersionTag("v1.0.9"))
    }

    @Test
    fun `Content Range 解析起点与总量`() {
        assertEquals(1000L to 6622867L, SelfUpdate.parseContentRange("bytes 1000-2023/6622867"))
        assertEquals(0L to 0L, SelfUpdate.parseContentRange("bytes 0-0/*"))
        assertNull(SelfUpdate.parseContentRange("items 0-0/10"))
        assertNull(SelfUpdate.parseContentRange(null))
    }

    @Test
    fun `版本比较按数字段而不是字典序`() {
        assertTrue(SelfUpdate.isNewer("1.0.10", "1.0.9"))
        assertFalse(SelfUpdate.isNewer("1.0.9", "1.0.10"))
        assertFalse(SelfUpdate.isNewer("1.0.8", "1.0.8"))
    }
}
