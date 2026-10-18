package com.yuyin.reverb.update

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import com.yuyin.reverb.BuildConfig
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 应用内更新。
 *
 * 发布物只有一个:仓库 GitHub Releases 上那份 `reverb.apk`。这里做三件事 ——
 * ① 启动后查一次「最新 release」;② 版本比本机新就下载(仅 Wi-Fi 自动下,计费网络先征求同意);
 * ③ 下载完把文件交给系统安装器。**没有任何自建后端**:这一条与「零后端」约束不冲突,
 * 因为读的是**公开发布页的公开 API**,不带任何标识用户的参数,也不上传任何数据。
 *
 * **它在 `src/main`(2026-10-18 起)**
 * 原先只有自分发渠道带这个功能:商店那份是同名空壳,权限与文案都不进那个包(见 H70 的隔离手法)。
 * 两个 flavor 合并成一份包之后没得选了 —— 同一个 APK 既上 GitHub 也上商店,
 * 所以这份真实现进了 `src/main`,`REQUEST_INSTALL_PACKAGES` 也随之进了唯一的 manifest。
 * ⚠️ 商店合规口径下「自更新 + 敏感权限」仍是被明令避免的形态(绕过市场的版本审核、
 * 需逐次举证),这一刀是**合并的代价**,不是它变合规了;真被拒时的处置是把 `start` 调用点摘掉
 * 并删 manifest 里那一行,验收仍是解包 grep(见 H205)。
 *
 * **为什么"以后再说"必须落盘**
 * 检测点在每次冷启动。若用户点了「以后再说」而不记版本,下次启动同一个弹窗会再来一次,
 * 于是这个功能变成每启动一次的骚扰。记的是**被跳过的那个版本名**:
 * 只对同一版本静音,一旦发布了更高的版本会重新问(所以不需要"重新检查更新"的入口)。
 */
object SelfUpdate {

    private const val TAG = "Update"

    /// 公开发布页的 latest 接口。`latest` 不含 draft/prerelease,正合发布流程。
    private const val RELEASES_URL = "https://api.github.com/repos/cxyxlxdm/revert-cast/releases/latest"

    /// 单个资产的下载端点(拼上 release JSON 里那个数字 `id`)。
    ///
    /// **为什么下载不直接用发布页给的 `browser_download_url`**:2026-10-17 真机第一次跑完整流程,
    /// 检测请求成功而下载 `SocketTimeoutException: failed to connect to github.com/20.205.243.166
    /// (port 443) … after 15000ms`;同一台笔记本上同一个 URL 同样超时,而 `api.github.com`
    /// 解析到另一个 IP(…168)且可达。两个地址指向的是**同一个字节的同一份资产**(实测那条端点
    /// 302 到 `release-assets.githubusercontent.com` 后返回 206、`content-range: bytes 0-0/64958828`)。
    /// 所以下面按「API 端点在前、直链在后」的顺序试。见 H199。
    ///
    /// ⚠️ 这条路每次下载都吃一次 API 限额(未带 token 是**每 IP 每小时 60 次**;检测只占 1 次/冷启动,
    /// 一次完整下载再占 1 次)。对本功能这个量级完全够,但别把它挪到定时器上。
    private const val ASSET_API_URL = "https://api.github.com/repos/cxyxlxdm/revert-cast/releases/assets/"

    /// 发布物的资产名(与 `android/build-release.sh` 落到 `dist/` 的文件名一致)。
    /// **不能取 `assets[0]`**:1.0.1 / 1.0.2 那两个 release 里同时挂着 macOS 的 `Reverb.dmg`,
    /// 而且它在数组里排在 `reverb.apk` 之后 —— 顺序不是契约,按名字挑才稳。
    private const val APK_ASSET_NAME = "reverb.apk"

    /// 落盘子目录名(也是 `file_paths.xml` 里对外可读的那一条)。
    private const val DIR = "update"
    private const val PREFS = "reverb_update"
    private const val KEY_SKIPPED = "skipped_tag"

    private val _state = MutableStateFlow<UpdateState>(UpdateState.Idle)
    val state: StateFlow<UpdateState> = _state

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val started = AtomicBoolean(false)
    private var downloadJob: Job? = null

    private lateinit var appCtx: Context
    private lateinit var prefs: SharedPreferences
    private lateinit var client: OkHttpClient

    /**
     * 每次进程只跑一次([started] 挡住),由 `MainActivity.startGatedComponents()` 调用 ——
     * 那里是「用户已同意隐私政策」之后的唯一入口(见该文件注释:同意之前不得读网络状态)。
     */
    fun start(context: Context, http: OkHttpClient) {
        if (!started.compareAndSet(false, true)) return
        appCtx = context.applicationContext
        prefs = appCtx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // 复用共享连接池,但必须放开 callTimeout:整包 60+ MB,默认的 30 秒总时限一定会掐断。
        // **并且只走 HTTP/1.1**:2026-10-17 真机第一次跑这条下载,在 h2 连接建立阶段就抛
        // `IOException: Required SETTINGS preface not received`(对端没给 HTTP/2 的连接前奏,
        // 而短的那个检测请求是好的 —— 长连接与大文件走的是 objects 那个重定向后的主机)。
        // GitHub 那条链路在部分网络上 h2 不稳是已知形态,而这里没有任何理由非要 h2:
        // 一条一个 60 MB 的大请求,h1.1 的连接复用收益为零。见 H199。
        client = http.newBuilder()
            .readTimeout(60, java.util.concurrent.TimeUnit.SECONDS)
            .callTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS)
            .protocols(listOf(okhttp3.Protocol.HTTP_1_1))
            .build()
        scope.launch { checkOnce() }
    }

    private suspend fun checkOnce() {
        val rel = fetchLatest() ?: return  // 静默:检测失败不打扰用户,原因在日志里
        val local = BuildConfig.VERSION_NAME
        if (!isNewer(rel.tag, local)) {
            Logger.i(TAG, "update check up-to-date local=$local remote=${rel.tag}")
            return
        }
        if (rel.tag == prefs.getString(KEY_SKIPPED, null)) {
            Logger.i(TAG, "update skipped tag=${rel.tag} local=$local")
            return
        }
        Logger.i(TAG, "update available remote=${rel.tag} local=$local size=${rel.size}")
        val file = apkFile(rel)
        if (file.exists() && file.length() == rel.size) {
            // 上次下完没装(或装完又启动了一次):不再走一遍网络,直接给安装
            _state.value = UpdateState.Ready(rel, file)
            return
        }
        if (metered()) _state.value = UpdateState.AskCellular(rel) else beginDownload(rel)
    }

    /**
     * 「当前链路按用量计费吗」。**只在蜂窝真正在传数据时才为 true** ——
     * 连着 Wi-Fi 时实测上报 `NOT_METERED`(这条口径与下载闸门同源,见 H166 与 `DownloadManager`)。
     * 拿不到 ConnectivityManager 时按「不计费」放行:宁可少问一次,不要把更新功能钉死。
     *
     * ⚠️ 这里**不读**设置页那个「允许蜂窝下载」开关:那个开关管的是用户自己点下去的音频下载,
     * 而本处的口径是「不是 Wi-Fi 就提醒,用户同意了才下」(产品要求),是**一次一议**,
     * 不是把许可常开。别把它"顺手统一"成同一个开关。
     */
    private fun metered(): Boolean {
        val cm = if (::appCtx.isInitialized) appCtx.getSystemService(ConnectivityManager::class.java) else null
        return cm?.isActiveNetworkMetered == true
    }

    /** 用户点头(或直接就在 Wi-Fi)之后开下。已在下就忽略重复点击。 */
    fun beginDownload(rel: Release) {
        if (downloadJob?.isActive == true) return
        _state.value = UpdateState.Downloading(rel, 0)
        // 把这一轮的 scope 传下去:`download` 里全是阻塞式 IO,协程不会自己在那里检查取消,
        // 必须显式拿 [ensureActive] 挡一道(否则点了「以后再说」之后它还会把 60 MB 下完)。
        downloadJob = scope.launch { download(rel, this) }
    }

    /**
     * 按候选地址依次试,任一成功即收;全败才报失败(弹窗给「重试 / 以后再说」)。
     *
     * 每条候选都是**整包重来**,不做断点续传:续传要求远端支持 Range 且 ETag 稳定,
     * 而这里真正的失败形状是「这条链路连不上」,换一条链路重下比续传更对得上问题。
     */
    private fun download(rel: Release, jobScope: CoroutineScope) {
        val dir = File(appCtx.cacheDir, DIR).apply { mkdirs() }
        // 目录里只该留着正在用的这一份:清掉旧版本的残留(60 MB 级,不能堆)
        dir.listFiles()?.forEach { f ->
            if (f.name != rel.fileName()) runCatching { f.delete() }
        }
        val tmp = File(dir, "${rel.fileName()}.part")
        val target = File(dir, rel.fileName())
        for (url in rel.apkUrls) {
            if (!jobScope.isActive) return   // 已 dismiss:state 是 Idle,这里不该再写它
            val ok = try {
                attempt(rel, url, tmp, target, jobScope)
            } catch (e: CancellationException) {
                // 用户点了「以后再说」:静默收场,不要弹一个"下载失败"
                Logger.i(TAG, "update download cancelled tag=${rel.tag}")
                runCatching { tmp.delete() }
                return
            } catch (e: Exception) {
                Logger.e(TAG, "update download failed endpoint=${Logger.endpoint(url)} tag=${rel.tag}", e)
                runCatching { tmp.delete() }
                false
            }
            if (ok) {
                _state.value = UpdateState.Ready(rel, target)
                return
            }
            runCatching { tmp.delete() }
        }
        Logger.w(TAG, "update download all candidates failed tag=${rel.tag}")
        _state.value = UpdateState.Failed(rel)
    }

    /**
     * 用一条地址把整包下完并校验。返回 false = 「这一条不行,换下一条」;
     * 抛异常 = 链路级失败,同样由调用方换候选。
     */
    private fun attempt(
        rel: Release,
        url: String,
        tmp: File,
        target: File,
        jobScope: CoroutineScope
    ): Boolean {
        runCatching { tmp.delete() }
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            // API 那个端点**必须**带这个头才会 302 到文件本体;不带就返回 JSON,
            // 而 JSON 存成 .apk 会一路走到系统安装器才失败。直链对这个头不敏感,
            // 所以两条候选共用一份请求头。
            .header("Accept", "application/octet-stream")
            .build()
        client.newCall(req).execute().use { resp ->
            val body = resp.body
            if (!resp.isSuccessful || body == null) {
                Logger.w(TAG, "update download http ${resp.code} endpoint=${Logger.endpoint(url)}")
                return false
            }
            // 请求地址是我拼的,但 302 的**落地**主机是远端给的 —— 落地这一侧也要在名单里
            val landed = resp.request.url.host
            if (landed !in TRUSTED_HOSTS) {
                Logger.w(TAG, "update download untrusted redirect endpoint=${Logger.endpoint(resp.request.url.toString())}")
                return false
            }
            val total = if (body.contentLength() > 0) body.contentLength() else rel.size
            val md = runCatching { MessageDigest.getInstance("SHA-256") }.getOrNull()
            var read = 0L
            var shown = -1
            body.byteStream().use { input ->
                tmp.outputStream().use { out ->
                    val buf = ByteArray(8192)
                    var n: Int
                    while (input.read(buf).also { n = it } != -1) {
                        out.write(buf, 0, n)
                        md?.update(buf, 0, n)
                        read += n
                        if (total > 0) {
                            val pct = ((read.toFloat() / total) * 100).toInt().coerceIn(0, 100)
                            // **只在整数百分比变化时写 StateFlow**:按块刷等于给下载加一条
                            // 高频重渲源(硬规矩 6/7 那一类),101 次才是这条进度该有的成本。
                            if (pct != shown) {
                                shown = pct
                                jobScope.ensureActive()   // 取消在这唯一够细的检查点落地
                                _state.value = UpdateState.Downloading(rel, pct)
                            }
                        }
                    }
                    out.flush()
                }
            }
            // 字节数先对一道:这条抓的是**要装进系统的东西**,而"拿到 JSON 而不是 APK"这种
            // 形状在 digest 缺失的老 release 上没有任何别的检查会拦住它
            if (rel.size > 0L && read != rel.size) {
                Logger.w(TAG, "update download size mismatch tag=${rel.tag} got=$read want=${rel.size}")
                return false
            }
            val actual = md?.digest()?.joinToString("") { "%02x".format(it) }
            if (rel.sha256 != null) {
                if (actual == null || actual != rel.sha256) {
                    Logger.w(TAG, "update sha256 mismatch tag=${rel.tag}")
                    return false
                }
                Logger.i(TAG, "update sha256 verified tag=${rel.tag}")
            } else {
                // release 的 digest 字段是较近才有的,老 release 没有:没有就只按字节数对得上
                Logger.w(TAG, "update no digest published tag=${rel.tag} bytes=$read")
            }
            if (!tmp.renameTo(target)) {
                Logger.w(TAG, "update rename failed tag=${rel.tag}")
                return false
            }
            Logger.i(TAG, "update downloaded tag=${rel.tag} bytes=$read endpoint=${Logger.endpoint(url)}")
            return true
        }
    }

    /**
     * 交给系统安装器。**装这一步完全在应用外**:Android 8+ 需要用户授予「安装未知应用」,
     * 未授予时把用户送到那一页的开关(而不是替它做任何决定)。
     *
     * ⚠️ [from] 必须是**Activity 那侧的 Context**(界面里传 `LocalContext.current`):
     * 用 application context 调 `startActivity` 在新系统上会被要求 `FLAG_ACTIVITY_NEW_TASK`,
     * 而安装器本来就该开在当前任务之上。
     */
    fun install(from: Context, rel: Release): InstallHandoff {
        val file = File(File(appCtx.cacheDir, DIR), rel.fileName())
        if (!file.exists() || file.length() != rel.size) return InstallHandoff.Lost
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !appCtx.packageManager.canRequestPackageInstalls()
        ) {
            return InstallHandoff.NeedPermission
        }
        val authority = "${appCtx.packageName}.fileprovider"
        return try {
            val uri = FileProvider.getUriForFile(appCtx, authority, file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            from.startActivity(intent)
            Logger.i(TAG, "update handoff to installer tag=${rel.tag}")
            InstallHandoff.Started
        } catch (e: Exception) {
            // 没有能处理 package-archive 的组件(极少见,但被裁剪过的 ROM 真有)
            Logger.e(TAG, "update install handoff failed", e)
            InstallHandoff.NotFound
        }
    }

    /**
     * 未授予「安装未知应用」时,把用户送到**本应用那一页**的开关(targetSdk 34 上这是唯一合法路径,
     * 老写法 `ACTION_MANAGE_UNKNOWN_APP_SOURCES` 带 package uri)。
     */
    fun openInstallPermissionPage(from: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            from.startActivity(
                Intent(
                    android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${appCtx.packageName}")
                )
            )
        }
    }

    /** 取消下载 / 以后再说:回到静默,并把这一版本记成已跳过(下次冷启动不再问)。 */
    fun dismiss(rel: Release) {
        downloadJob?.cancel()
        downloadJob = null
        runCatching { File(File(appCtx.cacheDir, DIR), "${rel.fileName()}.part").delete() }
        prefs.edit().putString(KEY_SKIPPED, rel.tag).apply()
        _state.value = UpdateState.Idle
    }

    /** 只是把弹窗收起来(没有新版本可跳时不记跳过)。 */
    fun reset() {
        _state.value = UpdateState.Idle
    }

    private fun fetchLatest(): Release? = try {
        val req = Request.Builder()
            .url(RELEASES_URL)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            .header("Accept", "application/vnd.github+json")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                Logger.w(TAG, "update check http ${resp.code} endpoint=${Logger.endpoint(RELEASES_URL)}")
                null
            } else parse(resp.body?.string())
        }
    } catch (e: Exception) {
        Logger.e(TAG, "update check error endpoint=${Logger.endpoint(RELEASES_URL)}", e)
        null
    }

    private fun parse(json: String?): Release? {
        if (json.isNullOrBlank()) return null
        return try {
            val o = JSONObject(json)
            val tag = o.optString("tag_name").ifBlank { o.optString("name") }.trim()
            if (tag.isEmpty()) return null
            val assets = o.optJSONArray("assets") ?: return null
            var picked: JSONObject? = null
            for (i in 0 until assets.length()) {
                val a = assets.optJSONObject(i) ?: continue
                val name = a.optString("name")
                if (name.equals(APK_ASSET_NAME, ignoreCase = true)) {
                    picked = a
                    break
                }
                if (picked == null && name.endsWith(".apk", ignoreCase = true)) picked = a  // 兜底:改名了也不至于完全不动
            }
            val asset = picked ?: return null
            val direct = asset.optString("browser_download_url").trim()
            val id = asset.optLong("id", 0L)
            // 候选顺序 = 实测可达性顺序(见 [ASSET_API_URL] 那段):API 端点在前、发布页直链在后。
            // API 那条是**我们自己拼的**(`id` 只当数字用),直链那条来自远端 JSON,所以两条一起过名单。
            val urls = listOfNotNull(
                if (id > 0L) ASSET_API_URL + id else null,
                direct.takeIf { it.isNotBlank() }
            ).filter { isTrustedDownload(it) }
            if (urls.isEmpty()) {
                Logger.w(TAG, "update check no trusted apk asset tag=$tag")
                return null
            }
            Release(
                tag = tag,
                apkUrls = urls,
                size = asset.optLong("size", 0L),
                // 公开发布页给的校验串;老 release 没有这个字段,没有就不校验(见 download 里那条 log)
                sha256 = asset.optString("digest", "").removePrefix("sha256:").lowercase()
                    .takeIf { it.length >= 16 && it.all { c -> c in "0123456789abcdef" } }
            )
        } catch (e: Exception) {
            Logger.e(TAG, "update parse failed", e)
            null
        }
    }

    /**
     * 只接受自家发布页这几条主机:下载完是要**装进系统**的东西,
     * 这里的输入按外部输入对待(TLS 之外再加一道"响应内容我没看错")。
     *
     * 四条各有出处:`api.github.com` 是检测与资产端点,`github.com` 是直链的第一跳,
     * 后两条是重定向的落地(host 集合按 GitHub 当前实际用到的收 ——
     * `release-assets.githubusercontent.com` 是 2026-10-17 实测那条端点的落地主机,见 H199)。
     */
    private val TRUSTED_HOSTS = setOf(
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com"
    )

    private fun isTrustedDownload(url: String): Boolean = try {
        val uri = Uri.parse(url)
        uri.scheme == "https" && uri.host in TRUSTED_HOSTS
    } catch (e: Exception) {
        false
    }

    private fun apkFile(rel: Release): File = File(File(appCtx.cacheDir, DIR), rel.fileName())

    sealed class UpdateState {
        object Idle : UpdateState()

        /// 计费网络:先问一句,点头才下
        data class AskCellular(val rel: Release) : UpdateState()

        data class Downloading(val rel: Release, val percent: Int) : UpdateState()

        data class Ready(val rel: Release, val file: File) : UpdateState()

        data class Failed(val rel: Release) : UpdateState()
    }

    enum class InstallHandoff { Started, NeedPermission, NotFound, Lost }

    /** [apkUrls] 是**按优先级排的候选地址**,不是列表 UI 能选的东西 —— 见 [ASSET_API_URL] 的注释。 */
    data class Release(val tag: String, val apkUrls: List<String>, val size: Long, val sha256: String?)

    /**
     * 落盘文件名。`tag` 来自发布页,**必须当外部输入**:版本号里出现 `/` 或 `..`
     * 就会把文件写到缓存目录外面去(而那个目录是 FileProvider 对外可读的)。
     * 只留 `[0-9A-Za-z._-]`,其余替成 `_`,并夹长度。
     */
    fun Release.fileName(): String {
        val safe = tag.take(40).map { if (it.isLetterOrDigit() || it == '.' || it == '-') it else '_' }
            .joinToString("")
            .trimStart('.')
        return "reverb-${if (safe.isEmpty()) "new" else safe}.apk"
    }

    /**
     * 版本比对:点分十进制,缺位补 0,大小比较。
     * 两边的"-debug"/"-beta"之类的后缀**不参与比较**(只取每段的数字前缀),
     * 因为调试包的本机版本名带的就是 `-debug`,而发布页那份没有。
     * 解析不出来就判「不比它新」——宁可漏问一次,不要在用户没新版本时弹窗。
     */
    fun isNewer(remote: String, local: String): Boolean {
        val r = versionOf(remote) ?: return false
        val l = versionOf(local) ?: return false
        val n = maxOf(r.size, l.size)
        for (i in 0 until n) {
            val a = if (i < r.size) r[i] else 0
            val b = if (i < l.size) l[i] else 0
            if (a != b) return a > b
        }
        return false
    }

    private fun versionOf(raw: String): IntArray? {
        val s = raw.trim().trimStart('v', 'V')
        if (s.isEmpty()) return null
        val parts = s.split('.')
        val out = IntArray(parts.size)
        for (i in parts.indices) {
            val digits = parts[i].takeWhile { it.isDigit() }
            if (digits.isEmpty()) return null
            out[i] = digits.toIntOrNull() ?: return null
        }
        return out
    }
}
