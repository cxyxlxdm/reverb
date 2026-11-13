package com.yuyin.reverb

import android.app.Application
import androidx.work.Configuration
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.yuyin.reverb.data.local.AudioCacheStore
import com.yuyin.reverb.data.local.CategoryStore
import com.yuyin.reverb.data.local.DownloadStore
import com.yuyin.reverb.data.local.FavoriteStore
import com.yuyin.reverb.data.local.FeedCacheStore
import com.yuyin.reverb.data.local.HistoryStore
import com.yuyin.reverb.data.local.InboxStore
import com.yuyin.reverb.data.local.ListenStatsStore
import com.yuyin.reverb.data.local.NoteStore
import com.yuyin.reverb.data.local.PlaybackStateStore
import com.yuyin.reverb.data.local.PopularCacheStore
import com.yuyin.reverb.data.local.RegionStore
import com.yuyin.reverb.data.local.SeedCatalog
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.data.local.StampStore
import com.yuyin.reverb.data.local.SubscriptionStore
import com.yuyin.reverb.data.local.TranscriptStore
import com.yuyin.reverb.data.local.UpdateStore
import com.yuyin.reverb.data.remote.PodcastRepository
import com.yuyin.reverb.data.remote.TranscriptFetcher
import com.yuyin.reverb.playback.asr.AsrFactory
import com.yuyin.reverb.playback.AudioCacheManager
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.update.FeedUpdateWorker
import com.yuyin.reverb.update.Notifications
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/** 极简手写依赖容器，避免引入 DI 框架带来的构建复杂度。 */
class AppContainer(app: Application) {
    init {
        // 删除墓碑账本要先开:各 store 的删除动作都会往里记一笔(见 `SyncTombstones`)。
        com.yuyin.reverb.sync.SyncTombstones.configure(app)
    }

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    val popularCache = PopularCacheStore(app)
    // 随包内置的精选清单：缓存为空（首装/清缓存/无网）时给发现页兜底，避免首屏空白
    val seedCatalog = SeedCatalog(app)
    // 频道详情（解析后的 RSS）缓存：详情页秒开，且断网时仍能看已访问过的频道
    val feedCache = FeedCacheStore(app)

    // 全链路零配置：Apple + fyyd.de + gpodder.net + RSS/OPML，均免费无需 Key。
    /**
     * 私有源凭据(HTTP Basic)。单独一份账本、**不进系统备份与手动备份**,
     * 只发给源自己(同主机)的 feed / 音频 / 逐字稿请求。见 H253。
     */
    val feedAuthStore = com.yuyin.reverb.data.local.FeedAuthStore(app)

    // (私有源是用户自己带凭据的那一类,不改变"公共目录零配置"这条。)
    val repository = PodcastRepository(httpClient, popularCache, seedCatalog, feedCache, feedAuthStore)

    val subscriptionStore = SubscriptionStore(app).also { sub ->
        // 退订即丢弃这个源的凭据(见 SubscriptionStore.onRemoved 的注释)
        sub.onRemoved = { podcast -> feedAuthStore.forget(podcast.feedUrl) }
    }
    val inboxStore = InboxStore(app)
    val categoryStore = CategoryStore(app)
    val downloadStore = DownloadStore(app)
    /**
     * 「播过即缓存」的账本。刻意与 [downloadStore] 分成两份:下载是用户点名留的、进备份、
     * 由「清除下载」负责;缓存是 App 为「下次别联网」自己攒的、可被 300 MB 预算挤掉、**不进备份**。
     */
    val audioCacheStore = AudioCacheStore(app)
    val historyStore = HistoryStore(app)
    val listenStatsStore = ListenStatsStore(app)
    val favoriteStore = FavoriteStore(app)
    val stampStore = StampStore(app)
    val noteStore = NoteStore(app)
    // 「正在播哪一集 / 它来自哪一列 / 排好的 up next」的跨启动快照。
    // 刻意**不进**任何备份(白名单里没有它):那是这台设备上的一次性排程,理由写在 store 顶部。
    val playbackStateStore = PlaybackStateStore(app)
    val updateStore = UpdateStore(app)
    val regionStore = RegionStore(app)
    val settingsStore = SettingsStore(app)

    // 转写:先取发布方自己的逐字稿,取不到才在引擎可用时走本机识别(见 asrEngine 那条注释)
    val transcriptFetcher = TranscriptFetcher(httpClient) { url -> feedAuthStore.headerForUrl(url) }
    val transcriptStore = TranscriptStore(app, transcriptFetcher)
    // 章节表(podcast:chapters):取一次、落盘、离线也能跳。与逐字稿吃同一份凭据与网络口径。
    val chaptersFetcher = com.yuyin.reverb.data.remote.ChaptersFetcher(httpClient) { url ->
        feedAuthStore.headerForUrl(url)
    }
    val chapterStore = com.yuyin.reverb.data.local.ChapterStore(app, chaptersFetcher)
    /**
     * 离线识别引擎。**只有一份包,所以它不带 null 那一支了** —— 合并前商店那个 flavor 的
     * `AsrFactory` 是空实现,包里连 `.so` 与模型都没有(见 `playback/asr/AsrEngine` 的注释与 H205)。
     * 用 lazy:模型是几十 MB,不能在应用启动时就读进内存,得等用户真的要转写。
     */
    val asrEngine: com.yuyin.reverb.playback.asr.AsrEngine? by lazy { AsrFactory.create(app) }

    /**
     * 局域网同步。**lazy**:监听端口与 mDNS 广播只在用户打开「局域网同步」面板时才开始
     * (见 `LanSyncController.start`),不在启动时付这份代价,也不在后台常驻监听。
     */
    val lanSync by lazy { com.yuyin.reverb.sync.LanSyncController(app, this) }
}

class ReverbApp : Application(), Configuration.Provider {
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().build()

    override fun attachBaseContext(base: android.content.Context) {
        super.attachBaseContext(com.yuyin.reverb.util.LocaleUtil.wrap(base))
    }

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        com.yuyin.reverb.util.Logger.init(this)
        container = AppContainer(this)

        DownloadManager.init(this, container.httpClient, container.downloadStore, container.settingsStore,
            container.feedAuthStore)
        // 缓存的 init 不发任何网络请求(只建目录 + 一次对账扫盘),所以与同意门无关,放这里没问题;
        // 真正拉音频要等用户点播放,那时门早已过了。
        AudioCacheManager.init(this, container.httpClient, container.audioCacheStore, container.settingsStore,
            container.feedAuthStore)
        PlayerController.bindHistory(container.historyStore)
        // 视频源的直链要现取(2 小时失效),所以播放层要握着一个能联网的对象;
        // 与 repo 共用同一个 client,不另建连接池。
        PlayerController.bindBilibili(container.repository.bilibili)
        PlayerController.bindSettings(container.settingsStore)
        PlayerController.bindListenStats(container.listenStatsStore)
        PlayerController.bindState(container.playbackStateStore)
        // 桌面卡片从历史单集起播时,上一集 / 下一集要靠本地频道缓存补上下文。
        // **只读缓存**,不触发任何网络请求(与鸿蒙 bindFeedEpisodes 同一口径)。
        PlayerController.bindFeedEpisodes { feedUrl ->
            container.feedCache.get(feedUrl)?.result?.episodes.orEmpty()
        }
        container.listenStatsStore.seedFromHistory(container.historyStore.history.value)
        Notifications.ensureChannel(this)
        // **不在这里排 WorkManager 任务**:带网络约束的周期任务会让 WorkManager 的约束追踪器
        // 读取系统网络状态,而 Application.onCreate 早于用户同意隐私政策。
        // 改由 MainActivity 在同意之后调 scheduleFeedUpdates(见 startGatedComponents)。
        // 这里只负责「已关掉提醒就取消既有任务」——取消不读任何网络信息。
        // 连 cancelFeedUpdates 也要等同意之后:`WorkManager.getInstance()` 本身会初始化
        // WorkManager,其 ForceStopRunnable 在重排既有任务时会挂上约束监听、进而读网络状态。
        // 未同意的情况下压根没排过任务,也就无需取消。
        val updatesEnabled = container.settingsStore.updatesEnabled.value
        if (container.settingsStore.privacyAccepted.value && !updatesEnabled) cancelFeedUpdates(this)

        try {
            val region = container.regionStore.override.value ?: "auto"
            val lang = container.settingsStore.language.value.ifBlank { "system" }
            com.yuyin.reverb.util.Logger.i(
                TAG,
                "app launch v${BuildConfig.VERSION_NAME} region=$region lang=$lang " +
                    "updatesScheduled=$updatesEnabled subs=${container.subscriptionStore.subscriptions.value.size} " +
                    "favs=${container.favoriteStore.favorites.value.size} history=${container.historyStore.history.value.size} " +
                    "stamps=${container.stampStore.stamps.value.size} notes=${container.noteStore.notes.value.size} " +
                    "downloads=${container.downloadStore.downloads.value.size} " +
                    // 缓存条数打在这里(读内存账本,不扫盘):它是唯一能区分"没缓存成"与
                    // "缓存过但文件已不在"的地方。字节数**不在这里取** —— usageBytes() 要 listFiles,
                    // 那是给启动加一次主线程磁盘往返(口径见 H65),设置页需要时自己去算。
                    "audioCache=${AudioCacheManager.cachedCount()} " +
                    // 队列不属任何备份分区,但它是用户排出来的东西 —— 装机取证要靠这一行判断
                    // "冷启动到底读回了没有"(读回失败与"本来就没排队"在界面上是同一个样子)。
                    "upNext=${container.playbackStateStore.snapshot.upNext.size} " +
                    "playingCur=${container.playbackStateStore.snapshot.current?.id ?: "-"}"
            )
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.e(TAG, "launch log failed", e)
        }
    }

    companion object {
        private const val TAG = "App"
        const val UPDATE_WORK = "feed-update"

        fun scheduleFeedUpdates(context: android.content.Context) {
            val work = PeriodicWorkRequestBuilder<FeedUpdateWorker>(6, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UPDATE_WORK,
                ExistingPeriodicWorkPolicy.KEEP,
                work
            )
        }

        fun cancelFeedUpdates(context: android.content.Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UPDATE_WORK)
        }
    }
}
