package com.yuyin.reverb.playback

import android.content.Context
import com.yuyin.reverb.data.local.DownloadStore
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.data.model.DownloadStatus
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.ShortHash
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File

/** 离线下载：OkHttp 流式拉取 enclosure 直链到私有目录，进度以 StateFlow 暴露。 */
object DownloadManager {

    private lateinit var client: OkHttpClient
    private lateinit var store: DownloadStore
    private lateinit var dir: File
    private lateinit var appCtx: Context
    private var settings: SettingsStore? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private const val TAG = "Download"

    private val _states = MutableStateFlow<Map<String, DownloadStatus>>(emptyMap())
    val states: StateFlow<Map<String, DownloadStatus>> = _states

    fun init(context: Context, client: OkHttpClient, store: DownloadStore, settings: SettingsStore) {
        this.client = client
        this.store = store
        this.settings = settings
        this.appCtx = context.applicationContext
        dir = File(context.filesDir, "downloads").apply { mkdirs() }
        _states.value = store.downloads.value.associate { it.episode.id to DownloadStatus.Completed }
    }

    /**
     * 未允许蜂窝下载、且**当前默认网络按用量计费**时拦截。
     *
     * 判据本体已收进 [com.yuyin.reverb.util.CellularGate](为什么必须收:见那里的注释,
     * REVIEW-2026-10-25 中-3)。**这里只留一层转发**,因为调用点与日志都按这个名字写好了,
     * 而"下载"和"缓存"和"转写前下音频"三条路径必须问的是同一个问题。
     */
    private fun blockedByCellular(): Boolean =
        com.yuyin.reverb.util.CellularGate.blocked(settings, if (::appCtx.isInitialized) appCtx else null)

    fun deleteAll() {
        if (!::store.isInitialized) return
        com.yuyin.reverb.util.Logger.i(TAG, "deleteAll count=${store.downloads.value.size}")
        store.downloads.value.forEach { runCatching { File(it.localPath).delete() } }
        store.clearAll()
        _states.value = emptyMap()
    }

    fun usageBytes(): Long =
        if (::store.isInitialized) store.downloads.value.sumOf {
            runCatching { File(it.localPath).length() }.getOrDefault(0L)
        } else 0L

    fun isDownloaded(episodeId: String): Boolean = ::store.isInitialized && store.contains(episodeId)

    fun localPath(episodeId: String): String? =
        if (::store.isInitialized) store.get(episodeId)?.localPath else null

    fun statusOf(episodeId: String): DownloadStatus? = _states.value[episodeId]

    fun download(episode: Episode) {
        if (!::store.isInitialized || episode.audioUrl.isBlank()) return
        val id = episode.id
        if (store.contains(id)) return
        val cur = _states.value[id]
        if (cur is DownloadStatus.Downloading || cur is DownloadStatus.Queued) return

        if (blockedByCellular()) {
            com.yuyin.reverb.util.Logger.w(TAG, "blocked by cellular id=$id")
            setState(id, DownloadStatus.Failed) // 计费网络下已拦;换不计费的链路或关掉开关再重试(见 H162)
            return
        }

        com.yuyin.reverb.util.Logger.i(
            TAG,
            "download start id=$id endpoint=${com.yuyin.reverb.util.Logger.endpoint(episode.audioUrl)}"
        )
        setState(id, DownloadStatus.Queued)
        scope.launch {
            try {
                val target = File(dir, fileName(id, episode.audioUrl))
                val req = Request.Builder()
                    .url(episode.audioUrl)
                    .header("User-Agent", "Reverb/1.0 (Android podcast client)")
                    .build()
                client.newCall(req).execute().use { resp ->
                    val body = resp.body
                    if (!resp.isSuccessful || body == null) {
                        com.yuyin.reverb.util.Logger.w(TAG, "download http ${resp.code} id=$id")
                        setState(id, DownloadStatus.Failed)
                        return@launch
                    }
                    val total = body.contentLength()
                    var read = 0L
                    var milestone = 0 // 已记录到的进度里程碑(25/50/75)
                    body.byteStream().use { input ->
                        target.outputStream().use { out ->
                            val buf = ByteArray(8192)
                            var n: Int
                            while (input.read(buf).also { n = it } != -1) {
                                out.write(buf, 0, n)
                                read += n
                                if (total > 0) {
                                    val pct = ((read.toFloat() / total) * 100).toInt()
                                    if (pct >= milestone + 25 && milestone < 75) {
                                        milestone = (pct / 25) * 25
                                        com.yuyin.reverb.util.Logger.d(TAG, "download progress $milestone% id=$id")
                                    }
                                    setState(id, DownloadStatus.Downloading((read.toFloat() / total).coerceIn(0f, 1f)))
                                }
                            }
                        }
                    }
                    store.add(episode, target.absolutePath)
                    com.yuyin.reverb.util.Logger.i(TAG, "download complete id=$id path=${target.absolutePath} bytes=$read")
                    setState(id, DownloadStatus.Completed)
                }
            } catch (e: Exception) {
                com.yuyin.reverb.util.Logger.e(TAG, "download failed id=$id", e)
                setState(id, DownloadStatus.Failed)
            }
        }
    }

    fun delete(episodeId: String) {
        com.yuyin.reverb.util.Logger.i(TAG, "delete id=$episodeId")
        store.get(episodeId)?.let { runCatching { File(it.localPath).delete() } }
        store.remove(episodeId)
        removeState(episodeId)
    }

    private fun setState(id: String, s: DownloadStatus) {
        _states.value = _states.value.toMutableMap().apply { put(id, s) }
    }

    private fun removeState(id: String) {
        _states.value = _states.value.toMutableMap().apply { remove(id) }
    }

    private fun fileName(id: String, url: String): String {
        val ext = when {
            url.contains(".m4a", true) -> ".m4a"
            url.contains(".aac", true) -> ".aac"
            url.contains(".ogg", true) -> ".ogg"
            url.contains(".wav", true) -> ".wav"
            else -> ".mp3"
        }
        // 为什么不用 String.hashCode():它是 32 位,按生日悖论约 7.7 万个 id 就有 50% 概率撞一对,
        // 撞上后两集共用一个文件 —— 表现为"下载 A 却听到 B",而且账本里两条记录都自称合法,
        // 事后根本查不出来。SHA-256 截 16 个 hex(64 位)把量级推到十亿级。见 REVIEW-2026-10-25 低·族 A。
        // 迁移:这里只决定磁盘文件名,而 DownloadStore 账本存的是 localPath 绝对路径原文,
        // 没有按文件名反查 id 的地方,所以旧文件改名前后都能照常播、不会变孤儿。
        // 短名不进备份 JSON,不是跨端契约的一部分(见 AGENTS.md 的备份格式约束)。
        return "dl_" + ShortHash.hex16(id) + ext
    }
}
