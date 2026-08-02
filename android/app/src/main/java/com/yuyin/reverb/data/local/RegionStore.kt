package com.yuyin.reverb.data.local

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** 地区偏好：null 表示「自动跟随设备」，否则为两位地区码（小写，如 cn/us/jp）。响应式，供多处共享。 */
class RegionStore(context: Context) {
    private val prefs = context.getSharedPreferences("reverb_prefs", Context.MODE_PRIVATE)

    private val _override = MutableStateFlow(prefs.getString(KEY, null))
    val override: StateFlow<String?> = _override

    fun setOverride(code: String?) {
        prefs.edit().apply {
            if (code.isNullOrBlank()) remove(KEY) else putString(KEY, code)
        }.apply()
        _override.value = if (code.isNullOrBlank()) null else code
    }

    private companion object {
        const val KEY = "region_override"
    }
}
