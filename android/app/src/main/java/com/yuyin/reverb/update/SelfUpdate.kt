package com.yuyin.reverb.update

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import androidx.core.content.ContextCompat
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
 * ① 启动后查一次发布页的 release **列表**(不是 `releases/latest` 那根指针),设置页「检查更新」
 *    走同一条代码路径、只是必须给个读数;② 远端版本比本机新才下载(仅蜂窝网络先征求同意);
 * ③ 下载完把文件交给系统安装器。**没有任何自建后端**:这一条与「零后端」约束不冲突,
 * 因为读的是**公开发布页的公开 API**,不带任何标识用户的参数,也不上传任何数据。
 *
 * ⚠️ 口径(2026-11-27 改):**同 versionCode 一律不提示、不下载**。
 * 公开仓的 release 只有 tag(tag 里就是版本名),读不到远端 APK 的 versionCode;
 * 而发版约定是 versionName 递增时 versionCode 同步递增(见 AGENTS「版本号一共四处」),
 * 所以"远端比本机新"按 versionName 的数字段比 [isNewer],等价于按 versionCode 比。
 * 原先还有一条 `isRepublished`:**同版本名 + 不同字节**也会触发下载 ——
 * 那条已停用。本机重打一个同版本包时,GitHub 上同 tag 的旧资产会把刚装的新包覆盖回去,
 * 正是这次要堵的行为;远端字节就算与本机不同,只要版本号不高于本机就当已是最新。
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
 * 于是这个功能变成每启动一次的骚扰。记的是**被跳过那一版的「版本名 + 包体摘要」**:
 * 只对**那一份发布物**静音;下一版 tag 不同,会照常提示(见 H203 的代价)。
 */
object SelfUpdate {

    private const val TAG = "Update"

    /**
     * 公开发布页的 **release 列表**接口(不是 `releases/latest`)。
     *
     * 换掉的理由有两条,都是这轮踩过的:
     * ① `latest` 那个指针靠"发版时把 latest 移过来"才指向对的那一版 ——
     *    一旦哪天手滑没移,检测就永远问的是一版旧的;列表接口自己排序,不依赖指针。
     * ② 列表一次就把每个 release 的资产名、字节数与 `digest` 全带回来了,
     *    `digest` 用于下载完校验字节与落盘文件名(避免把旧字节递给安装器);
     *    `latest` 只有一份,拿不到历史 release。
     * `per_page=20`:本仓库至今 6 个 release,20 条够扩好几年,且一次调用不翻页
     * (GitHub 未带 token 是**每 IP 每小时 60 次**,检测必须始终只占 1 次)。
     * draft 与 prerelease 在解析里自己滤掉 —— 滤完这两类,口径与 `latest` 完全一致。
     */
    private const val RELEASES_URL = "https://api.github.com/repos/cxyxlxdm/revert-cast/releases?per_page=20"


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

    /// Atom 发布流:检测主路的兜底。不需要 token,也不占 REST API 的每 IP 60 次限额。
    /// 2026-11-23 起 macOS 已把它当主路;Android 仍先走 API(要 digest 校验下载字节),
    /// 限额用尽(403 / remaining=0)时再用它把「有新版本」这件事问出来。
    private const val ATOM_URL = "https://github.com/cxyxlxdm/revert-cast/releases.atom"

    /// 直链前缀。Atom 里只有 tag,资产直链按「tag + 固定文件名」自己拼。
    private const val DOWNLOAD_BASE = "https://github.com/cxyxlxdm/revert-cast/releases/download/"

    private val ATOM_ENTRY = Regex("<entry>.*?<title>([^<]+)</title>", RegexOption.DOT_MATCHES_ALL)

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

    /// 下载中间弹窗还该不该显示。下载本身由 [UpdateDownloadService] 在通知栏里跑,
    /// 所以「用户在干别的事」与「下载在不在跑」是两件事 —— 只用一个 [UpdateState] 表达
    /// 会把「收起弹窗」误当成「取消下载」。
    private val _dialogShown = MutableStateFlow(true)
    val dialogShown: StateFlow<Boolean> = _dialogShown

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val started = AtomicBoolean(false)
    private var downloadJob: Job? = null

    /// 交给 [UpdateDownloadService] 的那一份发布信息(同一进程内的交接,不落盘)。
    /// 服务被系统以 `START_NOT_STICKY` 拉起时读不到它就直接退出 —— 重来一次要走正常的检测路径。
    @Volatile
    internal var pendingRelease: Release? = null
        private set

    private lateinit var appCtx: Context
    private lateinit var prefs: SharedPreferences
    private lateinit var client: OkHttpClient

    /**
     * 每次进程只**自动**跑一次([started] 挡住),由 `MainActivity.startGatedComponents()` 调用 ——
     * 那里是「用户已同意隐私政策」之后的唯一入口(见该文件注释:同意之前不得读网络状态)。
     */
    fun start(context: Context, http: OkHttpClient) {
        if (!started.compareAndSet(false, true)) return
        init(context, http)
        scope.launch { checkOnce(manual = false) }
    }

    /**
     * 设置页「检查更新」那一条用的**主动检测**。与自动那轮共用同一条代码路径,只差三件事:
     * ①不受 [started] 的限制(随时可点);②不受「已跳过」静音的限制(你都主动点了,就别拿旧决定挡你);
     * ③结果一定要有个可见的落点(最新 / 失败),而自动那轮是静默的。
     *
     * ⚠️ 未初始化就直接返回:`appCtx` / `prefs` / `client` 都是在 [start] 里才落地的,
     * 而唯一能点这一条的界面必然在同意隐私之后才出现 —— 真没初始化时这里必须是不动,
     * 不能是一个 `lateinit not initialized` 崩溃。
     */
    fun checkNow(context: Context) {
        if (!::appCtx.isInitialized) {
            // 同意门之前不该有任何网络动作,所以这里也不补一次 init,只记一行日志
            Logger.w(TAG, "manual update check before init")
            return
        }
        if (_state.value is UpdateState.Checking || _state.value is UpdateState.Downloading) return
        scope.launch { checkOnce(manual = true) }
    }

    private fun init(context: Context, http: OkHttpClient) {
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
    }

    private suspend fun checkOnce(manual: Boolean) {
        if (_state.value is UpdateState.Checking) return
        _state.value = UpdateState.Checking
        val rel = fetchLatest()
        if (rel == null) {
            // 自动那一轮静默(检测失败不打扰用户,原因在日志里);主动点的那一轮必须给个说法。
            // 两条路都必须有落点:自动轮失败若把状态留在 Checking,checkNow 的防重入闸会把
            // 之后所有手动点击吞到进程重启为止(H235) —— "静默"是回到 Idle,不是停在一个中间态。
            Logger.w(TAG, "update check got nothing manual=$manual")
            _state.value = if (manual) UpdateState.CheckFailed else UpdateState.Idle
            return
        }
        val local = BuildConfig.VERSION_NAME
        val newer = isNewer(rel.tag, local)
        if (!newer) {
            // 同 versionCode(= 同版本名)一律不提示、不下载。远端资产摘要就算与本机不同,
            // 也不再按"同版本重出包"处理 —— 否则本机临时重打的同版本包会被 GitHub 上
            // 同 tag 的旧资产覆盖回去。
            Logger.i(TAG, "update check up-to-date local=$local(${BuildConfig.VERSION_CODE}) remote=${rel.tag}")
            _state.value = if (manual) UpdateState.UpToDate(rel.tag) else UpdateState.Idle
            return
        }
        val target = rel
        if (!manual && target.muteKey() == prefs.getString(KEY_SKIPPED, null)) {
            // 自动那一轮:这一版(这一份字节)之前跳过过,回到静默。
            // 这里**不能**写成 UpToDate —— 设置那一行会跟着显示"已是最新",而其实是有更新、只是被跳过的
            Logger.i(TAG, "update skipped key=${target.muteKey()} local=$local")
            _state.value = UpdateState.Idle
            return
        }
        Logger.i(TAG, "update available remote=${rel.tag} local=$local(${BuildConfig.VERSION_CODE}) size=${rel.size} manual=$manual")
        val file = apkFile(rel)
        if (rel.size > 0L && file.exists() && file.length() == rel.size) {
            // 上次下完没装(或装完又启动了一次):不再走一遍网络,直接给安装。
            // 文件名里带摘要前缀,所以"同版本重出包"不会命中这一条而把旧字节再递一次(见 [fileName])。
            _state.value = UpdateState.Ready(target, file)
            return
        }
        if (metered()) _state.value = UpdateState.AskCellular(target) else beginDownload(appCtx, target)
    }

    // 「同版本重出包」的 digest 兜底已停用(2026-11-27):同 versionCode 一律不提示、不下载,
    // 本机重打的同版本包不应被 GitHub 上同 tag 的旧资产覆盖回去。


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

    /**
     * 用户点头(或直接就在 Wi-Fi)之后开下。已在下就忽略重复点击。
     *
     * 下载跑在**前台服务**里而不是这个进程的协程里:安装包已经 200 MB 级,用户收起弹窗
     * 按提示在通知栏看进度、继续听播客或锁屏,进程都必须活着 —— 普通协程会随进程一起被回收。
     * 弹窗与下载因此解耦:[dialogShown] 管前者,[UpdateState.Downloading] 管后者。
     */
    fun beginDownload(context: Context, rel: Release) {
        if (downloadJob?.isActive == true || _state.value is UpdateState.Downloading) return
        pendingRelease = rel
        _dialogShown.value = true
        _state.value = UpdateState.Downloading(rel, 0)
        // 自动那一轮(Wi-Fi + 有新版)是从冷启动的检测协程里进来的,而用户可能已经在那一刻
        // 把应用切走了 —— Android 12 起从后台启动前台服务会被直接拒绝。被拒时退回进程内下载:
        // 进程活着就照样下完,被回收就下次启动重来(这条路径在本轮改造前本来就是这么走的)。
        val started = runCatching {
            ContextCompat.startForegroundService(
                context, Intent(context, UpdateDownloadService::class.java)
            )
        }.isSuccess
        if (!started) {
            Logger.w(TAG, "update foreground service rejected, fallback in-process")
            downloadJob = scope.launch { download(rel, this) }
        }
    }

    /**
     * 服务那一侧真正开跑的地方。`download` 里全是阻塞式 IO,协程不会自己在那里检查取消,
     * 必须显式拿 [ensureActive] 挡一道(否则点了「取消下载」之后它还会把整包下完) ——
     * 所以把服务的 scope 传进去,取消由服务/用户动作落在协程上。
     */
    internal fun runServiceDownload(rel: Release, serviceScope: CoroutineScope): Job {
        val job = serviceScope.launch { download(rel, this) }
        downloadJob = job
        return job
    }

    /**
     * 服务被系统收回(前台服务超时之类)而下载还没收尾:留一个可重试的落点,
     * 别把界面钉在 `Downloading` 上 —— 那会连设置页那一行也一直显示"正在下载"。
     */
    internal fun markInterrupted(rel: Release) {
        if (_state.value is UpdateState.Downloading) {
            Logger.w(TAG, "update download interrupted by service stop tag=${rel.tag}")
            _dialogShown.value = true
            _state.value = UpdateState.Failed(rel)
        }
    }

    /** 收起 / 重新打开下载进度弹窗。下载本身不受影响。 */
    fun setDialogVisible(visible: Boolean) {
        _dialogShown.value = visible
    }

    /**
     * 按候选地址依次试,任一成功即收;全败才报失败(弹窗给「重试 / 以后再说」)。
     *
     * **断点续传**:分片刻意留在缓存目录里,失败 / 服务被系统收回都不删 —— 下一次
     * (同一进程重试或下次冷启动)带 `Range` + `If-Range` 接着下。只有用户明确取消/跳过才删。
     * 远端不支持 Range(回 200)时自动退回整包重下;分片与远端对不上(416 / 总量不符)时也丢掉重来。
     */
    private fun download(rel: Release, jobScope: CoroutineScope) {
        val dir = File(appCtx.cacheDir, DIR).apply { mkdirs() }
        val partName = "${rel.fileName()}.part"
        val metaName = "$partName.json"
        // 目录里只该留着正在用的这一份:目标、分片、分片元数据。其余是旧版本残留(60 MB 级)。
        dir.listFiles()?.forEach { f ->
            if (f.name != rel.fileName() && f.name != partName && f.name != metaName) {
                runCatching { f.delete() }
            }
        }
        val part = File(dir, partName)
        val meta = File(dir, metaName)
        val target = File(dir, rel.fileName())

        // 上次已下完整、只差改名(进程在最后一步被杀):校验后直接收尾,不再走网络。
        if (rel.size > 0L && part.isFile && part.length() == rel.size) {
            if (rel.sha256 != null && sha256(part) != rel.sha256) {
                Logger.w(TAG, "update part sha256 mismatch, discard tag=${rel.tag}")
                runCatching { part.delete() }
                runCatching { meta.delete() }
            } else {
                runCatching { target.delete() }
                if (part.renameTo(target)) {
                    runCatching { meta.delete() }
                    _dialogShown.value = true
                    _state.value = UpdateState.Ready(rel, target)
                    return
                }
            }
        }
        if (rel.size > 0L && part.isFile && part.length() > rel.size) {
            runCatching { part.delete() }
            runCatching { meta.delete() }
        }

        for (url in rel.apkUrls) {
            if (!jobScope.isActive) return   // 已 dismiss:state 是 Idle,这里不该再写它
            val ok = try {
                attempt(rel, url, part, meta, target, jobScope)
            } catch (e: CancellationException) {
                // 用户点了「以后再说」:静默收场;只有取消才删分片(下次要重下)。
                Logger.i(TAG, "update download cancelled tag=${rel.tag}")
                runCatching { part.delete() }
                runCatching { meta.delete() }
                return
            } catch (e: Exception) {
                // 链路级失败**保留分片**:下一个候选或下一次启动可以续传。
                Logger.e(TAG, "update download failed endpoint=${Logger.endpoint(url)} tag=${rel.tag}", e)
                false
            }
            if (ok) {
                // 收尾一定要把弹窗放出来:用户可能正收起着在干别的事,而"能装了"这件事
                // 需要一个能点的落点(通知栏里那条只是提示,安装仍由弹窗交给系统安装器)。
                _dialogShown.value = true
                _state.value = UpdateState.Ready(rel, target)
                return
            }
        }
        Logger.w(TAG, "update download all candidates failed tag=${rel.tag} part=${part.length()}")
        _dialogShown.value = true
        _state.value = UpdateState.Failed(rel)
    }

    /**
     * 用一条地址续传/下载并校验。返回 false = 这一条没完成(**分片保留**);
     * 抛异常 = 链路级失败,同样由调用方换候选且保留分片。
     */
    private fun attempt(
        rel: Release,
        url: String,
        part: File,
        metaFile: File,
        target: File,
        jobScope: CoroutineScope
    ): Boolean {
        var partBytes = if (part.isFile) part.length() else 0L
        val meta = readResumeMeta(metaFile)
        val canResume = partBytes > 0L && meta != null && meta.tag == rel.tag &&
            (meta.total <= 0L || rel.size <= 0L || meta.total == rel.size) &&
            (!meta.etag.isNullOrBlank() || !meta.lastModified.isNullOrBlank())
        if (partBytes > 0L && !canResume) {
            Logger.w(TAG, "update discard unusable part bytes=$partBytes tag=${rel.tag}")
            runCatching { part.delete() }
            runCatching { metaFile.delete() }
            partBytes = 0L
        }
        val builder = Request.Builder()
            .url(url)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            // API 那个端点**必须**带这个头才会 302 到文件本体;不带就返回 JSON,
            // 而 JSON 存成 .apk 会一路走到系统安装器才失败。直链对这个头不敏感,
            // 所以两条候选共用一份请求头。
            .header("Accept", "application/octet-stream")
        if (canResume) {
            builder.header("Range", "bytes=$partBytes-")
            (meta?.etag?.takeIf { it.isNotBlank() }
                ?: meta?.lastModified?.takeIf { it.isNotBlank() })
                ?.let { builder.header("If-Range", it) }
        }
        client.newCall(builder.build()).execute().use { resp ->
            if (resp.code == 416) {
                // 分片越过远端资源(或远端换了文件):丢掉,下一次从 0 开始。
                Logger.w(TAG, "update resume range not satisfiable tag=${rel.tag} bytes=$partBytes")
                runCatching { part.delete() }
                runCatching { metaFile.delete() }
                return false
            }
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
            val range = if (resp.code == 206) parseContentRange(resp.header("Content-Range")) else null
            if (resp.code == 206 && (range == null || range.first != partBytes)) {
                Logger.w(TAG, "update resume range mismatch got=${resp.header("Content-Range")} want=$partBytes")
                runCatching { part.delete() }
                runCatching { metaFile.delete() }
                return false
            }
            val offset = if (resp.code == 206) range!!.first else 0L
            val total = when {
                resp.code == 206 && range != null && range.second > 0L -> range.second
                body.contentLength() > 0L -> body.contentLength()
                else -> rel.size
            }
            val etag = resp.header("ETag")
            val lastModified = resp.header("Last-Modified")
            if (etag != null || lastModified != null) {
                writeResumeMeta(metaFile, ResumeMeta(rel.tag, etag, lastModified, total))
            } else {
                runCatching { metaFile.delete() }
            }
            var read = 0L
            var shown = -1
            body.byteStream().use { input ->
                java.io.FileOutputStream(part, resp.code == 206).use { out ->
                    val buf = ByteArray(8192)
                    var n: Int
                    while (input.read(buf).also { n = it } != -1) {
                        out.write(buf, 0, n)
                        read += n
                        if (total > 0L) {
                            val pct = (((offset + read).toFloat() / total) * 100).toInt().coerceIn(0, 100)
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
            val downloaded = offset + read
            val actualSize = part.length()
            if (rel.size > 0L && actualSize != rel.size) {
                // 短了 = 没下完,分片留着下次续;长了 = 远端给错了,丢掉重来。
                Logger.w(TAG, "update download size mismatch tag=${rel.tag} got=$actualSize want=${rel.size} read=$downloaded")
                if (actualSize > rel.size) {
                    runCatching { part.delete() }
                    runCatching { metaFile.delete() }
                }
                return false
            }
            val actual = sha256(part)
            if (rel.sha256 != null) {
                if (actual == null || actual != rel.sha256) {
                    Logger.w(TAG, "update sha256 mismatch tag=${rel.tag}")
                    runCatching { part.delete() }
                    runCatching { metaFile.delete() }
                    return false
                }
                Logger.i(TAG, "update sha256 verified tag=${rel.tag}")
            } else {
                // release 的 digest 字段是较近才有的,Atom 兜底那条也没有:没有就只按字节数对得上
                Logger.w(TAG, "update no digest published tag=${rel.tag} bytes=$actualSize")
            }
            runCatching { target.delete() }
            if (!part.renameTo(target)) {
                Logger.w(TAG, "update rename failed tag=${rel.tag}")
                return false
            }
            runCatching { metaFile.delete() }
            Logger.i(TAG, "update downloaded tag=${rel.tag} bytes=$actualSize resumed=${offset > 0} endpoint=${Logger.endpoint(url)}")
            return true
        }
    }

    internal data class ResumeMeta(
        val tag: String,
        val etag: String?,
        val lastModified: String?,
        val total: Long
    )

    private fun readResumeMeta(file: File): ResumeMeta? = try {
        if (!file.isFile) null else JSONObject(file.readText()).let { o ->
            ResumeMeta(
                tag = o.optString("tag"),
                etag = o.optString("etag").takeIf { it.isNotBlank() },
                lastModified = o.optString("lastModified").takeIf { it.isNotBlank() },
                total = o.optLong("total", 0L)
            )
        }
    } catch (e: Exception) {
        null
    }

    private fun writeResumeMeta(file: File, meta: ResumeMeta) {
        runCatching {
            file.writeText(JSONObject().apply {
                put("tag", meta.tag)
                put("etag", meta.etag ?: "")
                put("lastModified", meta.lastModified ?: "")
                put("total", meta.total)
            }.toString())
        }
    }

    /** 整文件哈希。下载时不再边写边算,因为续传要先读旧分片 —— 统一在收尾时算一次更不容易错。 */
    private fun sha256(file: File): String? = try {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(8192)
            var n: Int
            while (input.read(buf).also { n = it } != -1) md.update(buf, 0, n)
        }
        md.digest().joinToString("") { "%02x".format(it) }
    } catch (e: Exception) {
        Logger.w(TAG, "update part hash failed: ${e.javaClass.simpleName}")
        null
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
            // 系统安装器已经接过这一棒,通知栏那条"下载完成"再留着只会多一个过期入口
            UpdateNotifications.cancel(appCtx)
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

    /**
     * 取消下载 / 以后再说:回到静默,并把**这一版的那一份发布物**记成已跳过(下次冷启动不再自动问)。
     * 记的是 [Release.muteKey](版本名 + 摘要)而不是裸版本名 —— 下一版 tag 不同就不会被静音,
     * 而主动点「检查更新」时这一条不构成限制(见 [checkNow])。
     */
    fun dismiss(rel: Release) {
        downloadJob?.cancel()
        downloadJob = null
        if (::appCtx.isInitialized) {
            runCatching { appCtx.stopService(Intent(appCtx, UpdateDownloadService::class.java)) }
            runCatching { File(File(appCtx.cacheDir, DIR), "${rel.fileName()}.part").delete() }
            runCatching { File(File(appCtx.cacheDir, DIR), "${rel.fileName()}.part.json").delete() }
        }
        prefs.edit().putString(KEY_SKIPPED, rel.muteKey()).apply()
        if (::appCtx.isInitialized) UpdateNotifications.cancel(appCtx)
        _dialogShown.value = true
        _state.value = UpdateState.Idle
    }

    /** 只是把弹窗收起来(没有新版本可跳时不记跳过)。 */
    fun reset() {
        if (::appCtx.isInitialized) UpdateNotifications.cancel(appCtx)
        _dialogShown.value = true
        _state.value = UpdateState.Idle
    }

    private fun fetchLatest(): Release? {
        apiLatest()?.let { return it }
        return atomLatest()
    }

    /// REST 列表(主路):要 digest 校验下载字节并给落盘文件取名,API 一次就带回来了。
    /// 限额用尽时它回 403 —— 那只是**降级信号**,不是检测失败,交给 [atomLatest]。
    private fun apiLatest(): Release? = try {
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

    /// Atom 兜底:只有 tag,没有大小与 digest,所以拿直链 HEAD 补大小。
    /// 只认纯数字版本(可带 v),预发布 tag 不推给用户;没有任何比本机新的就返回一条空读数。
    private fun atomLatest(): Release? = try {
        val req = Request.Builder()
            .url(ATOM_URL)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            .header("Accept", "application/atom+xml")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                Logger.w(TAG, "update atom http ${resp.code} endpoint=${Logger.endpoint(ATOM_URL)}")
                null
            } else {
                val tags = parseAtomTags(resp.body?.string().orEmpty())
                val newest = tags.firstOrNull() ?: return null
                if (!isNewer(newest, BuildConfig.VERSION_NAME)) {
                    return Release(tag = newest, apkUrls = emptyList(), size = 0L, sha256 = null)
                }
                for (tag in tags.asSequence().filter { isNewer(it, BuildConfig.VERSION_NAME) }.take(5)) {
                    val direct = DOWNLOAD_BASE + Uri.encode(tag) + "/" + APK_ASSET_NAME
                    val size = probeApk(direct)
                    if (size > 0L) {
                        Logger.i(TAG, "update atom found tag=$tag size=$size")
                        return Release(tag = tag, apkUrls = listOf(direct), size = size, sha256 = null)
                    }
                }
                Logger.w(TAG, "update atom no reachable apk in ${tags.size} tags")
                null
            }
        }
    } catch (e: Exception) {
        Logger.e(TAG, "update atom error endpoint=${Logger.endpoint(ATOM_URL)}", e)
        null
    }

    /// 直链 HEAD 取字节数;404(那一版没挂 apk)与网络失败都回 0,由调用方换下一版。
    private fun probeApk(url: String): Long {
        return try {
            val req = Request.Builder().url(url)
                .header("User-Agent", "Reverb/1.0 (Android podcast client)")
                .head()
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return 0L
                if (resp.request.url.host !in TRUSTED_HOSTS) {
                    Logger.w(TAG, "update atom untrusted host ${resp.request.url.host}")
                    return 0L
                }
                resp.body?.contentLength()?.takeIf { it > 0L } ?: 0L
            }
        } catch (e: Exception) {
            Logger.w(TAG, "update atom head failed: ${e.javaClass.simpleName}")
            0L
        }
    }

    /**
     * Atom 流里的 `<title>` 就是 tag。只认纯数字版本(可带 v 前缀),去重后按版本降序。
     * 单独拆出来是为了能单测 —— 解析错会把 beta 或旧版推给用户。
     */
    internal fun parseAtomTags(xml: String): List<String> {
        val seen = LinkedHashSet<String>()
        for (m in ATOM_ENTRY.findAll(xml)) {
            val raw = m.groupValues[1].trim()
            if (!isStableVersionTag(raw)) continue
            seen.add(raw)
        }
        return seen.sortedWith { a, b ->
            when {
                isNewer(a, b) -> -1
                isNewer(b, a) -> 1
                else -> 0
            }
        }
    }

    internal fun isStableVersionTag(raw: String): Boolean {
        val s = raw.trim().trimStart('v', 'V')
        return s.isNotEmpty() && s.matches(Regex("\\d+(\\.\\d+)*"))
    }

    /** `Content-Range: bytes 1000-2023/6622867` → `(1000, 6622867)`;总量 `*` 记 0。 */
    internal fun parseContentRange(raw: String?): Pair<Long, Long>? {
        if (raw.isNullOrBlank()) return null
        val parts = raw.trim().split(" ", limit = 2)
        if (parts.size != 2 || parts[0] != "bytes") return null
        val halves = parts[1].split("/", limit = 2)
        if (halves.size != 2) return null
        val start = halves[0].substringBefore('-').toLongOrNull() ?: return null
        val total = if (halves[1] == "*") 0L else halves[1].toLongOrNull() ?: 0L
        return start to total
    }

    /**
     * 列表接口返回的是**数组**,所以要逐个 release 过一遍再挑,而不是"取第一条"。
     * 挑法:先滤掉 draft / prerelease(与原先 `latest` 接口的口径一致 —— 那两个字段是列表接口才给的,
     * `latest` 在服务端就滤过了),再要求它挂着可用的 apk 资产,最后按版本名取最大的那一个。
     *
     * ⚠️ **数组顺序不是契约**(GitHub 当前按时间倒序给,但那是碰巧),所以这里必须自己比版本;
     * 而两个 release 版本名相同时取先遇到的那个 —— 同版本一律不提示、不下载,
     * 所以取哪一份都不会改变检测结论。见 H234。
     */
    private fun parse(json: String?): Release? {
        if (json.isNullOrBlank()) return null
        return try {
            val arr = org.json.JSONArray(json)
            var best: Release? = null
            for (i in 0 until arr.length()) {
                val rel = releaseOf(arr.optJSONObject(i)) ?: continue
                val cur = best
                if (cur == null || isNewer(rel.tag, cur.tag)) best = rel
            }
            if (best == null) Logger.w(TAG, "update check no usable release in ${arr.length()} entries")
            best
        } catch (e: Exception) {
            Logger.e(TAG, "update parse failed", e)
            null
        }
    }

    /** 单个 release JSON → [Release]。不合格(draft / prerelease / 没版本名 / 没可用资产)一律 null。 */
    private fun releaseOf(o: JSONObject?): Release? {
        if (o == null) return null
        if (o.optBoolean("draft") || o.optBoolean("prerelease")) return null
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
        return Release(
            tag = tag,
            apkUrls = urls,
            size = asset.optLong("size", 0L),
            // 公开发布页给的校验串;老 release 没有这个字段,没有就不校验(见 download 里那条 log)
            sha256 = asset.optString("digest", "").removePrefix("sha256:").lowercase()
                .takeIf { it.length >= 16 && it.all { c -> c in "0123456789abcdef" } }
        )
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

        /// 检测请求在飞(自动那一轮也会经过这里,但只有主动查才把它显示出来)
        object Checking : UpdateState()

        /// 主动查过、且发布页那一版版本名不高于本机(同 versionCode) —— 只给设置那一行看
        data class UpToDate(val tag: String) : UpdateState()

        /// 主动查而没问到东西(HTTP 失败 / 网络不通 / 响应里没有一个可用 release) —— 也只给设置那一行看。
        /// 与 [Failed] 不是一回事:那条是**安装包下载**失败,这一条连版本都没拿到。
        object CheckFailed : UpdateState()

        /// 计费网络:先问一句,点头才下
        data class AskCellular(val rel: Release) : UpdateState()

        data class Downloading(val rel: Release, val percent: Int) : UpdateState()

        data class Ready(val rel: Release, val file: File) : UpdateState()

        data class Failed(val rel: Release) : UpdateState()
    }

    enum class InstallHandoff { Started, NeedPermission, NotFound, Lost }

    /**
     * [apkUrls] 是**按优先级排的候选地址**,不是列表 UI 能选的东西 —— 见 [ASSET_API_URL] 的注释。
     * [republished] 是历史字段(原「同版本名不同字节」的弹窗措辞开关),口径改后恒为 false;
     * 字段留着只为不动 UI 分支,不再参与任何检测判断。
     */
    data class Release(
        val tag: String,
        val apkUrls: List<String>,
        val size: Long,
        val sha256: String?,
        val republished: Boolean = false
    ) {
        /**
         * 「以后再说」记的那把键:版本名 + 摘要前 12 位。
         * 下一版 tag 不同就不会被静音;同一版只静音那一份发布物。
         */
        fun muteKey(): String = tag + "@" + (sha256?.take(12) ?: "nodigest")
    }

    /**
     * 落盘文件名。`tag` 来自发布页,**必须当外部输入**:版本号里出现 `/` 或 `..`
     * 就会把文件写到缓存目录外面去(而那个目录是 FileProvider 对外可读的)。
     * 只留 `[0-9A-Za-z._-]`,其余替成 `_`,并夹长度。
     *
     * ⚠️ 摘要前缀不是可选的装饰:「上次下完没装就直接给安装」那条捷径只比字节数,
     * 而重出包完全可能撞出同一个字节数(1.0.6 那三次里有两次同为 65 057 348 B,见 H154 同形教训)——
     * 名字不带摘要,那条捷径就会把**旧字节**当新版本递给系统安装器。
     */
    fun Release.fileName(): String {
        val safe = tag.take(40).map { if (it.isLetterOrDigit() || it == '.' || it == '-') it else '_' }
            .joinToString("")
            .trimStart('.')
        val suffix = sha256?.take(8).orEmpty()
        val base = if (suffix.isEmpty()) "reverb-${if (safe.isEmpty()) "new" else safe}"
        else "reverb-${if (safe.isEmpty()) "new" else safe}-$suffix"
        return "$base.apk"
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
