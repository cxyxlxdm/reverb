package com.yuyin.reverb.update

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.yuyin.reverb.ReverbApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicInteger

/**
 * 周期性抓取订阅 RSS，检测是否有新一期，有则发通知。首次运行只记录、不打扰。
 *
 * **为什么要限并发 + 单源超时(见 REVIEW-2026-10-25 低·族 C-3)**:
 * 原先这一轮是 `for (p in subs) { repository.feed(...) }` —— 串行、且单个源没有任何时限。
 * 两个账叠在一起就会踩到 WorkManager 的预算:
 *  - OkHttp 客户端配的是 `callTimeout(30s)`(见 `ReverbApp`),也就是**一个慢源最坏占 30 秒**;
 *  - 串行 × 订阅数 ⇒ 40 个订阅里有几个慢源就是十几分钟,而 `CoroutineWorker` 的执行预算是 **10 分钟**,
 *    超了系统就取消本帧作业。取消的症状不是报错,而是**排在后面的那些订阅这一轮根本没被抓过** ——
 *    用户看到的就是"某个频道有新集却不提醒",而且和订阅顺序有关、无法复现。
 *
 * 同一份判据仓库里已经有现成的范式:`InboxStore.refresh` 用 `Semaphore(8)` 限并发 +
 * 单源 `withTimeoutOrNull(8s)`。这里照它做,只是并发度取 [PARALLELISM](后台作业,比 UI 那条路
 * 再让一档,别和前台的追更刷新抢同一条链路的连接数)。
 *
 * **超时的订阅怎么办**:本轮跳过(`lastSeen` 不推进),下一轮照常重抓 ——
 * 所以最坏后果是**晚一轮提醒**,不是丢提醒。这正是"限流"该有的失败方向。
 */
class FeedUpdateWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val app = applicationContext as? ReverbApp ?: return Result.success()
        val container = app.container
        val subs = container.subscriptionStore.subscriptions.value
        com.yuyin.reverb.util.Logger.i(TAG, "run start subs=${subs.size}")
        if (subs.isEmpty()) return Result.success()

        val updateStore = container.updateStore
        // 并发写的一侧:各协程抓到自己那一集就 add,所以用锁收口(单条 add 不重,但列表本身不是线程安全的)
        val updatedTitles = ArrayList<String>()
        val gate = Semaphore(PARALLELISM)
        // 计数只进日志,但协程跑在多个 IO 线程上,普通 var ++ 是数据竞争 —— 用原子量
        val timeouts = AtomicInteger()
        val failures = AtomicInteger()

        coroutineScope {
            subs.forEach { p ->
                launch(Dispatchers.IO) {
                    gate.withPermit {
                        val feed = try {
                            withTimeout(PER_FEED_TIMEOUT_MS) {
                                try {
                                    container.repository.feed(p.feedUrl)
                                } catch (e: Exception) {
                                    // 抓取本身失败(离线 / 404 / 解析不出):与改动前同一口径记一行,本轮跳过
                                    failures.incrementAndGet()
                                    com.yuyin.reverb.util.Logger.e(
                                        TAG,
                                        "feed failed endpoint=${com.yuyin.reverb.util.Logger.endpoint(p.feedUrl)}",
                                        e
                                    )
                                    null
                                }
                            }
                        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                            // 单源到点即弃:不阻塞其余订阅,本轮跳过它(见类注释的失败方向)
                            timeouts.incrementAndGet()
                            com.yuyin.reverb.util.Logger.w(
                                TAG,
                                "feed timeout title='${p.title}' endpoint=${com.yuyin.reverb.util.Logger.endpoint(p.feedUrl)}"
                            )
                            null
                        } ?: return@withPermit
                        val latest = feed.episodes.firstOrNull() ?: return@withPermit
                        val prev = updateStore.lastSeen(p.feedUrl)
                        when {
                            prev == null -> updateStore.setLastSeen(p.feedUrl, latest.id) // 首次只记录
                            latest.id != prev -> {
                                com.yuyin.reverb.util.Logger.i(TAG, "new episode title='${p.title}' latest=${latest.id}")
                                synchronized(updatedTitles) { updatedTitles.add(p.title) }
                                updateStore.setLastSeen(p.feedUrl, latest.id)
                            }
                        }
                    }
                }
            }
        }

        com.yuyin.reverb.util.Logger.i(
            TAG,
            "run done updated=${updatedTitles.size} timeouts=${timeouts.get()} failures=${failures.get()} subs=${subs.size}"
        )
        if (updatedTitles.isNotEmpty()) {
            Notifications.postUpdates(applicationContext, updatedTitles.size, updatedTitles)
        }
        return Result.success()
    }

    private companion object {
        const val TAG = "FeedWorker"

        /** 后台并发度:比 `InboxStore.parallelism`(8)让一档,别和前台追更刷新抢连接。 */
        const val PARALLELISM = 6

        /**
         * 单源上限。**比 OkHttp 的 `callTimeout(30s)` 短才有意义** —— 30 秒那条是"这次请求别再挂着",
         * 而这里要的是"这一轮别被一个源拖死"。取 8 秒与 `InboxStore.perFeedTimeoutMs` 同一档:
         * 一次 RSS 抓取 = 下载 + 解析,慢源最坏是几百 KB / 上千集,8 秒覆盖得住正常情况。
         */
        const val PER_FEED_TIMEOUT_MS = 8_000L
    }
}
