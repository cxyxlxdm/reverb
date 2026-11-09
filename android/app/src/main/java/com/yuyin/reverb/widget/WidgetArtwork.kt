package com.yuyin.reverb.widget

import android.content.Context
import android.graphics.Bitmap
import androidx.core.graphics.drawable.toBitmap
import coil.imageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlinx.coroutines.runBlocking

/**
 * 封面只从 **Coil 的缓存**里取(`networkCachePolicy(DISABLED)`),不在小组件里发网络请求。
 *
 * 理由两条:
 *  - 小组件会在用户没打开 App 时被系统拉起,那里不该出现 App 之外的新网络路径;
 *  - 封面在用户点开这一集时已经下载过,磁盘缓存里就有;取不到时退回应用图标即可,
 *    比"为了补一张图把小组件更新拖到超时"划算。
 */
internal object WidgetArtwork {
    fun load(context: Context, url: String, sidePx: Int): Bitmap? {
        if (url.isBlank() || sidePx <= 0) return null
        val request = ImageRequest.Builder(context)
            .data(url)
            .networkCachePolicy(CachePolicy.DISABLED)
            .allowHardware(false)
            .size(sidePx)
            .build()
        val result = runBlocking {
            runCatching { context.imageLoader.execute(request) }.getOrNull()
        }
        val drawable = (result as? SuccessResult)?.drawable ?: return null
        return runCatching {
            drawable.toBitmap(sidePx, sidePx, Bitmap.Config.ARGB_8888)
        }.getOrNull()
    }
}
