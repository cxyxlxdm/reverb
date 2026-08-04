package com.yuyin.reverb.util

import android.content.Context
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * 全链路持久化日志:把关键节点的运行轨迹带时间戳、分级、分类写入应用私有文件,
 * 便于「偶发、难复现」的问题事后回看,并支持在设置里一键导出/分享给开发者。
 *
 * - 落盘文件:filesDir/logs/reverb.log,超过约 1.5MB 轮转为 reverb.1.log(仅保留上一份)。
 * - 写入串行化(单线程 executor),绝不阻塞 UI;任何异常都被吞掉,日志本身不会拖垮 App。
 * - 同时镜像到 android.util.Log,方便本地 adb logcat 观察。
 */
object Logger {

    private const val MAX_BYTES = 1_500_000L // ~1.5MB 轮转阈值
    private const val DIR = "logs"
    private const val FILE = "reverb.log"
    private const val PREV_FILE = "reverb.1.log"
    private const val LOGCAT_TAG = "Reverb"

    private val timeFmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "reverb-logger").apply { isDaemon = true } }

    @Volatile private var logDir: File? = null
    @Volatile private var current: File? = null

    /** 由 ReverbApp.onCreate 调用一次;失败不抛出,仅退化为只写 logcat。 */
    fun init(context: Context) {
        try {
            val dir = File(context.applicationContext.filesDir, DIR).apply { mkdirs() }
            logDir = dir
            current = File(dir, FILE)
        } catch (e: Exception) {
            Log.w(LOGCAT_TAG, "Logger.init failed", e)
        }
    }

    fun d(tag: String, msg: String) = write("D", tag, msg, null)
    fun i(tag: String, msg: String) = write("I", tag, msg, null)
    fun w(tag: String, msg: String) = write("W", tag, msg, null)
    fun e(tag: String, msg: String, throwable: Throwable? = null) = write("E", tag, msg, throwable)

    private fun write(level: String, tag: String, msg: String, t: Throwable?) {
        // 时间戳在提交时取,顺序更贴近真实发生时刻
        val ts = try { timeFmt.format(Date()) } catch (e: Exception) { "" }
        // 先镜像到 logcat(廉价、同步)
        try {
            val cat = "$LOGCAT_TAG/$tag"
            when (level) {
                "D" -> if (t != null) Log.d(cat, msg, t) else Log.d(cat, msg)
                "I" -> if (t != null) Log.i(cat, msg, t) else Log.i(cat, msg)
                "W" -> if (t != null) Log.w(cat, msg, t) else Log.w(cat, msg)
                else -> if (t != null) Log.e(cat, msg, t) else Log.e(cat, msg)
            }
        } catch (e: Exception) {
            // 单测/无 android 环境时忽略
        }
        val line = buildString {
            append(ts).append(" [").append(level).append("] [").append(tag).append("] ").append(msg)
            if (t != null) {
                append('\n')
                append(stackTraceToString(t))
            }
            append('\n')
        }
        try {
            writer.execute { appendLine(line) }
        } catch (e: Exception) {
            // executor 已关闭等极端情况,忽略
        }
    }

    private fun appendLine(line: String) {
        val file = current ?: return
        try {
            if (file.length() >= MAX_BYTES) rotate(file)
            file.appendText(line)
        } catch (e: Exception) {
            // 磁盘满/权限等,忽略,绝不影响业务
        }
    }

    private fun rotate(file: File) {
        try {
            val dir = logDir ?: file.parentFile ?: return
            val prev = File(dir, PREV_FILE)
            if (prev.exists()) prev.delete()
            file.renameTo(prev)
            // renameTo 后 current 指向的路径已空,后续 appendText 会重新创建
        } catch (e: Exception) {
            // 轮转失败则清空当前文件兜底,避免无限增长
            runCatching { file.writeText("") }
        }
    }

    /** 当前正在写入的日志文件(可能尚不存在)。 */
    fun currentFile(): File = current ?: File(logDir ?: File("."), FILE)

    /** 上一份 + 当前份的全部文本(旧的在前),用于导出/分享。 */
    fun allText(): String {
        return try {
            val dir = logDir ?: return ""
            val sb = StringBuilder()
            val prev = File(dir, PREV_FILE)
            if (prev.exists()) sb.append(prev.readText())
            val cur = File(dir, FILE)
            if (cur.exists()) sb.append(cur.readText())
            sb.toString()
        } catch (e: Exception) {
            ""
        }
    }

    /** 当前 + 上一份日志占用的字节数。 */
    fun sizeBytes(): Long {
        return try {
            val dir = logDir ?: return 0L
            var n = 0L
            File(dir, FILE).let { if (it.exists()) n += it.length() }
            File(dir, PREV_FILE).let { if (it.exists()) n += it.length() }
            n
        } catch (e: Exception) {
            0L
        }
    }

    /** 清空全部日志。 */
    fun clear() {
        try {
            val dir = logDir ?: return
            File(dir, PREV_FILE).delete()
            File(dir, FILE).writeText("")
        } catch (e: Exception) {
            // 忽略
        }
    }

    private fun stackTraceToString(t: Throwable): String = try {
        val sw = StringWriter()
        t.printStackTrace(PrintWriter(sw))
        sw.toString().trimEnd()
    } catch (e: Exception) {
        t.toString()
    }
}
