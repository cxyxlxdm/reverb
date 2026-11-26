package com.yuyin.reverb.data.local

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** 地区偏好：null 表示「自动跟随设备」，否则为受支持的两字节地区码（小写）。响应式，供多处共享。 */
class RegionStore(context: Context) {
    private val prefs = context.getSharedPreferences("reverb_prefs", Context.MODE_PRIVATE)

    private val _override = MutableStateFlow(RegionStore.normalize(prefs.getString(KEY, null)))
    val override: StateFlow<String?> = _override

    fun setOverride(code: String?) {
        val normalized = RegionStore.normalize(code)
        prefs.edit().apply {
            if (normalized == null) remove(KEY) else putString(KEY, normalized)
        }.apply()
        _override.value = normalized
    }

    companion object {
        private const val KEY = "region_override"
        private val SUPPORTED = setOf("cn", "hk", "tw", "mo", "us", "jp", "kr", "gb", "sg", "au", "ca", "de")

        /** 备份与偏好共用同一入口，未知地区码不能绕过开启后的美国默认值。 */
        fun normalize(code: String?): String? =
            code?.trim()?.lowercase()?.takeIf { it in SUPPORTED }
    }
}
