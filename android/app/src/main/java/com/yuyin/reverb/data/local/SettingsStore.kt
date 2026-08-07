package com.yuyin.reverb.data.local

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * 应用设置：主题模式(0 跟随系统/1 浅色/2 深色)、字号倍率、配色索引、
 * 是否允许蜂窝下载、是否开启订阅更新提醒。全部持久化并以 StateFlow 暴露。
 */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("reverb_settings", Context.MODE_PRIVATE)

    val themeMode = MutableStateFlow(prefs.getInt("theme_mode", 2)) // 默认深色（水墨）
    val fontScale = MutableStateFlow(prefs.getFloat("font_scale", 1.0f))
    val accentIndex = MutableStateFlow(prefs.getInt("accent_index", 0))
    val allowCellularDownload = MutableStateFlow(prefs.getBoolean("cellular_dl", false))
    val updatesEnabled = MutableStateFlow(prefs.getBoolean("updates_enabled", true))
    val defaultSpeed = MutableStateFlow(prefs.getFloat("default_speed", 1.0f))
    val skipBackSec = MutableStateFlow(prefs.getInt("skip_back", 10))
    val skipForwardSec = MutableStateFlow(prefs.getInt("skip_fwd", 30))
    val language = MutableStateFlow(prefs.getString("language", "") ?: "") // "" = 跟随系统
    val spectrumEnabled = MutableStateFlow(prefs.getBoolean("spectrum_enabled", false)) // 真实频谱(需录音权限),默认关
    val contextualRadio = MutableStateFlow(prefs.getBoolean("contextual_radio", false)) // 电台模式:false 随机 / true 情境,默认随机
    val subsGrid = MutableStateFlow(prefs.getBoolean("subs_grid", false)) // 订阅排列:false 列表(一行一个)/ true 宫格,默认列表

    fun setThemeMode(v: Int) { prefs.edit().putInt("theme_mode", v).apply(); themeMode.value = v }
    fun setFontScale(v: Float) { prefs.edit().putFloat("font_scale", v).apply(); fontScale.value = v }
    fun setAccentIndex(v: Int) { prefs.edit().putInt("accent_index", v).apply(); accentIndex.value = v }
    fun setAllowCellularDownload(v: Boolean) { prefs.edit().putBoolean("cellular_dl", v).apply(); allowCellularDownload.value = v }
    fun setUpdatesEnabled(v: Boolean) { prefs.edit().putBoolean("updates_enabled", v).apply(); updatesEnabled.value = v }
    fun setDefaultSpeed(v: Float) { prefs.edit().putFloat("default_speed", v).apply(); defaultSpeed.value = v }
    fun setSkipBackSec(v: Int) { prefs.edit().putInt("skip_back", v).apply(); skipBackSec.value = v }
    fun setSkipForwardSec(v: Int) { prefs.edit().putInt("skip_fwd", v).apply(); skipForwardSec.value = v }
    fun setLanguage(tag: String) { prefs.edit().putString("language", tag).apply(); language.value = tag }
    fun setSpectrumEnabled(v: Boolean) { prefs.edit().putBoolean("spectrum_enabled", v).apply(); spectrumEnabled.value = v }
    fun setContextualRadio(v: Boolean) { prefs.edit().putBoolean("contextual_radio", v).apply(); contextualRadio.value = v }
    fun setSubsGrid(v: Boolean) { prefs.edit().putBoolean("subs_grid", v).apply(); subsGrid.value = v }
}
