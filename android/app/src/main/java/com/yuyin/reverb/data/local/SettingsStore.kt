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
    // 默认**关**:隐私政策写明「仅在你主动开启『订阅更新提醒』时征求你的同意」,
    // 默认开就等于没经用户主动开启便去要通知权限,两者不能同时成立。
    val updatesEnabled = MutableStateFlow(prefs.getBoolean("updates_enabled", false))
    val defaultSpeed = MutableStateFlow(prefs.getFloat("default_speed", 1.0f))
    val skipBackSec = MutableStateFlow(prefs.getInt("skip_back", 10))
    val skipForwardSec = MutableStateFlow(prefs.getInt("skip_fwd", 30))
    val language = MutableStateFlow(prefs.getString("language", "") ?: "") // "" = 跟随系统
    val spectrumEnabled = MutableStateFlow(prefs.getBoolean("spectrum_enabled", false)) // 真实频谱(需录音权限),默认关
    val contextualRadio = MutableStateFlow(prefs.getBoolean("contextual_radio", false)) // 电台模式:false 随机 / true 情境,默认随机
    val subsGrid = MutableStateFlow(prefs.getBoolean("subs_grid", false)) // 订阅排列:false 列表(一行一个)/ true 宫格,默认列表

    /**
     * 是否已同意隐私政策。**在同意之前不得初始化任何可能读取系统网络信息的组件**
     * ——媒体库(media3)与 WorkManager 内部都会调 ConnectivityManager.getActiveNetworkInfo(),
     * 应用市场把它判定为「获取 SSID」,且要求必须在用户同意之后才可发生。
     * 详见 MainActivity 与 ReverbApp 里的门控。
     */
    val privacyAccepted = MutableStateFlow(prefs.getBoolean("privacy_accepted", false))

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

    /** 同意隐私政策。用 commit() 而非 apply():紧接着就要启动此前被门控的组件,不能容忍异步写还没落盘。 */
    fun acceptPrivacy() {
        prefs.edit().putBoolean("privacy_accepted", true).commit()
        privacyAccepted.value = true
    }
}
