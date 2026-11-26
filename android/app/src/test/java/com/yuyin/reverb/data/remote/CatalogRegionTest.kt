package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.local.RegionStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CatalogRegionTest {
    @Test
    fun `关闭目录时保留设备地区或显式覆盖`() {
        assertEquals("cn", PodcastRepository.catalogRegion(false, null, "CN"))
        assertEquals("hk", PodcastRepository.catalogRegion(false, "HK", "US"))
        assertEquals("us", PodcastRepository.catalogRegion(false, "", ""))
    }

    @Test
    fun `开启目录时空值与港澳台回落美国`() {
        listOf(null, "", "hk", "TW", "mo").forEach { selected ->
            assertEquals("us", PodcastRepository.catalogRegion(true, selected, "CN"))
        }
    }

    @Test
    fun `中国内地只有显式选择时才生效`() {
        assertEquals("cn", PodcastRepository.catalogRegion(true, "CN", "US"))
        assertEquals("us", PodcastRepository.catalogRegion(true, null, "CN"))
    }

    @Test
    fun `其它明确选择的非中文地区保留并归一大小写`() {
        assertEquals("jp", PodcastRepository.catalogRegion(true, "JP", "CN"))
        assertEquals("gb", PodcastRepository.catalogRegion(true, "gb", "US"))
    }

    @Test
    fun `备份里的未知地区码回落自动并在开启时使用美国`() {
        listOf("zh", "zh-CN", "xx", " unknown ").forEach { selected ->
            assertNull(RegionStore.normalize(selected))
            assertEquals("us", PodcastRepository.catalogRegion(true, selected, "CN"))
        }
        assertEquals("cn", RegionStore.normalize(" CN "))
    }
}
