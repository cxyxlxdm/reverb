package com.yuyin.reverb.data.local

import android.content.Context

/** 记录每个订阅上次已知的最新一集 id，用于检测更新。 */
class UpdateStore(context: Context) {
    private val prefs = context.getSharedPreferences("reverb_updates", Context.MODE_PRIVATE)

    fun lastSeen(feedUrl: String): String? = prefs.getString(key(feedUrl), null)

    fun setLastSeen(feedUrl: String, episodeId: String) {
        prefs.edit().putString(key(feedUrl), episodeId).apply()
    }

    private fun key(feedUrl: String) = "seen_" + feedUrl.hashCode()
}
