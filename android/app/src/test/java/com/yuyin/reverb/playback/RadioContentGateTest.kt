package com.yuyin.reverb.playback

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Test

class RadioContentGateTest {
    @Test
    fun `三方内容关闭时随机电台不会进入抓取`() = runBlocking {
        assertFalse(RadioStation.start(RadioStation.Mode.RANDOM))
    }
}
