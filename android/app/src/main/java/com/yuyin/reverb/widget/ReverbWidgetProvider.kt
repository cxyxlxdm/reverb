package com.yuyin.reverb.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.yuyin.reverb.MainActivity
import com.yuyin.reverb.R
import com.yuyin.reverb.util.Logger
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * 「继续收听」小组件:三种尺寸、四种排法,共用一套 id,按宿主给的格子尺寸选布局。
 *
 *  - 2×2(方)→ [R.layout.widget_small](左封面缩略图 + 右文字 + 进度)
 *  - 2×2(竖高)→ [R.layout.widget_small_tall](海报在上 + 文字在下 + 进度)
 *  - 4×2 → [R.layout.widget_medium](左封面、右文字,横向)
 *  - 2×4 / 4×4 → [R.layout.widget_large](大封面 + 文字 + 进度,纵向)
 *
 * 尺寸判定只看系统给的格子尺寸(dp),不看屏幕宽度 ——
 * 同一台机器上用户可以拉出任意一格,判据必须跟着那一格走。
 *
 * 所有绘制都在单线程 executor 上做:读两份 JSON(history 可达几百 KB)+ 解一张封面,
 * 不该占主线程,也不该让 `onUpdate` 卡在 10 秒预算的边上。
 * 系统随时可能只为了刷新小组件而拉起本进程,所以这里**不初始化 AppContainer**。
 */
class ReverbWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        renderAll(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle
    ) {
        renderAll(context)
    }

    override fun onEnabled(context: Context) {
        renderAll(context)
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "reverb-widget").apply { isDaemon = true }
        }

        /** App 内播放状态变化时调用;真正的重绘在后台线程,调用方不会被 IO 挡住。 */
        fun renderAll(context: Context) {
            val app = context.applicationContext
            executor.execute {
                runCatching { render(app) }
                    .onFailure { Logger.e("Widget", "小组件刷新失败", it) }
            }
        }

        private fun render(app: Context) {
            val mgr = AppWidgetManager.getInstance(app)
            val ids = mgr.getAppWidgetIds(ComponentName(app, ReverbWidgetProvider::class.java))
            if (ids.isEmpty()) return
            // 一次刷新只读一遍文件:同一批 id 共用同一份状态与同一张解好的封面。
            val state = WidgetState.read(app)
            val artKey = state?.artworkUrl.orEmpty()
            var art: android.graphics.Bitmap? = null
            var artTried = false
            for (id in ids) {
                val opts = mgr.getAppWidgetOptions(id)
                val (w, h) = reportedSize(app, opts)
                val (layout, artDp) = choose(w, h)
                Logger.i("Widget", "id=$id ${w}x${h}dp layout=$layout")
                if (!artTried && artKey.isNotEmpty()) {
                    // 只试一次:缓存里没有就退回应用图标,别为同一张图逐个 id 重跑解码。
                    artTried = true
                    val px = (artDp * app.resources.displayMetrics.density).toInt()
                    art = WidgetArtwork.load(app, artKey, px)
                }
                mgr.updateAppWidget(id, build(app, state, layout, art))
            }
        }

        /**
         * 阈值取 220dp 而不是「四列/四行」的名义宽度:宿主上报的尺寸会扣掉格子内边距,
         * 这台 Pixel 3 上 4 列的卡片报 276dp、4 行报 317dp,而 2×2 约 120×150。
         *
         * 尺寸不能只看 minWidth/minHeight:那两个是**两个方向的最小值**(实测 4×3 竖卡报成
         * 276×186,于是竖卡被认成横卡)。API 31+ 的 `appWidgetSizes` 才是当前可占的每一档,
         * 取与屏幕同方向、面积最大的那一档。
         */
        private fun choose(w: Int, h: Int): Pair<Int, Int> {
            return when {
                // 4×4 / 2×4:纵向卡片,封面按格子宽度裁,最多 320dp
                w >= 220 && h >= 220 -> R.layout.widget_large to min(320, w)
                h >= 220 -> R.layout.widget_large to min(320, maxOf(110, w))
                // 4×2:横向卡片
                w >= 220 -> R.layout.widget_medium to 168
                // 2×2 的两种形状分开画:同一台桌面拉出来的 2×2 是「窄而高」(实测 130×206dp),
                // 左封面 + 右文字会挤成中间一条、上下各留一大块空白;竖排让海报当主角。
                // 别用固定高度 220dp 判:2×2 报上来的高度是 206,永远到不了那个阈值。
                h * 10 >= w * 13 -> R.layout.widget_small_tall to w
                else -> R.layout.widget_small to 96
            }
        }

        @Suppress("DEPRECATION")
        private fun reportedSize(app: Context, opts: Bundle): Pair<Int, Int> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val sizes = if (Build.VERSION.SDK_INT >= 33) {
                    opts.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
                } else {
                    opts.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                }
                val portrait = app.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
                val sameWay = sizes
                    ?.filter { (it.height >= it.width) == portrait }
                    ?.maxByOrNull { it.width * it.height }
                if (sameWay != null) return sameWay.width.toInt() to sameWay.height.toInt()
            }
            return opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 110) to
                opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110)
        }

        private fun build(
            app: Context,
            state: WidgetEpisode?,
            layout: Int,
            art: android.graphics.Bitmap?
        ): RemoteViews {
            val rv = RemoteViews(app.packageName, layout)
            if (state == null) {
                rv.setTextViewText(R.id.widget_label, app.getString(R.string.widget_continue))
                rv.setTextViewText(R.id.widget_title, app.getString(R.string.widget_empty_title))
                rv.setTextViewText(R.id.widget_podcast, app.getString(R.string.widget_empty_sub))
                rv.setViewVisibility(R.id.widget_progress, View.GONE)
                rv.setViewVisibility(R.id.widget_time, View.GONE)
                // 空态不藏封面:大卡与竖卡里它是 weight=1 的主区域,藏掉会让文字全挤到顶上、
                // 下面空半张卡片。放应用图标当占位,卡片才像一个完整的设计。
                rv.setViewVisibility(R.id.widget_art, View.VISIBLE)
                rv.setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)
                rv.setContentDescription(
                    R.id.widget_root,
                    "${app.getString(R.string.widget_empty_title)} · ${app.getString(R.string.widget_empty_sub)}"
                )
            } else {
                rv.setTextViewText(R.id.widget_label, app.getString(R.string.widget_continue))
                rv.setTextViewText(R.id.widget_title, state.title)
                rv.setTextViewText(
                    R.id.widget_podcast,
                    state.podcastTitle.ifBlank { app.getString(R.string.unknown_channel) }
                )
                if (state.hasProgress) {
                    rv.setViewVisibility(R.id.widget_progress, View.VISIBLE)
                    rv.setProgressBar(R.id.widget_progress, 1000, state.percent, false)
                    rv.setViewVisibility(R.id.widget_time, View.VISIBLE)
                    rv.setTextViewText(
                        R.id.widget_time,
                        app.getString(
                            R.string.widget_progress_time,
                            clock(state.positionMs),
                            clock(state.durationMs)
                        )
                    )
                } else {
                    rv.setViewVisibility(R.id.widget_progress, View.GONE)
                    if (state.live) {
                        rv.setViewVisibility(R.id.widget_time, View.VISIBLE)
                        rv.setTextViewText(R.id.widget_time, app.getString(R.string.widget_live))
                    } else {
                        rv.setViewVisibility(R.id.widget_time, View.GONE)
                    }
                }
                if (art != null) {
                    rv.setViewVisibility(R.id.widget_art, View.VISIBLE)
                    rv.setImageViewBitmap(R.id.widget_art, art)
                } else {
                    rv.setViewVisibility(R.id.widget_art, View.VISIBLE)
                    rv.setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)
                }
                val time = if (state.hasProgress) {
                    app.getString(
                        R.string.widget_progress_time,
                        clock(state.positionMs),
                        clock(state.durationMs)
                    )
                } else if (state.live) app.getString(R.string.widget_live) else ""
                rv.setContentDescription(
                    R.id.widget_root,
                    listOf(state.title, state.podcastTitle, time).filter { it.isNotBlank() }.joinToString(" · ")
                )
            }
            rv.setOnClickPendingIntent(R.id.widget_root, openIntent(app, state?.id))
            return rv
        }

        /**
         * 复用通知栏那条「打开播放页」的入口([MainActivity.EXTRA_OPEN_PLAYER]),
         * 另外带上这一集的 id:冷启动时 playback_state 可能是空的(小组件那条来自历史),
         * 不带 id 的话播放页没有「当前集」可画,点了只会停在发现页。
         *
         * **不自动播放**:App 侧拿到 id 走 PlayerController.prepare —— 装载成暂停态,
         * 按下播放键才出声(产品口径,见该方法的注释)。
         */
        private fun openIntent(app: Context, episodeId: String?): PendingIntent {
            val intent = Intent(app, MainActivity::class.java).apply {
                putExtra(MainActivity.EXTRA_OPEN_PLAYER, true)
                if (!episodeId.isNullOrBlank()) putExtra(MainActivity.EXTRA_OPEN_EPISODE, episodeId)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            return PendingIntent.getActivity(
                app,
                REQUEST_OPEN,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        private const val REQUEST_OPEN = 0x5701

        internal fun clock(ms: Long): String {
            val total = (ms.coerceAtLeast(0) / 1000)
            val h = total / 3600
            val m = (total % 3600) / 60
            val s = total % 60
            return if (h > 0) String.format(Locale.getDefault(), "%d:%02d:%02d", h, m, s)
            else String.format(Locale.getDefault(), "%d:%02d", m, s)
        }
    }
}

/**
 * 播放/暂停/换集/拖动时请求重绘,进度类更新做 20 秒节流。
 *
 * 为什么需要节流:播放中每 500ms 有一个 tick,而每 5 秒会落一次 history 进度;
 * 如果每次落盘都重绘,系统每分钟要处理十几次小组件更新,而进度条的时间文字只到分钟级,
 * 20 秒一次已经看不出延迟。换集 / 播放态变化走 `force`,立刻刷。
 */
object WidgetRefresh {
    private const val PROGRESS_MIN_MS = 20_000L
    private val handler = Handler(Looper.getMainLooper())
    private var lastRunAtMs = 0L
    private var pending = false

    fun request(context: Context, force: Boolean = false, delayMs: Long = 0) {
        val app = context.applicationContext
        if (delayMs > 0) {
            // 拖动/关条之后 history.json 还压在那 400ms 的写去抖里,立刻重绘会读到旧进度。
            handler.postDelayed({ run(app, System.currentTimeMillis()) }, delayMs)
            return
        }
        val now = System.currentTimeMillis()
        if (force) {
            pending = false
            handler.removeCallbacksAndMessages(null)
            run(app, now)
            return
        }
        if (now - lastRunAtMs >= PROGRESS_MIN_MS) {
            run(app, now)
            return
        }
        if (pending) return
        pending = true
        handler.postDelayed({
            pending = false
            run(app, System.currentTimeMillis())
        }, PROGRESS_MIN_MS - (now - lastRunAtMs))
    }

    private fun run(app: Context, now: Long) {
        lastRunAtMs = now
        ReverbWidgetProvider.renderAll(app)
    }
}
