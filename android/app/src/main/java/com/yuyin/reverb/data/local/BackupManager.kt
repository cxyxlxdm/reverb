package com.yuyin.reverb.data.local

import com.yuyin.reverb.AppContainer
import com.yuyin.reverb.playback.DownloadManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * 备份/恢复：把订阅、下载(仅节目链接，不含音频文件)、历史、设置导出为一个 JSON，
 * 或从 JSON 选择性导入。每一项都可单独选择是否备份/恢复。
 */
object BackupManager {
    enum class Section { SUBSCRIPTIONS, FAVORITES, STAMPS, NOTES, DOWNLOADS, HISTORY, LISTEN_STATS, SETTINGS }

    private const val TAG = "Backup"

    fun build(container: AppContainer, include: Set<Section>): String {
        com.yuyin.reverb.util.Logger.i(TAG, "export sections=${include.joinToString(",")}")
        val root = JSONObject().put("version", 1)

        if (Section.SUBSCRIPTIONS in include) {
            val arr = JSONArray()
            container.subscriptionStore.subscriptions.value.forEach { arr.put(PodcastJson.toJson(it)) }
            root.put("subscriptions", arr)
        }
        if (Section.FAVORITES in include) {
            val arr = JSONArray()
            container.favoriteStore.favorites.value.forEach { arr.put(EpisodeJson.toJson(it)) }
            root.put("favorites", arr)
        }
        if (Section.STAMPS in include) {
            val arr = JSONArray()
            container.stampStore.stamps.value.forEach { s ->
                arr.put(
                    JSONObject()
                        .put("episodeId", s.episodeId).put("seal", s.seal)
                        .put("title", s.title).put("podcastTitle", s.podcastTitle).put("createdAt", s.createdAt)
                )
            }
            root.put("stamps", arr)
        }
        if (Section.NOTES in include) {
            // 批注是**用户写出来的字**,丢了没有任何东西能补回来,所以必须进默认导出。
            // episode 整条嵌进去(与 history 同构),否则换机后那些被发布方删掉的旧集无法定位。
            val arr = JSONArray()
            container.noteStore.notes.value.forEach { n ->
                arr.put(
                    JSONObject()
                        .put("noteId", n.id)
                        .put("positionMs", n.positionMs)
                        .put("text", n.text)
                        .put("createdAt", n.createdAt)
                        .put("episode", EpisodeJson.toJson(n.episode))
                )
            }
            root.put("notes", arr)
        }
        if (Section.DOWNLOADS in include) {
            // 只备份节目元数据/链接，不含音频文件
            val arr = JSONArray()
            container.downloadStore.downloads.value.forEach { arr.put(EpisodeJson.toJson(it.episode)) }
            root.put("downloads", arr)
        }
        if (Section.HISTORY in include) {
            val arr = JSONArray()
            container.historyStore.history.value.forEach { h ->
                arr.put(
                    JSONObject()
                        .put("episode", EpisodeJson.toJson(h.episode))
                        .put("positionMs", h.positionMs)
                        .put("durationMs", h.durationMs)
                        .put("updatedAt", h.updatedAt)
                        .put("played", h.played)
                )
            }
            root.put("history", arr)
        }
        if (Section.LISTEN_STATS in include) {
            // 按设备分账导出;恢复时按设备取 max,故重复恢复不会重复统计
            val arr = JSONArray()
            container.listenStatsStore.snapshot().forEach { arr.put(ChannelListenJson.toJson(it)) }
            root.put("listenStats", arr)
        }
        if (Section.SETTINGS in include) {
            val s = container.settingsStore
            /**
             * settings 分区的键集与鸿蒙 `BackupManager.ets` 的 SETTINGS 段**逐键对齐**。
             *
             * 契约是**这一组键名与类型**,不是各端本地的存储格式:Android 本地把字号存成
             * Float 倍率(`font_scale`)、鸿蒙存成档位下标(`font_index`),那是各自实现。
             * 所以这里同时写两种:
             *  - `fontScale` —— 跨端契约键,也是本端一直在用的那个;
             *  - `fontIndex` —— 给**已发布的旧鸿蒙**(1.0.3 及更早)读的,它只认下标。
             *    少了这一行,新 Android 导出的备份装到旧鸿蒙上会静默丢掉字号。
             *
             * `language` / `subsGrid` / `contextualRadio` 是这次补的:三项本端早就有,
             * 只是从没写进备份,于是从 Android 换到鸿蒙时**语言、订阅排列、电台模式**
             * 全部回到默认 —— 而同一份文件里比它们冷门的键都带过去了。
             */
            val obj = JSONObject()
                .put("themeMode", s.themeMode.value)
                .put("fontScale", s.fontScale.value.toDouble())
                .put("fontIndex", SettingsStore.fontIndexFor(s.fontScale.value))
                .put("accentIndex", s.accentIndex.value)
                .put("allowCellularDownload", s.allowCellularDownload.value)
                .put("updatesEnabled", s.updatesEnabled.value)
                .put("defaultSpeed", s.defaultSpeed.value.toDouble())
                .put("skipBackSec", s.skipBackSec.value)
                .put("skipForwardSec", s.skipForwardSec.value)
                .put("language", s.language.value)
                .put("subsGrid", s.subsGrid.value)
                .put("contextualRadio", s.contextualRadio.value)
                .put("regionOverride", container.regionStore.override.value ?: JSONObject.NULL)
                .put("categoryOrder", JSONArray(container.categoryStore.loadOrder()))
            root.put("settings", obj)
        }
        com.yuyin.reverb.util.Logger.i(
            TAG,
            "export built subs=${root.optJSONArray("subscriptions")?.length() ?: 0} " +
                "favs=${root.optJSONArray("favorites")?.length() ?: 0} " +
                "stamps=${root.optJSONArray("stamps")?.length() ?: 0} " +
                "notes=${root.optJSONArray("notes")?.length() ?: 0} " +
                "downloads=${root.optJSONArray("downloads")?.length() ?: 0} " +
                "history=${root.optJSONArray("history")?.length() ?: 0}"
        )
        return root.toString(2)
    }

    fun sectionsIn(json: String): Set<Section> = try {
        val root = JSONObject(json)
        buildSet {
            if (root.has("subscriptions")) add(Section.SUBSCRIPTIONS)
            if (root.has("favorites")) add(Section.FAVORITES)
            if (root.has("stamps")) add(Section.STAMPS)
            if (root.has("notes")) add(Section.NOTES)
            if (root.has("downloads")) add(Section.DOWNLOADS)
            if (root.has("history")) add(Section.HISTORY)
            if (root.has("listenStats")) add(Section.LISTEN_STATS)
            if (root.has("settings")) add(Section.SETTINGS)
        }
    } catch (e: Exception) {
        emptySet()
    }

    /** 应用导入。返回 true 表示导入了「设置」(调用方可据此重排更新任务)。 */
    fun apply(container: AppContainer, json: String, include: Set<Section>): Boolean {
        com.yuyin.reverb.util.Logger.i(TAG, "restore sections=${include.joinToString(",")}")
        val root = JSONObject(json)

        if (Section.SUBSCRIPTIONS in include) root.optJSONArray("subscriptions")?.let { arr ->
            val list = (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.let(PodcastJson::fromJson) }
            if (list.isNotEmpty()) container.subscriptionStore.addAll(list)
        }
        if (Section.FAVORITES in include) root.optJSONArray("favorites")?.let { arr ->
            // 备份即「新在前」顺序;addAll 尾部追加,按原序并入即可保持该顺序
            val list = (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.let(EpisodeJson::fromJson) }
            if (list.isNotEmpty()) container.favoriteStore.addAll(list)
        }
        if (Section.STAMPS in include) root.optJSONArray("stamps")?.let { arr ->
            val list = (0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.let {
                    Stamp(it.optString("episodeId"), it.optString("seal"), it.optString("title"), it.optString("podcastTitle"), it.optLong("createdAt"))
                }
            }
            if (list.isNotEmpty()) container.stampStore.addAll(list)
        }
        if (Section.NOTES in include) root.optJSONArray("notes")?.let { arr ->
            val list = (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                val epObj = o.optJSONObject("episode") ?: return@mapNotNull null
                val ep = EpisodeJson.fromJson(epObj)
                if (ep.audioUrl.isBlank() || o.optString("text").isBlank()) return@mapNotNull null
                // **只有 `createdAt` 这个 epoch 字段**要做秒/毫秒归一(H86:macOS 侧写的是秒)。
                // `positionMs` 绝不能套同一条阈值 —— 那是给「Unix 时间戳」设计的,
                // 播放位置恒落在 1..1e11 之间,套上去会把 66 分钟(4.0e6 ms)误判成秒、乘一千变成
                // 40 亿毫秒,跳过去直接超出时长而落回开头,且列表显示的时间戳看着还是"合理"的。
                val raw = o.optLong("createdAt")
                val createdAt = if (raw in 1 until 100_000_000_000) raw * 1000 else raw
                EpisodeNote(
                    // 缺 `noteId` 时用**确定值**兜底,不用随机 UUID:恢复按 id 去重,
                    // 随机 id 等于让同一份备份恢复两次就把批注**翻倍**(破坏幂等)。
                    // 格式照鸿蒙 `${createdAt}-${i}` —— 确定值本身是免费的,没理由不这么做。
                    id = o.optString("noteId").ifBlank { "$createdAt-$i" },
                    episode = ep,
                    positionMs = o.optLong("positionMs").coerceAtLeast(0L),
                    text = o.optString("text"),
                    createdAt = createdAt
                )
            }
            if (list.isNotEmpty()) container.noteStore.addAll(list)
        }
        if (Section.DOWNLOADS in include) root.optJSONArray("downloads")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val ep = EpisodeJson.fromJson(o)
                if (ep.audioUrl.isNotBlank()) DownloadManager.download(ep) // 按链接重新下载
            }
        }
        if (Section.HISTORY in include) root.optJSONArray("history")?.let { arr ->
            // 合并策略:同一集在两边都存在时,按 updatedAt 取更新的那条,避免用旧备份把当前进度倒退。
            // 快照恢复前的状态用于比较(边并入边比较会失真)。
            val existing = container.historyStore.history.value.associateBy { it.episode.id }
            // 倒序导入，使原本较新的记录最终位于前列
            for (i in arr.length() - 1 downTo 0) {
                val o = arr.optJSONObject(i) ?: continue
                val epObj = o.optJSONObject("episode") ?: continue
                val ep = EpisodeJson.fromJson(epObj)
                // 时间戳口径归一(H86):本端是毫秒,macOS 备份是秒 —— 1e11 以下按秒×1000
                // (现时秒级时间戳 ~1.8e9,毫秒级 ~1.8e12,阈值两侧都有足够余量)
                val raw = o.optLong("updatedAt")
                val updatedAt = if (raw in 1 until 100_000_000_000) raw * 1000 else raw
                val cur = existing[ep.id]
                if (cur != null && cur.updatedAt >= updatedAt) continue // 当前记录更新,保留不覆盖
                container.historyStore.record(ep, updatedAt)
                container.historyStore.updatePosition(ep.id, o.optLong("positionMs"), o.optLong("durationMs"))
                // record() 会把 played 重置为 false,备份里带 true 的要补回
                if (o.optBoolean("played", false)) container.historyStore.markPlayed(ep.id, true)
            }
        }
        if (Section.LISTEN_STATS in include) root.optJSONArray("listenStats")?.let { arr ->
            // 按设备取 max 合并(幂等):重复恢复同一份备份不会重复累加,跨设备则自然汇总
            val list = ArrayList<com.yuyin.reverb.data.model.ChannelListen>(arr.length())
            val legacy = HashMap<String, Long>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val (c, legacyMs) = ChannelListenJson.parse(o)
                list.add(c)
                if (legacyMs > 0) legacy[c.key] = legacyMs
            }
            if (list.isNotEmpty()) container.listenStatsStore.merge(list, legacy)
        }
        var importedSettings = false
        // 整段再包一层 runCatching(setter 本身也可能抛),不能让「设置」这一个分区
        // 把其余 7 个分区一起带走。见 REVIEW-2026-10-25 中-2。
        runCatching {
            if (Section.SETTINGS in include) root.optJSONObject("settings")?.let { s ->
                val st = container.settingsStore
                /**
                 * 逐键「有则取、类型不对则**跳过**」。
                 *
                 * 原先每个键都是 `s.getInt(...)` / `getBoolean(...)` 这类**会抛**的取法(org.json
                 * 在类型不符时抛 JSONException),而整段外面没有 try —— 于是一份手改过、或来自
                 * 另一端的备份里只要有一个键的类型不对:
                 *  1. `apply()` 直接抛出,后面的 `regionOverride`/`categoryOrder` 连同
                 *     **后面根本没跑到的分区**全丢;
                 *  2. 更糟的是调用方 `SettingsScreen` 之后照样把 `restore_done` 弹出来,
                 *     用户看到的是"恢复成功"。
                 *
                 * 三种状态必须分开(这是这条整改意见点名的坑):
                 *  - **键不存在** → 不动本端(这份备份压根没谈这一项);
                 *  - **键存在但类型不对** → 不动本端 + 记一行日志。
                 *    图省事的 `optInt(key, 本端当前值)` 会把这两种情况折成同一个"值没变",
                 *    看着无害,实际是把备份里那个坏值**静默**当成"用户就是要这个";
                 *    而如果默认值写的是硬编码常量(0 / false),类型不对就等于**把用户现有设置盖掉**,
                 *    那才是真的丢数据。
                 *  - **键存在且类型对** → 照它写。
                 *
                 * 判"类型对不对"用的是同一键取两次不同兜底:两次结果一致才说明值本身读得出来,
                 * 不一致说明其中一次落到了兜底上(org.json 的 opt* 只在无法转换时才返回兜底)。
                 *
                 * ⚠️ 这里**只改读法,不改任何键名/类型/结构** —— settings 分区的键集是三端
                 *    `reverb-backup.json` 的互通契约(见上面导出段)。
                 */
                fun typeBad(key: String, want: String) =
                    com.yuyin.reverb.util.Logger.w(TAG, "settings.$key 类型不是$want,跳过这一项(保留本端现值)")

                fun intOf(key: String): Int? {
                    if (!s.has(key) || s.isNull(key)) return null
                    val a = s.optInt(key, Int.MIN_VALUE)
                    if (a == s.optInt(key, Int.MAX_VALUE)) return a
                    typeBad(key, "整数"); return null
                }

                fun doubleOf(key: String): Double? {
                    if (!s.has(key) || s.isNull(key)) return null
                    val a = s.optDouble(key, Double.NaN)
                    if (!a.isNaN() && a == s.optDouble(key, Double.POSITIVE_INFINITY)) return a
                    typeBad(key, "小数"); return null
                }

                fun boolOf(key: String): Boolean? {
                    if (!s.has(key) || s.isNull(key)) return null
                    val a = s.optBoolean(key, false)
                    if (a == s.optBoolean(key, true)) return a
                    typeBad(key, "布尔"); return null
                }

                fun strOf(key: String): String? {
                    if (!s.has(key) || s.isNull(key)) return null
                    // 字符串必须**看原始类型**:optString 会把 false 转成 "false" 这种看着合法的串,
                    // 塞进 language 就是把一个不可能的值当真了。
                    return (s.opt(key) as? String).also { if (it == null) typeBad(key, "字符串") }
                }

                intOf("themeMode")?.let { st.setThemeMode(it) }
                /**
                 * 字号:**优先读 `fontScale`(倍率,跨端契约键),读不到才退 `fontIndex`(下标)**。
                 *
                 * 先后不能反:新版两端导出的备份两个键都写(见上面导出段),而它们由同一个值派生,
                 * 正常情况下取哪个都一样。之所以仍要以倍率优先 —— 一份**手改过**或**来自只改了下标
                 * 那一侧**的备份里两者可能不一致,这时必须有一个确定性的胜出者,否则同一份文件
                 * 在两台机器上恢复出两档字号,而两端都显示"我从自己的库里读出来的",查不到。
                 *
                 * 「fontScale 存在但类型坏了」时**不再退到 fontIndex**:那等于用另一把尺子去补一个
                 * 坏掉的读数,读出来的字号和用户那份文件里的意图毫无关系(中-2 说的就是这种混淆)。
                 */
                val hasFontScale = s.has("fontScale") && !s.isNull("fontScale")
                if (hasFontScale) doubleOf("fontScale")?.let { st.setFontScale(it.toFloat()) }
                else intOf("fontIndex")?.let { st.setFontScale(SettingsStore.scaleForFontIndex(it)) }
                intOf("accentIndex")?.let { st.setAccentIndex(it) }
                boolOf("allowCellularDownload")?.let { st.setAllowCellularDownload(it) }
                boolOf("updatesEnabled")?.let { st.setUpdatesEnabled(it) }
                doubleOf("defaultSpeed")?.let { st.setDefaultSpeed(it.toFloat()) }
                intOf("skipBackSec")?.let { st.setSkipBackSec(it) }
                intOf("skipForwardSec")?.let { st.setSkipForwardSec(it) }
                // 这三项是这次补的消费端。语言标签两端用的是同一套("" = 跟随系统),
                // 所以对空串要照实写回去 —— 它的意思就是"跟随系统",不是"没值"。
                strOf("language")?.let { st.setLanguage(it) }
                boolOf("subsGrid")?.let { st.setSubsGrid(it) }
                boolOf("contextualRadio")?.let { st.setContextualRadio(it) }
                // 地区覆盖:**键不存在就不动本端**(原先无条件走 `setOverride(null)`,
                // 于是"来自没写这一项的旧备份"会把用户选好的地区清成跟随系统 —— 中-2 点名的
                // 「把键不存在当成有值」的同一个形状)。显式 `null`(导出段写 `JSONObject.NULL`)
                // 与空串都按"跟随系统"清掉,那是备份里明确表达出来的意图。
                if (s.has("regionOverride")) {
                    when (val v = s.opt("regionOverride")) {
                        // 导出端在"跟随系统"时写的是显式 null(见上面导出段),那是备份明确表达的意图,照办
                        null, JSONObject.NULL -> container.regionStore.setOverride(null)
                        is String -> container.regionStore.setOverride(v.ifBlank { null })
                        else -> typeBad("regionOverride", "字符串")
                    }
                }
                s.optJSONArray("categoryOrder")?.let { ca ->
                    val order = (0 until ca.length()).map { ca.optString(it) }.filter { it.isNotBlank() }
                    if (order.isNotEmpty()) container.categoryStore.saveOrder(order)
                }
                importedSettings = true
            }
        }.onFailure { com.yuyin.reverb.util.Logger.e(TAG, "settings 分区恢复中断,其余分区不受影响", it) }
        com.yuyin.reverb.util.Logger.i(TAG, "restore done importedSettings=$importedSettings")
        return importedSettings
    }
}
