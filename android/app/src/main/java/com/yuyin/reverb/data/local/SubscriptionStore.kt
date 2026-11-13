package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.sync.SyncTombstones
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** 本地订阅：以 JSON 文件持久化在应用私有目录，零依赖、无需数据库。 */
class SubscriptionStore(context: Context) {

    private val file = File(context.filesDir, "subscriptions.json")
    private val lock = Any()

    private val _subscriptions = MutableStateFlow(load())
    val subscriptions: StateFlow<List<Podcast>> = _subscriptions

    /**
     * 退订时的附加动作(由 AppContainer 接到 `FeedAuthStore.forget`)。
     * 为什么退订要清凭据:口令只服务于"这一个源还能不能用",用户不再订阅之后
     * 让它在设备上继续躺着没有理由;代价只是重新订阅时再输一次。
     */
    var onRemoved: ((Podcast) -> Unit)? = null

    fun isSubscribed(id: String): Boolean = _subscriptions.value.any { it.id == id }

    fun toggle(podcast: Podcast) {
        synchronized(lock) {
            val current = _subscriptions.value.toMutableList()
            val idx = current.indexOfFirst { it.id == podcast.id }
            val removed = idx >= 0
            if (removed) current.removeAt(idx) else current.add(0, podcast)
            _subscriptions.value = current
            persist(current)
            com.yuyin.reverb.util.Logger.i("SubStore", "${if (removed) "remove" else "add"} id=${podcast.id} total=${current.size}")
            if (removed) onRemoved?.invoke(podcast)
            // 删除墓碑:下一次同步时对端不能把这条再带回来;重新订阅则清掉墓碑。
            val tombKey = SyncTombstones.subscriptionKey(podcast.feedUrl, podcast.id)
            if (removed) SyncTombstones.record(SyncTombstones.SUBSCRIPTIONS, tombKey)
            else SyncTombstones.clear(SyncTombstones.SUBSCRIPTIONS, tombKey)
        }
    }

    fun addAll(podcasts: List<Podcast>) {
        synchronized(lock) {
            val current = _subscriptions.value.toMutableList()
            for (p in podcasts) if (current.none { it.id == p.id }) current.add(p)
            _subscriptions.value = current
            persist(current)
            // 备份恢复与同步并入都是「把外部的条目重新加进来」,按主观意图等于重新订阅:
            // 不清墓碑的话,下一次同步会把它当成"已删除"再删一遍。
            // 同步路径上走到这里的条目已经过 `LanSyncMerge` 的墓碑过滤,这一步对它是空转。
            podcasts.forEach {
                SyncTombstones.clear(SyncTombstones.SUBSCRIPTIONS, SyncTombstones.subscriptionKey(it.feedUrl, it.id))
            }
            com.yuyin.reverb.util.Logger.i("SubStore", "addAll +${podcasts.size} total=${current.size}")
        }
    }

    private fun load(): List<Podcast> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<Podcast>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                // 逐条 runCatching:一条坏元素只丢那一条。原先整份只有一个 try,
                // 中间任何一条抛出来就是"订阅全没了",而空态紧接着会被下一次 persist 落回盘上
                // (见 JsonWriter.writeAtomically 的空态闸,REVIEW-2026-10-25 高-3 附带条)。
                val p = runCatching {
                    Podcast(
                        id = o.optString("id"),
                        title = o.optString("title"),
                        author = o.optString("author"),
                        artworkUrl = o.optString("artworkUrl"),
                        feedUrl = o.optString("feedUrl"),
                        description = o.optString("description"),
                        genre = o.optString("genre"),
                        isPaid = o.optBoolean("isPaid", false),
                        fundingUrl = o.optString("fundingUrl"),
                        fundingLabel = o.optString("fundingLabel")
                    )
                }.getOrNull()
                if (p != null) out.add(p)
                else com.yuyin.reverb.util.Logger.w("SubStore", "subscriptions.json 第 $i 条读坏了,跳过")
            }
            out
        } catch (e: Exception) {
            // 顶层读坏 ≠ 这份数据是空的:标记 + 留证,后续的空态整份写回会被 JsonWriter 挡下
            JsonWriter.markLoadFailed(file)
            com.yuyin.reverb.util.Logger.e("SubStore", "subscriptions.json 读取失败,按空处理", e)
            emptyList()
        }
    }

    private fun persist(list: List<Podcast>) {
        try {
            val arr = JSONArray()
            for (p in list) {
                arr.put(
                    JSONObject()
                        .put("id", p.id)
                        .put("title", p.title)
                        .put("author", p.author)
                        .put("artworkUrl", p.artworkUrl)
                        .put("feedUrl", p.feedUrl)
                        .put("description", p.description)
                        .put("genre", p.genre)
                        .put("isPaid", p.isPaid)
                        .put("fundingUrl", p.fundingUrl)
                        .put("fundingLabel", p.fundingLabel)
                )
            }
            // 原子写(.part → rename):订阅是用户最重的一份资产,截断重写等于一次进程被杀全丢
            // 见 REVIEW-2026-10-25 高-3。这里**不走去抖**(见 JsonWriter 顶部那条分工理由),
            // 但落盘出口必须和去抖那五份文件同一个。
            JsonWriter.writeAtomically(file, arr.toString())
        } catch (e: Exception) {
            // 持久化失败不影响内存态，忽略
        }
    }
}
