package com.yuyin.reverb.widget

import android.content.Context
import com.yuyin.reverb.data.local.EpisodeJson
import com.yuyin.reverb.data.model.Episode
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** 小组件要画的那一集;只读快照,不碰播放器。 */
data class WidgetEpisode(
    val id: String,
    val title: String,
    val podcastTitle: String,
    val artworkUrl: String,
    val positionMs: Long,
    val durationMs: Long,
    val live: Boolean
) {
    val hasProgress: Boolean get() = !live && durationMs > 0
    val percent: Int
        get() = if (durationMs > 0) (positionMs * 1000 / durationMs).toInt().coerceIn(0, 1000) else 0
}

/**
 * 小组件的数据源:**App 已经在写的两份本地文件**,不初始化播放器、不联网。
 *
 * 为什么不复用 [com.yuyin.reverb.playback.PlayerController] 或 AppContainer:
 * 小组件是系统随时可能单独拉起的一次性进程,初始化容器会把网络探针、WorkManager、
 * 播放服务一起拉起来 —— 而它只需要「上次听到哪一集、听到第几秒」。
 *
 *  - `playback_state.json` 的 `current`:跨启动恢复用的同一份口径,冷启动后仍在;
 *  - `history.json`:同一集的 `positionMs` / `durationMs`,播放中每约 5 秒落一次。
 *
 * 两份都是只读;未同意隐私时它们本来就还没有内容,于是小组件只显示空态,
 * 不会产生任何外部请求(与「隐私同意门在架构层」那条约束一致)。
 */
object WidgetState {
    fun read(context: Context): WidgetEpisode? {
        val dir = context.filesDir
        val current = readCurrent(File(dir, "playback_state.json"))
        val history = readHistory(File(dir, "history.json"))
        if (current != null) {
            val row = history.firstOrNull { it.episode.id == current.id }
            val duration = row?.durationMs?.takeIf { it > 0 } ?: (current.durationSec * 1000)
            return WidgetEpisode(
                id = current.id,
                title = current.title,
                podcastTitle = current.podcastTitle,
                artworkUrl = current.artworkUrl,
                positionMs = (row?.positionMs ?: 0L).coerceAtLeast(0),
                durationMs = duration.coerceAtLeast(0),
                live = current.isLive
            )
        }
        // current 被清掉时(播完 / 退电台)退回「继续收听」同一条筛选:
        // 10s..95% 且未播完 —— 与发现页那条横条一个口径,不另立一套门槛。
        val row = history.firstOrNull {
            !it.played && it.durationMs > 0 &&
                it.positionMs in 10_000..(it.durationMs * 0.95).toLong()
        } ?: return null
        return WidgetEpisode(
            id = row.episode.id,
            title = row.episode.title,
            podcastTitle = row.episode.podcastTitle,
            artworkUrl = row.episode.artworkUrl,
            positionMs = row.positionMs,
            durationMs = row.durationMs,
            live = row.episode.isLive
        )
    }

    private fun readCurrent(file: File): Episode? {
        val text = runCatching { if (file.exists()) file.readText() else "" }.getOrDefault("")
        if (text.isBlank()) return null
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        if (root.optInt("version", 1) > 1) return null
        val obj = root.optJSONObject("current") ?: return null
        val ep = runCatching { EpisodeJson.fromJson(obj) }.getOrNull() ?: return null
        return ep.takeIf { it.audioUrl.isNotBlank() }
    }

    private data class Row(
        val episode: Episode,
        val positionMs: Long,
        val durationMs: Long,
        val played: Boolean
    )

    private fun readHistory(file: File): List<Row> {
        val text = runCatching { if (file.exists()) file.readText() else "" }.getOrDefault("")
        if (text.isBlank()) return emptyList()
        val arr = runCatching { JSONArray(text) }.getOrNull() ?: return emptyList()
        val out = ArrayList<Row>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val epObj = o.optJSONObject("episode") ?: continue
            val ep = runCatching { EpisodeJson.fromJson(epObj) }.getOrNull() ?: continue
            if (ep.audioUrl.isBlank()) continue
            out.add(
                Row(
                    episode = ep,
                    positionMs = o.optLong("positionMs"),
                    durationMs = o.optLong("durationMs"),
                    played = o.optBoolean("played")
                )
            )
        }
        return out
    }
}
