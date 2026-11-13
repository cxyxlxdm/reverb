package com.yuyin.reverb.util

import android.content.Context
import android.net.ConnectivityManager
import com.yuyin.reverb.data.local.SettingsStore

/**
 * 「这次擅自的大流量该不该被计费链路拦下」的**唯一判据**。
 *
 * 为什么要单独成一个东西(见 REVIEW-2026-10-25 中-3):同一段三条判据原先**抄了两份**
 * (`DownloadManager.blockedByCellular` 与 `AudioCacheManager.blockedByCellular`),而第三条
 * 大流量路径 —— 本机识别前要下的那一整集音频(`SenseVoiceEngine.downloadToCache`,几十 MB) ——
 * 根本没接闸门:用户关了「仅在 Wi-Fi 下载」,下载与缓存都老实用 Wi-Fi,
 * 只有"转逐字稿"这一条会在蜂窝上悄悄跑掉一整集的流量。
 * 判据抄第二份的时候漏第三个调用点是必然的,不是偶然(体检总结的「靠调用点自律的规矩必漏」)。
 *
 * 判据口径与原来那两份**完全一致,一个字都没改**:
 *  - 用 `isActiveNetworkMetered` 而不是「bearer 是不是 Wi-Fi」—— 限量热点是计费的 Wi-Fi,要拦;
 *    以太网/免流链路不是 Wi-Fi 但不计费,放行。
 *  - **鸿蒙侧与这条不等价**(2026-10-09 实测:那边连着 Wi-Fi 也不上报 `NET_CAPABILITY_NOT_METERED`,
 *    计费信号在 ArkTS 拿不到,只能按 `bearerTypes` 判「是不是蜂窝」)⇒ 限量热点 Android 拦、鸿蒙放行。
 *    **不要把它"修一致"**,除非先在鸿蒙上把计费信号真取出来(见 H166)。
 *  - 两个取不到的方向也照原样:**settings 读不到按「不允许」**(默认就是只 Wi-Fi),
 *    **ConnectivityManager 取不到则放行**(宁可少拦一次,也不把功能整个钉死)。
 */
object CellularGate {

    /** @param ctx 传应用或 Activity 上下文都可以,内部取 applicationContext;传 null 视为取不到 → 放行 */
    fun blocked(settings: SettingsStore?, ctx: Context?): Boolean {
        val allow = settings?.allowCellularDownload?.value ?: false
        if (allow) return false
        val appCtx = ctx?.applicationContext ?: return false
        val cm = runCatching { appCtx.getSystemService(ConnectivityManager::class.java) }.getOrNull()
        return cm?.isActiveNetworkMetered == true
    }
}
