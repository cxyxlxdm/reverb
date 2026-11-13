package com.yuyin.reverb.widget

import android.content.Context
import com.yuyin.reverb.util.Logger
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * 小组件与播放器之间那一格**极小的跨进程状态**:当前是不是在播。
 *
 * 为什么不能从已有的两份文件推出来:
 *  - `playback_state.json` 只有「哪一集」,没有播放态;
 *  - `history.json` 的 `positionMs` 在暂停后仍有值,「有进度」不等于「正在播」。
 * 而卡片上的播放键要画 ▶ 还是 ❚❚,只能靠这一位。
 *
 * 口径与鸿蒙 `WidgetRuntime` 的 `widget_state.json` 保持一致(只写一个布尔),
 * 这样两端排障时是同一件事、同一个文件名。文件很小,但写盘仍放到后台线程 ——
 * 它挂在 `onIsPlayingChanged` 上,那条回调里已经有落盘与重绘,不该再添一次主线程 IO。
 *
 * **进程内去重**:同一个值只落一次盘。播放中 `onIsPlayingChanged` 不会反复触发,
 * 但启动期 `syncOnce` 与紧随其后的首个回调可能给出同一个值。
 *
 * ⚠️ 已知边界(与鸿蒙同一条):进程被系统杀掉时若正在播放,盘上留下的是 `playing=true`;
 * App 下次启动连上控制器后 `syncOnce` 会用真实状态覆盖它。在那之前卡片可能显示 ❚❚,
 * 而声音其实已经没了 —— 这是"没有常驻进程可靠地知道服务状态"的代价,不是写错了。
 */
object WidgetRuntime {
    private const val FILE = "widget_state.json"
    private const val KEY_PLAYING = "playing"

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "reverb-widget-state").apply { isDaemon = true }
    }
    private val lock = Any()

    /** 本进程最后一次**成功提交**给写线程的值;null = 还没写过。 */
    private var lastCommitted: Boolean? = null

    fun readPlaying(context: Context): Boolean {
        val file = File(context.filesDir, FILE)
        val text = runCatching { if (file.exists()) file.readText() else "" }.getOrDefault("")
        if (text.isBlank()) return false
        return runCatching { JSONObject(text).optBoolean(KEY_PLAYING, false) }.getOrDefault(false)
    }

    fun writePlaying(context: Context, playing: Boolean) {
        synchronized(lock) {
            if (lastCommitted == playing) return
            lastCommitted = playing
        }
        val app = context.applicationContext
        executor.execute {
            runCatching {
                File(app.filesDir, FILE).writeText(
                    JSONObject().put(KEY_PLAYING, playing).toString()
                )
            }.onFailure { Logger.e("Widget", "小组件播放态写入失败 playing=$playing", it) }
        }
    }
}
