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
     * 是否已同意**当前版本**的隐私政策。
     *
     * **在同意之前不得初始化任何可能读取系统网络信息的组件** ——媒体库(media3)与
     * WorkManager 内部都会调 ConnectivityManager.getActiveNetworkInfo(),应用市场
     * 把它判定为「获取 SSID」,且要求必须在用户同意之后才可发生。
     * 详见 MainActivity 与 ReverbApp 里的门控。
     *
     * 存的是**已同意的政策版本号**而不是布尔:政策有实质性变更时(新增网络访问点、
     * 新增权限、改变数据用途…),按合规惯例应重新征求同意。把 [PRIVACY_VERSION] +1
     * 即可让所有用户再看一次同意页。
     */
    val privacyAccepted = MutableStateFlow(loadPrivacyAccepted())

    private fun loadPrivacyAccepted(): Boolean {
        val v = prefs.getInt("privacy_version", 0)
        if (v > 0) return v >= PRIVACY_VERSION
        // 兼容早期版本:那时只存了布尔 privacy_accepted。视为已同意版本 1。
        if (prefs.getBoolean("privacy_accepted", false)) {
            prefs.edit().putInt("privacy_version", 1).apply()
            return 1 >= PRIVACY_VERSION
        }
        return false
    }

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

    /**
     * 同意当前版本的隐私政策。
     * 用 commit() 而非 apply():紧接着就要启动此前被门控的组件,不能容忍异步写还没落盘。
     */
    fun acceptPrivacy() {
        prefs.edit().putInt("privacy_version", PRIVACY_VERSION).commit()
        privacyAccepted.value = true
    }

    companion object {
        /**
         * 隐私政策版本。**政策有实质性变更时把这个数 +1**,所有用户会再看一次同意页。
         *
         * 什么算"实质性变更":新增/变更网络访问地址、新增权限、改变数据的收集或用途、
         * 新增会外发数据的功能。纯措辞润色不必 +1。
         *
         * 变更历史:
         *   1 = 首个版本(2026-08)。含:无后端服务、本地存储项、网络访问地址(发布方 RSS /
         *       官网推荐清单 / 可选的公开检索接口)、网络状态权限与 SSID 说明、权限清单。
         *
         * 改这个数之后**必须重新打包**,并同步更新 PRIVACY.md 与 reverb/privacy.html。
         */
        const val PRIVACY_VERSION = 1
    }
}
