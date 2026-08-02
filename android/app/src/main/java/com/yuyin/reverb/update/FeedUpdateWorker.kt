package com.yuyin.reverb.update

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.yuyin.reverb.ReverbApp

/** 周期性抓取订阅 RSS，检测是否有新一期，有则发通知。首次运行只记录、不打扰。 */
class FeedUpdateWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val app = applicationContext as? ReverbApp ?: return Result.success()
        val container = app.container
        val subs = container.subscriptionStore.subscriptions.value
        if (subs.isEmpty()) return Result.success()

        val updateStore = container.updateStore
        val updatedTitles = ArrayList<String>()

        for (p in subs) {
            val feed = try {
                container.repository.feed(p.feedUrl)
            } catch (e: Exception) {
                null
            } ?: continue
            val latest = feed.episodes.firstOrNull() ?: continue
            val prev = updateStore.lastSeen(p.feedUrl)
            when {
                prev == null -> updateStore.setLastSeen(p.feedUrl, latest.id) // 首次只记录
                latest.id != prev -> {
                    updatedTitles.add(p.title)
                    updateStore.setLastSeen(p.feedUrl, latest.id)
                }
            }
        }

        if (updatedTitles.isNotEmpty()) {
            Notifications.postUpdates(applicationContext, updatedTitles.size, updatedTitles)
        }
        return Result.success()
    }
}
