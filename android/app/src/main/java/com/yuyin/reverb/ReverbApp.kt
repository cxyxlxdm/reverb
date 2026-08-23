package com.yuyin.reverb

import android.app.Application
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.yuyin.reverb.data.local.CategoryStore
import com.yuyin.reverb.data.local.DownloadStore
import com.yuyin.reverb.data.local.FavoriteStore
import com.yuyin.reverb.data.local.FeedCacheStore
import com.yuyin.reverb.data.local.HistoryStore
import com.yuyin.reverb.data.local.InboxStore
import com.yuyin.reverb.data.local.ListenStatsStore
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
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.update.FeedUpdateWorker
import com.yuyin.reverb.update.Notifications
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/** 极简手写依赖容器，避免引入 DI 框架带来的构建复杂度。 */
class AppContainer(app: Application) {
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
    val repository = PodcastRepository(httpClient, popularCache, seedCatalog, feedCache)

    val subscriptionStore = SubscriptionStore(app)
    val inboxStore = InboxStore(app)
    val categoryStore = CategoryStore(app)
    val downloadStore = DownloadStore(app)
    val historyStore = HistoryStore(app)
    val listenStatsStore = ListenStatsStore(app)
    val favoriteStore = FavoriteStore(app)
    val stampStore = StampStore(app)
    val updateStore = UpdateStore(app)
    val regionStore = RegionStore(app)
    val settingsStore = SettingsStore(app)

    // 转写:先取发布方自己的逐字稿,取不到才(在有引擎的渠道)本机识别
    val transcriptFetcher = TranscriptFetcher(httpClient)
    val transcriptStore = TranscriptStore(app, transcriptFetcher)
    /**
     * 离线识别引擎。**大陆商店渠道恒为 null** —— 那个 flavor 的 `AsrFactory` 是空实现,
     * 包里连 `.so` 与模型都没有(见 `playback/asr/AsrEngine` 的注释)。
     * 用 lazy:模型是几十 MB,不能在应用启动时就读进内存,得等用户真的要转写。
     */
    val asrEngine: com.yuyin.reverb.playback.asr.AsrEngine? by lazy { AsrFactory.create(app) }
}

class ReverbApp : Application() {
    override fun attachBaseContext(base: android.content.Context) {
        super.attachBaseContext(com.yuyin.reverb.util.LocaleUtil.wrap(base))
    }

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        com.yuyin.reverb.util.Logger.init(this)
        container = AppContainer(this)

        DownloadManager.init(this, container.httpClient, container.downloadStore, container.settingsStore)
        PlayerController.bindHistory(container.historyStore)
        PlayerController.bindSettings(container.settingsStore)
        PlayerController.bindListenStats(container.listenStatsStore)
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
                    "stamps=${container.stampStore.stamps.value.size} downloads=${container.downloadStore.downloads.value.size}"
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
