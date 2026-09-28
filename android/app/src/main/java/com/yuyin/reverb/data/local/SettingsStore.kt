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
    /**
     * 逐字稿功能开关(默认**开**,与 macOS 一致)。
     *
     * 它只管**要不要显示播放页第三页**;真正能不能本机识别取决于渠道有没有引擎
     * (`AsrFactory.HAS_ENGINE`)。大陆商店渠道没有引擎,那边设置页里连这一项都不显示 ——
     * 于是这个值在那个渠道形同虚设,不影响"有官方稿的集照样出第三页"。
     */
    val transcriptionEnabled = MutableStateFlow(prefs.getBoolean("transcription_enabled", true))
    /**
     * 逐字高亮(默认开)。它管两件事:
     * - 界面:当前句是**逐字**上色,还是整句一个颜色;
     * - 本机识别:whisper 要不要额外算 DTW 词级时间戳 —— 那会**多花约 70% 时间**
     *   (冷机实测 1 小时音频 11 分钟 vs 6.5 分钟)。
     *
     * 两个渠道都有这个开关,但**含义不同**:大陆商店渠道没有识别引擎,它只影响
     * 「发布方提供的逐字稿」怎么渲染(那种稿本来就带词级时间,开着不花任何代价);
     * 完整版则要为此多算一遍。副标题因此按渠道分别写(见 src/default|store/res/values-* 各一份)。
     */
    val wordHighlight = MutableStateFlow(prefs.getBoolean("word_highlight", true))
    val contextualRadio = MutableStateFlow(prefs.getBoolean("contextual_radio", false)) // 电台模式:false 随机 / true 情境,默认随机
    val subsGrid = MutableStateFlow(prefs.getBoolean("subs_grid", false)) // 订阅排列:false 列表(一行一个)/ true 宫格,默认列表
    /**
     * 列表播放模式:0 顺序 / 1 单曲循环 / 2 随机。音阁三段(最新 / 收藏 / 下载)与频道主页
     * 右端那颗模式按钮循环切换它,**各处共用一个** —— 与「订阅排列」同理,三把开关只会让人
     * 怀疑自己设错了。
     *
     * ⚠️ 1 这个位置 2026-09-28 之前是「列表循环」,含义换成了「单曲循环」而**存的数没变**
     * (见 `PlayMode` 的注释与 H118)。
     *
     * 这里只存 **ordinal**(枚举本体在 `playback/PlayerController.PlayMode`),
     * 免得数据层反向依赖播放层。新增模式**只能加在枚举末尾**。
     */
    val playMode = MutableStateFlow(prefs.getInt("play_mode", 0))

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
    fun setTranscriptionEnabled(v: Boolean) { prefs.edit().putBoolean("transcription_enabled", v).apply(); transcriptionEnabled.value = v }
    fun setWordHighlight(v: Boolean) { prefs.edit().putBoolean("word_highlight", v).apply(); wordHighlight.value = v }
    fun setContextualRadio(v: Boolean) { prefs.edit().putBoolean("contextual_radio", v).apply(); contextualRadio.value = v }
    fun setSubsGrid(v: Boolean) { prefs.edit().putBoolean("subs_grid", v).apply(); subsGrid.value = v }
    fun setPlayMode(v: Int) { prefs.edit().putInt("play_mode", v).apply(); playMode.value = v }

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
         * 改这个数之后**必须重新打包**,并同步更新 docs/PRIVACY.md 与 reverb/privacy.html。
         */
        const val PRIVACY_VERSION = 1
    }
}
