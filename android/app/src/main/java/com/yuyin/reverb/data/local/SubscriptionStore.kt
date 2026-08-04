package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Podcast
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
        }
    }

    fun addAll(podcasts: List<Podcast>) {
        synchronized(lock) {
            val current = _subscriptions.value.toMutableList()
            for (p in podcasts) if (current.none { it.id == p.id }) current.add(p)
            _subscriptions.value = current
            persist(current)
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
                out.add(
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
                )
            }
            out
        } catch (e: Exception) {
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
            file.writeText(arr.toString())
        } catch (e: Exception) {
            // 持久化失败不影响内存态，忽略
        }
    }
}
