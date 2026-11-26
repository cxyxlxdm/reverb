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
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.playback.PlayerController
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

    /**
     * 卡片上的三颗键走**显式广播**回到这里,而不是拉起界面:
     * 点键只动播放态,用户应该继续停在桌面(与鸿蒙 `postCardAction { action: 'call' }` 同一分工)。
     *
     * `goAsync()` 是必须的:冷启动时 `PlayerController` 连上服务要几百毫秒,
     * `onReceive` 一返回系统就可能回收广播,动作会凭空消失。它最多把这次广播多留 ~10 秒,
     * 我们自己的等待上限是 6 秒(见 [PlayerController.runWhenReady])。
     */
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_TOGGLE, ACTION_PREV, ACTION_NEXT -> {
                val app = context.applicationContext
                val pending = goAsync()
                handleControl(app, intent.action.orEmpty(), intent.getStringExtra(EXTRA_EPISODE)) {
                    pending.finish()
                }
            }
            else -> super.onReceive(context, intent)
        }
    }

    companion object {
        const val ACTION_TOGGLE = "com.yuyin.reverb.widget.TOGGLE"
        const val ACTION_PREV = "com.yuyin.reverb.widget.PREV"
        const val ACTION_NEXT = "com.yuyin.reverb.widget.NEXT"
        const val EXTRA_EPISODE = "episode_id"

        private val executor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "reverb-widget").apply { isDaemon = true }
        }

        /**
         * 卡片按键的动作体。三项前置条件按顺序:
         *  ① **隐私同意门**:连播放器会创建 ExoPlayer,media3 内部会读系统网络状态;
         *     未同意时一个动作都不许做(与 `MainActivity.startGatedComponents` 同一条门)。
         *  ② 控制器没起来就先 `init` —— 小组件进程可能在 App 没运行时被单独拉起,
         *     而 `ReverbApp.onCreate` 已经绑好历史 / 设置 / 播放态,只差这一步连接。
         *  ③ 控制器与恢复都要等到位再动作:冷启动时 `restoreState` 是异步的,
         *     早一步按下播放键会对着"还没装载的播放器"操作,表现为点了没反应。
         *
         * 当前集为空时(盘上没有可恢复的会话)**退回打开播放页**,不让按键变成死键;
         * 其余两档没有可切的对象,只记一条日志。
         */
        private fun handleControl(
            app: Context,
            action: String,
            episodeId: String?,
            done: () -> Unit
        ) {
            val container = (app as? ReverbApp)?.container
            if (container == null || !container.settingsStore.privacyAccepted.value) {
                Logger.w("Widget", "卡片按键忽略:$action(未同意隐私或容器不可用)")
                done()
                return
            }
            PlayerController.init(app)
            PlayerController.runWhenReady(
                timeoutMs = 6_000,
                onTimeout = {
                    Logger.w("Widget", "卡片按键超时:$action")
                    done()
                }
            ) {
                try {
                    val cur = PlayerController.current.value
                    Logger.i("Widget", "卡片按键 $action cur=${cur?.id ?: "-"}")
                    when (action) {
                        ACTION_TOGGLE -> if (cur != null) {
                            PlayerController.togglePlayPause()
                        } else {
                            // 没有会话:退回播放页。带 episodeId 时由 MainActivity 负责装载;
                            // 不带的话 App 内会按空态处理。
                            app.startActivity(
                                Intent(app, MainActivity::class.java).apply {
                                    putExtra(MainActivity.EXTRA_OPEN_PLAYER, true)
                                    if (!episodeId.isNullOrBlank()) {
                                        putExtra(MainActivity.EXTRA_OPEN_EPISODE, episodeId)
                                    }
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                                }
                            )
                        }
                        ACTION_PREV -> if (cur != null) PlayerController.previous()
                        ACTION_NEXT -> if (cur != null) PlayerController.next()
                    }
                } catch (e: Exception) {
                    Logger.e("Widget", "卡片按键失败:$action", e)
                } finally {
                    done()
                }
            }
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
            // 播放态来自独立的 `widget_state.json`(见 WidgetRuntime):两份播放数据文件
            // 里都没有「正在播」这一位,不能靠有进度来推。
            val playing = WidgetRuntime.readPlaying(app)
            val artKey = if (SettingsStore(app).thirdPartyContentEnabled.value) {
                state?.artworkUrl.orEmpty()
            } else {
                ""
            }
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
                mgr.updateAppWidget(id, build(app, state, layout, art, playing))
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
            art: android.graphics.Bitmap?,
            playing: Boolean
        ): RemoteViews {
            val rv = RemoteViews(app.packageName, layout)
            // 两种排法的控件不是同一组 id:2×2 只有封面上的播放键,4×2 / 4×4 才有那一行三颗键。
            // **不能对不存在的 id 发 RemoteViews 动作** —— 宿主 apply 时会整条抛 ActionException。
            val rowControls = layout == R.layout.widget_large || layout == R.layout.widget_medium
            // 标签行已删(与鸿蒙 H269 同一条:它不携带信息,还占 2×2 最缺的那一行)。
            if (state == null) {
                rv.setTextViewText(R.id.widget_title, app.getString(R.string.widget_empty_title))
                rv.setTextViewText(R.id.widget_podcast, app.getString(R.string.widget_empty_sub))
                rv.setViewVisibility(R.id.widget_progress, View.GONE)
                rv.setViewVisibility(R.id.widget_time, View.GONE)
                // 空态不藏封面:大卡与竖卡里它是 weight=1 的主区域,藏掉会让文字全挤到顶上、
                // 下面空半张卡片。放应用图标当占位,卡片才像一个完整的设计。
                rv.setViewVisibility(R.id.widget_art, View.VISIBLE)
                rv.setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)
                // 空态三颗键全部藏掉:没有可播放 / 可切换的对象,亮着只会被当成坏键。
                if (rowControls) {
                    rv.setViewVisibility(R.id.widget_prev, View.GONE)
                    rv.setViewVisibility(R.id.widget_toggle, View.GONE)
                    rv.setViewVisibility(R.id.widget_next, View.GONE)
                } else {
                    rv.setViewVisibility(R.id.widget_toggle, View.GONE)
                }
                rv.setContentDescription(
                    R.id.widget_root,
                    "${app.getString(R.string.widget_empty_title)} · ${app.getString(R.string.widget_empty_sub)}"
                )
            } else {
                rv.setTextViewText(R.id.widget_title, state.title)
                rv.setTextViewText(
                    R.id.widget_podcast,
                    state.podcastTitle.ifBlank { app.getString(R.string.unknown_channel) }
                )
                if (state.hasProgress) {
                    rv.setViewVisibility(R.id.widget_progress, View.VISIBLE)
                    // 0..1000 = 0.1% 一档:80 分钟的节目一格约 4 秒,5 秒推一次时读数连续
                    // (与鸿蒙 H267 的 percent 精度同一档)。
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
                // 播放 / 暂停图标由 `widget_state.json` 决定;上一首 / 下一首在本集没有队列时
                // 仍可点(PlayerController 会按频道缓存补上下文,见 expandContextFromFeed)——
                // 补不出来时它只是没有动作,不如藏起来诚实,但那样会让一排键在播放中闪断,
                // 所以这里保持显示,由播放器决定能不能走。
                val toggleIcon = if (playing) R.drawable.widget_ic_pause else R.drawable.widget_ic_play
                val toggleDesc = app.getString(if (playing) R.string.a11y_pause else R.string.a11y_play)
                rv.setImageViewResource(R.id.widget_toggle, toggleIcon)
                rv.setContentDescription(R.id.widget_toggle, toggleDesc)
                rv.setOnClickPendingIntent(
                    R.id.widget_toggle,
                    controlIntent(app, ACTION_TOGGLE, state.id)
                )
                if (rowControls) {
                    rv.setViewVisibility(R.id.widget_prev, View.VISIBLE)
                    rv.setViewVisibility(R.id.widget_toggle, View.VISIBLE)
                    rv.setViewVisibility(R.id.widget_next, View.VISIBLE)
                    rv.setContentDescription(R.id.widget_prev, app.getString(R.string.a11y_prev))
                    rv.setContentDescription(R.id.widget_next, app.getString(R.string.a11y_next))
                    rv.setOnClickPendingIntent(
                        R.id.widget_prev,
                        controlIntent(app, ACTION_PREV, state.id)
                    )
                    rv.setOnClickPendingIntent(
                        R.id.widget_next,
                        controlIntent(app, ACTION_NEXT, state.id)
                    )
                } else {
                    rv.setViewVisibility(R.id.widget_toggle, View.VISIBLE)
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

        /**
         * 控制键的广播。**显式 Intent**(带组件)而不是只给 action:
         * Android 8 起隐式广播受限,而卡片按键必须稳定命中本 Provider。
         * 三个动作各占一个 request code,否则后一个 PendingIntent 会把前一个顶掉。
         */
        private fun controlIntent(app: Context, action: String, episodeId: String?): PendingIntent {
            val intent = Intent(app, ReverbWidgetProvider::class.java).apply {
                setAction(action)
                if (!episodeId.isNullOrBlank()) putExtra(EXTRA_EPISODE, episodeId)
            }
            val request = REQUEST_OPEN + when (action) {
                ACTION_PREV -> 1
                ACTION_NEXT -> 2
                else -> 3
            }
            return PendingIntent.getBroadcast(
                app,
                request,
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
 * 播放/暂停/换集/拖动时请求重绘,进度类更新做 5 秒节流。
 *
 * 为什么是 5 秒(2026-11-12,与鸿蒙 H267 同一读数):
 * 时间行按分钟读,但进度条按 0.1% 一档 —— 80 分钟的节目一格约 4 秒。
 * 原先 20 秒一次,进度条 20 秒才动一格,看起来像"定住了"。
 * 播放中每 500ms 有一个 tick,每 5 秒落一次 history;重绘**错开落盘那一拍**
 * (ticker 里 `%10 == 5`),否则读到的是刚排队还没写下去的那一份,卡片永远落后一跳。
 * 换集 / 播放态变化走 `force`,立刻刷。
 */
object WidgetRefresh {
    private const val PROGRESS_MIN_MS = 5_000L
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
