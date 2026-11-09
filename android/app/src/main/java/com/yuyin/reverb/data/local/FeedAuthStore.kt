package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.FeedCredential
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File
import java.net.URI

/**
 * 私有订阅源的凭据账本:`feedUrl -> 用户名/密码`。
 *
 * 三条口径(与 `docs/FEATURES.md` 渠道/订阅那一节同源):
 *  1. **只存本机,不进任何备份。** 系统级备份是白名单制(`app/src/main/res/xml/backup_rules.xml`),
 *     本文件没被列出就天然不在里面;手动备份(`BackupManager`)只导出订阅列表,不含凭据。
 *     换机后用户需要重新输入一次 —— 这是有意的:口令不该跟着 JSON 到处走。
 *  2. **只发给源自己。** [headerForUrl] 按主机匹配(= 同主机或互为子域),不对"任意音频
 *     CDN"发送。音频与 feed 常常不同主机,那种情况下宁可不带 —— 把口令交给一个与用户
 *     无关的主机,是本仓库隐私口径里不能接受的一步(见 H253)。
 *  3. **日志只记主机。** [Logger.endpoint] 已经会把 URL 裁到 scheme://host,账号密码
 *     一个字都不进日志。
 *
 * 不加密:与应用里其余 JSON 账本一样落在 filesDir(系统给每个应用独立的私有目录),
 * 没有 Keystore 支持时"加密"只是把钥匙放在同一台设备上,不值得多一层自欺。
 */
class FeedAuthStore(context: Context) {

    private val file = File(context.filesDir, "feed_auth.json")
    private val lock = Any()

    private val _entries = MutableStateFlow<Map<String, FeedCredential>>(load())
    /** 供界面判断"这个源是不是已经存过凭据"(输入框预填用户名)。 */
    val entries: StateFlow<Map<String, FeedCredential>> = _entries

    fun get(feedUrl: String): FeedCredential? = _entries.value[feedUrl.trim()]

    /** 保存(覆盖)某个源的凭据。同步落盘:紧接着的重试就要用,不能等去抖。 */
    fun save(feedUrl: String, credential: FeedCredential) {
        val key = feedUrl.trim()
        if (key.isEmpty() || credential.username.isEmpty()) return
        synchronized(lock) {
            _entries.value = _entries.value + (key to credential)
            persistLocked()
        }
        Logger.i(TAG, "save feed=${Logger.endpoint(key)}")
    }

    fun forget(feedUrl: String) {
        val key = feedUrl.trim()
        synchronized(lock) {
            if (key !in _entries.value) return
            _entries.value = _entries.value - key
            persistLocked()
        }
        Logger.i(TAG, "forget feed=${Logger.endpoint(key)}")
    }

    /** 某个源自己的凭据头(feed 请求用)。 */
    fun headerFor(feedUrl: String): String? = get(feedUrl)?.header()

    /**
     * 音频 / 逐字稿:只有与某个已存源的**主机**相同(或互为子域)才给凭据。
     *
     * 同一主机上存了多份**不同**凭据时不给(不猜) —— 宁可让用户看到 401 再输一次,
     * 也不要把 A 站的口令发给 B 站。
     */
    fun headerForUrl(url: String): String? {
        val host = hostOf(url) ?: return null
        val matches = _entries.value.filterKeys { hostMatches(host, hostOf(it)) }.values.distinct()
        return if (matches.size == 1) matches.first().header() else null
    }

    private fun persistLocked() {
        val root = JSONObject()
        val items = JSONObject()
        _entries.value.forEach { (feed, c) ->
            items.put(feed, JSONObject().put("u", c.username).put("p", c.password))
        }
        root.put("v", 1).put("items", items)
        JsonWriter.writeAtomically(file, root.toString())
    }

    private fun load(): Map<String, FeedCredential> {
        if (!file.exists()) return emptyMap()
        return try {
            val items = JSONObject(file.readText()).optJSONObject("items") ?: return emptyMap()
            val out = HashMap<String, FeedCredential>()
            items.keys().forEach { feed ->
                val o = items.optJSONObject(feed) ?: return@forEach
                val user = o.optString("u")
                if (user.isEmpty()) return@forEach
                out[feed] = FeedCredential(user, o.optString("p"))
            }
            if (out.isNotEmpty()) Logger.i(TAG, "装载 ${out.size} 条源凭据")
            out
        } catch (e: Exception) {
            Logger.e(TAG, "读坏,按空账本启动", e)
            JsonWriter.markLoadFailed(file)
            emptyMap()
        }
    }

    companion object {
        private const val TAG = "FeedAuth"

        fun hostOf(url: String): String? = try {
            URI(url.trim()).host?.lowercase()
        } catch (e: Exception) {
            null
        }

        /** `a.example.com` 与 `example.com` 视为同源;`other.com` 不算。 */
        fun hostMatches(a: String?, b: String?): Boolean {
            if (a.isNullOrBlank() || b.isNullOrBlank()) return false
            return a == b || a.endsWith(".$b") || b.endsWith(".$a")
        }
    }
}
