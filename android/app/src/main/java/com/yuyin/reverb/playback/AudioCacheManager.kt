package com.yuyin.reverb.playback

import android.content.Context
import com.yuyin.reverb.data.local.AudioCacheStore
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.ShortHash
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File

/**
 * 播放过的整集音频落到 `filesDir/audio_cache/`,下次直接本地起播、不再联网。
 *
 * 为什么不是「边播边存」:ExoPlayer 的 `CacheDataSource` 能把流过的字节顺手落盘,看着更省流量,
 * 但它存的是**字节区间**,不是完整的一集 —— 用户只听前 3 分钟时,下次从第 20 分钟续播仍要联网,
 * 而这套缓存要给的承诺是「播过就不要再联网」。另外那样等于把播放路径接到缓存层上,
 * 起播失败要能退回纯流式,排查成本高一档(全仓 `CacheDataSource|SimpleCache` 目前为 0,
 * 是有意没引入)。**首播时后台整集拉全**这条:多花一点流量(受同一个蜂窝闸门管),
 * 换来「缓存里的每一集都能整集离线播」,语义简单得多。
 *
 * 三条实现上的硬要求:
 *  1. **写完才认账** —— 先下到 `.part`,成功再 rename 成正式名并记账。
 *     否则进程被杀留下的半截文件会被当成完整缓存,表现是「这集播到一半就没声」,
 *     而用户看到的是一条完全正常的历史记录。
 *  2. **单飞、最新优先** —— 用户连着点开三集,只有最后一集值得下。
 *     同时下三集会在几十 MB 的量级上把带宽和磁盘都打满,而前两集大概率不会再听。
 *  3. **字节预算 + LRU** —— 缓存无上限等于把用户手机当网盘;超预算挤掉最久没听的。
 *
 * 与 [DownloadManager] 完全分开:不同目录、不同账本、不同清理入口。用户点名下载的那份永远不该
 * 被预算挤掉,所以本类**从不读写** `downloads/`。反过来,「清除下载」也删不到这里的文件。
 */
object AudioCacheManager {

    /** 缓存总字节预算。整集 mp3 约 30–60 MB,300 MB 大约容下最近听过的 6–8 集。 */
    private const val BUDGET_BYTES = 300L * 1024 * 1024

    private lateinit var client: OkHttpClient
    private lateinit var store: AudioCacheStore
    private lateinit var dir: File
    private lateinit var appCtx: Context
    private var settings: SettingsStore? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()

    /**
     * 正在拉的那一集(单飞的判据)。
     *
     * **下载循环里每一块都读它一次** —— OkHttp 这里是同步调用,协程 `cancel()` 既不会打断阻塞的
     * socket,也不会让循环自己停(纯字节循环上没有挂起点)。所以「换集就取消上一个」真正生效的
     * 机制是这个字段:被挤掉的那次在下一个 16 KB 看见 `inFlight` 已经不是自己,抛异常收尾。
     */
    @Volatile
    private var inFlight: String? = null
    private var inFlightJob: Job? = null

    private const val TAG = "AudioCache"

    fun init(context: Context, client: OkHttpClient, store: AudioCacheStore, settings: SettingsStore) {
        this.client = client
        this.store = store
        this.settings = settings
        this.appCtx = context.applicationContext
        dir = File(context.filesDir, AudioCacheStore.DIR_NAME).apply { mkdirs() }
        // 账与文件的对账要扫目录、要删孤儿,是 IO;放主线程就是给启动加一次磁盘往返。
        // 晚几毫秒不影响任何东西 —— 起播时的判定只看文件是否存在(见 localPath)。
        scope.launch { reconcile() }
    }

    /**
     * 本地缓存文件路径,**只在文件真存在且非空时**返回。
     *
     * 这里刻意不返回「账本说有」的路径:账本可能比文件新(系统清理了目录、用户手动删过、
     * 备份恢复只搬了账)。把不存在的路径交给播放器 = 一集点了没反应,
     * 而这个界面上没有任何东西能解释「为什么这集突然播不了」。
     */
    fun localPath(episodeId: String): String? {
        if (!::store.isInitialized) return null
        val item = store.get(episodeId) ?: return null
        val f = File(dir, item.fileName)
        return if (f.exists() && f.length() > 0) f.absolutePath else null
    }

    /** 从缓存起播时记一次访问 —— LRU 的依据(账本那边解释过为什么必须在"播"的时候记)。 */
    fun onPlayFromCache(episodeId: String) {
        if (::store.isInitialized) store.touch(episodeId)
    }

    /**
     * 首播走流式时排一次「整集落缓存」。
     *
     * 幂等且**不排队**:已经在缓存里、正在下的、或已被更新的请求挤掉的,一律直接返回。
     *
     * @param headers 取流要带的请求头。视频源那一族必须给(CDN 认 UA + `Referer`,见
     *   [com.yuyin.reverb.data.remote.BilibiliSource] 的 `UA`);不给就沿用本类自己的 UA。
     */
    fun cache(episode: Episode, headers: Map<String, String>? = null) {
        if (!::store.isInitialized) return
        val id = episode.id
        val url = episode.audioUrl
        if (id.isBlank() || url.isBlank()) return
        // 内置引导音频的 URL 是 asset:///android_resource,不是 HTTP enclosure,没什么可缓存的
        if (com.yuyin.reverb.data.model.GuideEpisode.isGuide(id)) return
        if (store.get(id) != null) return
        if (blockedByCellular()) {
            com.yuyin.reverb.util.Logger.w(TAG, "cache skipped on metered net id=$id")
            return
        }
        val job: Job
        synchronized(lock) {
            if (inFlight == id) return
            inFlightJob?.cancel()          // 挤掉上一个:它会在下一块自检时停住
            inFlight = id
            job = scope.launch { fetch(id, url, headers) }
            inFlightJob = job
        }
        com.yuyin.reverb.util.Logger.i(
            TAG,
            "cache start id=$id endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
        )
    }

    /** 磁盘上的真实占用(不是账本字节数之和 —— 账可能旧,而 `.part` 根本不算缓存)。 */
    fun usageBytes(): Long {
        if (!::dir.isInitialized) return 0L
        return dir.listFiles()?.sumOf { if (it.isFile && !it.name.endsWith(".part")) it.length() else 0L }
            ?: 0L
    }

    fun cachedCount(): Int = if (::store.isInitialized) store.items.value.size else 0

    /**
     * 「清除缓存」:目录整个清空(含中途取消留下的 `.part`),账本一并作废。
     *
     * 顺序是硬的:**先**清认领字段再删文件。在途那次 fetch 是靠 `inFlight` 认自己的,
     * 不清掉它就会在目录已空之后继续往下写、并把这一集重新记进账本 —— 用户点了「清除缓存」
     * 却看到数字没怎么变,而这条路径界面上无法解释。
     */
    fun clearAll() {
        if (!::store.isInitialized) return
        synchronized(lock) {
            inFlightJob?.cancel()
            inFlight = null
            inFlightJob = null
        }
        val names = store.clearAll()
        com.yuyin.reverb.util.Logger.i(TAG, "clearAll entries=${names.size}")
        dir.listFiles()?.forEach { runCatching { it.delete() } }
    }

    private fun fetch(id: String, url: String, headers: Map<String, String>?) {
        val name = fileName(id, url)
        val part = File(dir, "$name.part")
        val target = File(dir, name)
        val req = Request.Builder().url(url)
        if (headers != null) {
            headers.forEach { (k, v) -> req.header(k, v) }
        } else {
            req.header("User-Agent", "Reverb/1.0 (Android podcast client)")
        }
        val call = client.newCall(req.build())
        try {
            call.execute().use { resp ->
                val body = resp.body
                if (!resp.isSuccessful || body == null) {
                    com.yuyin.reverb.util.Logger.w(TAG, "cache http ${resp.code} id=$id")
                    return
                }
                var read = 0L
                body.byteStream().use { input ->
                    part.outputStream().use { out ->
                        val buf = ByteArray(16384)
                        var n: Int
                        while (input.read(buf).also { n = it } != -1) {
                            out.write(buf, 0, n)
                            read += n
                            // 被更新的请求挤掉 / 用户清了缓存:立刻收手,别再占着带宽和这条连接。
                            if (inFlight != id) throw InterruptedException("superseded")
                        }
                    }
                }
                if (read <= 0L) {
                    com.yuyin.reverb.util.Logger.w(TAG, "cache empty body id=$id")
                    return
                }
                // **先 rename 再记账**:反过来的话,一次进程被杀就留下「账上有、文件没落地」的记录。
                //
                // rename 前再认一次领:收完最后一块与落名之间用户正好按了「清除缓存」的话,
                // 这一份不能再落回目录 —— 否则设置页那个数字刚清完又变成非 0,看起来就是按钮失灵。
                if (inFlight != id) {
                    com.yuyin.reverb.util.Logger.i(TAG, "cache cancelled before rename id=$id")
                    return
                }
                if (!part.renameTo(target)) {
                    com.yuyin.reverb.util.Logger.w(TAG, "cache rename failed id=$id")
                    return
                }
                val now = System.currentTimeMillis()
                store.put(
                    AudioCacheStore.Item(
                        episodeId = id,
                        audioUrl = url,
                        fileName = name,
                        bytes = target.length(),
                        cachedAt = now,
                        lastAccessMs = now
                    )
                )
                com.yuyin.reverb.util.Logger.i(TAG, "cache done id=$id bytes=$read")
            }
            evict(keepId = id)
        } catch (e: InterruptedException) {
            com.yuyin.reverb.util.Logger.i(TAG, "cache cancelled id=$id")
            runCatching { call.cancel() }
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "cache failed id=$id: ${e.message}")
        } finally {
            // rename 成功后 .part 已不存在,这里的 delete 是空操作;失败/取消/被挤掉都靠它收尾。
            runCatching { if (part.exists()) part.delete() }
            clearInFlight(id)
        }
    }

    /** 超预算就按「最久没听」依次删。[keepId] 是刚下完的这集(大概率正在播,绝不能删)。 */
    private fun evict(keepId: String) {
        var usage = usageBytes()
        if (usage <= BUDGET_BYTES) return
        for (item in store.byLeastRecent()) {
            if (usage <= BUDGET_BYTES) break
            if (item.episodeId == keepId) continue
            runCatching { File(dir, item.fileName).delete() }
            store.remove(item.episodeId)
            usage -= item.bytes
            com.yuyin.reverb.util.Logger.i(TAG, "evicted id=${item.episodeId} bytes=${item.bytes}")
        }
    }

    /**
     * 目录与账本互相校正:账指不到文件的删账,文件没人认领的删文件(含半截 `.part` 与空文件)。
     *
     * 需要它是因为两边都可能单独变:系统可以清理缓存目录,「清除缓存」的旧版本可以只删文件不删账,
     * 而崩溃留下的 `.part` 谁都不认领。不一致的后果不是脏文件那么温和 —— 账上有一条就意味着
     * [localPath] 有可能交出播不了的路径,设置页的数字也和磁盘对不上。
     */
    private fun reconcile() {
        val files = dir.listFiles()?.toList() ?: emptyList()
        val known = HashMap<String, String>()
        for (item in store.items.value) known[item.fileName] = item.episodeId
        for (f in files) {
            val owner = known[f.name]
            // 不认识的文件(含 .part)、不是普通文件的,一律删掉
            if (owner == null || !f.isFile) {
                runCatching { f.delete() }
                continue
            }
            if (f.length() == 0L) {
                runCatching { f.delete() }
                store.remove(owner)
            }
        }
        for (item in store.items.value) {
            if (!File(dir, item.fileName).exists()) store.remove(item.episodeId)
        }
        evict(keepId = "")
    }

    /**
     * 与 [DownloadManager] 同一套口径:没开「蜂窝也允许」且当前默认网络按用量计费就拦。
     * 判据本体(为什么用 `isActiveNetworkMetered`、为什么与鸿蒙**刻意不修一致**、两个取不到时
     * 各朝哪边)已收进 [com.yuyin.reverb.util.CellularGate],见那里的注释(REVIEW-2026-10-25 中-3)。
     *
     * 缓存必须走这道闸门:下载是用户点名要花的流量,而「播过就自动缓存」是 App 替他做的决定,
     * 更不该在计费链路上擅自跑几十 MB。
     */
    private fun blockedByCellular(): Boolean =
        com.yuyin.reverb.util.CellularGate.blocked(settings, if (::appCtx.isInitialized) appCtx else null)

    private fun clearInFlight(id: String) {
        synchronized(lock) {
            if (inFlight == id) {
                inFlight = null
                inFlightJob = null
            }
        }
    }

    private fun fileName(id: String, url: String): String {
        val ext = when {
            url.contains(".m4a", true) -> ".m4a"
            url.contains(".aac", true) -> ".aac"
            url.contains(".ogg", true) -> ".ogg"
            url.contains(".wav", true) -> ".wav"
            // 视频源(dash 音轨)给的是 `.m4s`:内容是**分片 MP4**(ftyp/moov/sidx/moof),
            // 落成 `.mp3` 只是改个名字、播放层按内容嗅探照样能播,但盘上那份文件从此
            // 名不副实 —— 任何人(包括我们自己 adb 进去看)都会以为那是一集 MP3。
            url.contains(".m4s", true) -> ".m4s"
            else -> ".mp3"
        }
        // 前缀与下载分开(dl_ / ca_):两个目录本来就分家,再加一层肉眼可辨,
        // 出问题时用 adb 看一眼目录就知道这个文件归谁管。
        //
        // 为什么不用 String.hashCode():32 位散列按生日悖论约 7.7 万个 id 就有 50% 概率撞一对,
        // 而缓存目录是按文件名落盘的 —— 撞上的两集会共用同一个文件,表现为"这集播的是另一集的声音",
        // 且 `AudioCacheStore` 里两条记录都自称合法,事后无从解释。SHA-256 截 16 个 hex(64 位)
        // 把量级推到十亿级。见 REVIEW-2026-10-25 低·族 A。
        //
        // 迁移口径(与体检文档的预判不同,这里核实过):`reconcile()` 是按**账本里的 fileName**
        // 认领文件的,旧格式 `ca_<hashCode>` 的文件仍被旧账条目认领,不会被当孤儿删掉;
        // [cache] 又是 `store.get(id) != null` 先短路,所以升级后已缓存的集不会重下一份。
        // 于是老缓存既不丢也不翻倍,只是新旧两种文件名在目录里并存,随 LRU 淘汰自然收敛。
        return "ca_" + ShortHash.hex16(id) + ext
    }
}
