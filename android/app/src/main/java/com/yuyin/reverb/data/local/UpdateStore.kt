package com.yuyin.reverb.data.local

import android.content.Context

/** 记录每个订阅上次已知的最新一集 id，用于检测更新。 */
class UpdateStore(context: Context) {
    private val prefs = context.getSharedPreferences("reverb_updates", Context.MODE_PRIVATE)

    /**
     * 读回这个订阅上次已知的最新一集 id；认不出来源的一律当「首次见到」（回 null）。
     *
     * 为什么键还是 `String.hashCode()`（见 REVIEW-2026-10-25 低·族 A）：
     * 32 位散列按生日悖论约 7.7 万个 feedUrl 就有一半概率撞一对，撞上之后 A 频道「上次看到哪一集」
     * 会被当成 B 频道的基线，于是 B 每次刷新都觉得「换了新的一集」 —— 表现为一夜之间通知 spam。
     * 另外三处（`dl_` / `ca_` / `asr-`）拼的是文件名，直接换 SHA-256 截断就行；
     * 这里是 SharedPreferences 的**键**，换算法会让全部旧键变成孤儿（旧条目既读不到也清不掉），
     * 所以取「键不动、把可验证的信息放进 value」：值改成 `feedUrl + SEP + episodeId`，
     * 读时先验 feedUrl 与键的主人是否一致，不一致（撞键、或升级前的旧格式）就当没见过。
     *
     * 为什么「当没见过」不会造成通知风暴：见
     * [com.yuyin.reverb.update.FeedUpdateWorker] —— 它对 `prev == null` 的分支是**只记录、不发通知**
     * （「首次只记录」），所以旧格式条目最多让一个订阅少提醒一次，而不是连响一片。
     */
    fun lastSeen(feedUrl: String): String? {
        val raw = prefs.getString(key(feedUrl), null) ?: return null
        val sep = raw.indexOf(SEP)
        // sep == -1 是升级前的旧格式（裸 episodeId）；sep == 0 意味着 feedUrl 段为空。都不作数
        if (sep <= 0) return null
        if (raw.substring(0, sep) != feedUrl) {
            com.yuyin.reverb.util.Logger.w(TAG, "更新记录与订阅不匹配，按首次处理 key=${key(feedUrl)}")
            return null
        }
        return raw.substring(sep + 1).ifEmpty { null }
    }

    fun setLastSeen(feedUrl: String, episodeId: String) {
        prefs.edit().putString(key(feedUrl), feedUrl + SEP + episodeId).apply()
    }

    private fun key(feedUrl: String) = "seen_" + feedUrl.hashCode()

    private companion object {
        const val TAG = "UpdateStore"

        /**
         * 分隔符取 U+0001（控制字符）。feedUrl 是 URL、episodeId 是 guid 或 URL，
         * 两者按规范都不含控制字符，所以拿它当分界不会有歧义、也不必转义；
         * 写成 `1.toChar()` 而不是字面量，是因为这个字符在源码里不可见，容易被编辑器吃掉。
         */
        val SEP: Char = 1.toChar()
    }
}
