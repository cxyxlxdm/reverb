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
import com.yuyin.reverb.data.local.HistoryStore
import com.yuyin.reverb.data.local.InboxStore
import com.yuyin.reverb.data.local.PopularCacheStore
import com.yuyin.reverb.data.local.RegionStore
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.data.local.StampStore
import com.yuyin.reverb.data.local.SubscriptionStore
import com.yuyin.reverb.data.local.UpdateStore
import com.yuyin.reverb.data.remote.PodcastRepository
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

    // 全链路零配置：Apple + fyyd.de + gpodder.net + RSS/OPML，均免费无需 Key。
    val repository = PodcastRepository(httpClient, popularCache)

    val subscriptionStore = SubscriptionStore(app)
    val inboxStore = InboxStore(app)
    val categoryStore = CategoryStore(app)
    val downloadStore = DownloadStore(app)
    val historyStore = HistoryStore(app)
    val favoriteStore = FavoriteStore(app)
    val stampStore = StampStore(app)
    val updateStore = UpdateStore(app)
    val regionStore = RegionStore(app)
    val settingsStore = SettingsStore(app)
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
        Notifications.ensureChannel(this)
        val updatesEnabled = container.settingsStore.updatesEnabled.value
        if (updatesEnabled) scheduleFeedUpdates(this) else cancelFeedUpdates(this)

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
