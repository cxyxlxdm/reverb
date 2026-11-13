package com.yuyin.reverb.util

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment
import java.util.Locale

/**
 * 把逐字稿拼成可以交给系统分享的两种文本:纯文本 / Markdown。
 *
 * **每句都带时间轴**:`[12:03]` 是在播放页点一下就能跳回去的位置。用户在笔记、
 * 邮件或聊天里读到这一句时,能凭它找回原处 —— 去掉时间戳的"干净版"反而没有用处。
 *
 * 这里只做拼装,不碰 IO / Intent(那层在 `TranscriptPane`),于是它能被单测直接盯住。
 *
 * 时间戳的位数按**整篇时长**决定:一小时以内写 `12:03`,超过一小时才写 `1:12:03`。
 * 逐句各判一次会让同一份文件里两种形状混排(前面 `12:03`、后面 `1:02:03`),
 * 看着像两份稿拼起来的。
 */
object TranscriptExport {

    enum class Format(val extension: String, val mime: String) {
        Text("txt", "text/plain"),
        Markdown("md", "text/markdown")
    }

    fun build(episode: Episode, segments: List<TranscribedSegment>, format: Format): String {
        val withHours = (segments.lastOrNull()?.endMs ?: 0) >= HOUR_MS
        val title = oneLine(episode.title).ifBlank { "Transcript" }
        val channel = oneLine(episode.podcastTitle)
        return buildString {
            when (format) {
                Format.Text -> {
                    appendLine(title)
                    if (channel.isNotBlank()) appendLine(channel)
                    appendLine()
                    for (seg in segments) {
                        append('[').append(stamp(seg.startMs, withHours)).append("] ")
                        appendLine(oneLine(seg.text))
                    }
                }
                Format.Markdown -> {
                    appendLine("# $title")
                    appendLine()
                    if (channel.isNotBlank()) {
                        appendLine("_${channel}_")
                        appendLine()
                    }
                    for (seg in segments) {
                        append("- [").append(stamp(seg.startMs, withHours)).append("] ")
                        appendLine(oneLine(seg.text))
                    }
                }
            }
        }
    }

    /** `12:03` 或 `1:12:03`;负数按 0 处理(时间轴上游保证过,但导出不该被一条脏数据带崩)。 */
    fun stamp(ms: Int, withHours: Boolean): String {
        val total = ms.coerceAtLeast(0) / 1000
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (withHours) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s)
        else String.format(Locale.ROOT, "%d:%02d", m, s)
    }

    /**
     * 分享到别的 App 的文件名。去掉路径分隔符与控制字符 —— 一集标题里出现 `/` 或换行
     * 并不罕见(尤其发布方把"第 3 期 / 上"直接当标题),原样落盘会多一层目录或直接抛异常。
     */
    fun fileName(episode: Episode, format: Format): String {
        val base = oneLine(episode.title)
            .replace(INVALID_FILE_CHARS, " ")
            .trim()
            .take(MAX_NAME_CHARS)
            .trim()
            .ifBlank { "transcript" }
        return "$base.${format.extension}"
    }

    /**
     * 一行化。逐字稿本身按句切开,理论上不含换行;但导出是**离开 App 之后**的产物,
     * 一条带 `\n` 的文本会把一批纯文本行拆散、把 Markdown 列表打断,所以在这一道收口。
     */
    private fun oneLine(s: String): String = s.replace(WHITESPACE, " ").trim()

    private val WHITESPACE = Regex("\\s+")
    private val INVALID_FILE_CHARS = Regex("[\\\\/:*?\"<>|\\p{Cntrl}]")
    private const val MAX_NAME_CHARS = 80
    private const val HOUR_MS = 3_600_000
}
