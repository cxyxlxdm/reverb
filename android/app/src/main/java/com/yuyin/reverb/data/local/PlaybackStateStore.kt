package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.Logger
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 一份「正在播什么」的跨启动快照(`playback_state.json`)。
 *
 * 存三样东西,缺一样就会露出用户报的那种症状:
 *  - `current`:正在播(或上次在播)的那一集 —— 没有它,迷你播放条在冷启动后整条不出现,
 *    用户只能回历史里凭标题把那集再点一次;
 *  - `context` + `contextIndex`:**这一集来自哪一列** —— 没有它,重启后「上一集/下一集」
 *    与「播完自动接下一集」全部失效,而系列节目恰恰靠这两条连着听;
 *  - `upNext`:用户手动排的队列 —— 就是那条反馈的本体(此前只在内存里,进程结束即丢)。
 *
 * 为什么不进任何备份(H84 的白名单里刻意没有它):队列与「正在播哪一集」是**这台设备上的一次性排程**,
 * 换机/恢复后大概率已经过期;而里面每一集都能从历史或订阅里找回,没有任何东西会永久丢失。
 * (批注 `notes.json` 正相反 —— 那是用户写出来的字,所以它进白名单。)
 * 也不参与手动备份的 8 分区:那 8 项的顺序是三端 reverb-backup.json 的互通契约,不为临时态动它。
 */
class PlaybackStateStore(context: Context) {
    private val file = File(context.filesDir, FILE_NAME)
    private val lock = Any()

    /** 读回来的原样快照;字段含义见 [save]。 */
    data class Snapshot(
        val current: Episode? = null,
        val listTag: String = "",
        val context: List<Episode> = emptyList(),
        val contextIndex: Int = 0,
        val upNext: List<Episode> = emptyList()
    ) {
        val isEmpty: Boolean get() = current == null && upNext.isEmpty()
    }

    var snapshot: Snapshot = load()
        private set

    init {
        val s = snapshot
        Logger.i(
            TAG,
            "启动读回播放态 cur=${s.current?.id ?: "-"} ctx=${s.context.size}@${s.contextIndex} " +
                "upNext=${s.upNext.size} tag='${s.listTag}'"
        )
    }

    /**
     * 落一份当前播放态。**同步写**:与订阅/收藏/批注同口径 —— 都是用户单次动作触发的小数据,
     * 而去抖写(见 [JsonWriter])的代价正是「进程被杀时丢掉窗口内那一次」,
     * 而这条反馈报的就是"排好队、切出去再回来就没了"。用去抖写会把同一个症状留在原地。
     *
     * [context] 收**整条**列上下文,裁剪在这里做(硬规矩 10:不变式在数据出口保证):
     * 只保留以 [contextIndex] 为中心的 ±[CONTEXT_HALF] 集。理由是一份 RSS 常有上千集,
     * 每条快照约 1 KB,整列落盘就是每次动作同步写几 MB —— 那是 H65 那笔账的同一个形状。
     * 代价:重启后连续按「上一集/下一集」超出窗口会到边界(按钮置灰),
     * 用户重新点一下列表即拿回全量上下文。
     */
    fun save(current: Episode?, listTag: String, context: List<Episode>, contextIndex: Int, upNext: List<Episode>) {
        val cur = current?.takeIf { it.audioUrl.isNotBlank() }
        if (cur == null && upNext.isEmpty()) {
            clear()
            return
        }
        val full = context.filter { it.audioUrl.isNotBlank() }
        var idx = full.indexOfFirst { cur != null && it.id == cur.id }
        if (idx < 0) {
            idx = if (contextIndex in full.indices) contextIndex else 0
            // 上下文里找不到正在播的那一集(例如「下一个播放」摘出来单播,上下文只有它自己)
            // 时才走这里;此时以传入的下标为准,别硬把 0 当答案。
        }
        val from = (idx - CONTEXT_HALF).coerceAtLeast(0)
        val to = (idx + CONTEXT_HALF).coerceAtMost(full.lastIndex)
        val window = if (from > 0 || to < full.lastIndex) full.subList(from, to + 1).toList() else full
        val queued = if (upNext.size > UP_NEXT_CAP) upNext.subList(0, UP_NEXT_CAP).toList() else upNext
        val body = JSONObject()
            .put("version", VERSION)
            .put("listTag", listTag)
            .put("contextIndex", idx - from)
            .put("context", JSONArray().apply { window.forEach { put(EpisodeJson.toJson(it)) } })
            .put("upNext", JSONArray().apply { queued.forEach { put(EpisodeJson.toJson(it)) } })
        if (cur != null) body.put("current", EpisodeJson.toJson(cur))
        synchronized(lock) {
            snapshot = Snapshot(cur, listTag, window, idx - from, queued)
            runCatching { file.writeText(body.toString()) }
                .onFailure { Logger.e(TAG, "播放态写入失败", it) }
        }
        Logger.i(
            TAG,
            "落盘播放态 cur=${cur?.id ?: "-"} ctx=${window.size}@${idx - from}(全列 ${full.size}) " +
                "upNext=${queued.size} tag='$listTag'"
        )
    }

    /** 清空:退电台、播完、数据无效时都落到「没有可恢复的东西」这个状态,而不是留一份半成品。 */
    fun clear() {
        synchronized(lock) {
            snapshot = Snapshot()
            runCatching { if (file.exists()) file.delete() }
        }
    }

    private fun load(): Snapshot {
        val text = runCatching { if (file.exists()) file.readText() else "" }.getOrDefault("")
        if (text.isBlank()) return Snapshot()
        // 逐键宽容解析:备份/缓存是跨版本边界,任何一键坏掉都不该让整份读不出来
        // (H86 那个坑的同一形状 —— 只是这里失败的方向是"重启后没有播放栏")。
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return Snapshot()
        if (root.optInt("version", 1) > VERSION) {
            // 新格式被老版本读到:整份作废,别拿半懂不懂的字段去恢复播放态
            Logger.w(TAG, "播放态 version=${root.optInt("version")} > $VERSION,忽略")
            return Snapshot()
        }
        val cur = root.optJSONObject("current")?.let { EpisodeJson.fromJson(it) }?.takeIf { it.audioUrl.isNotBlank() }
        val upNext = readList(root.optJSONArray("upNext"))
        val context = readList(root.optJSONArray("context"))
        var idx = root.optInt("contextIndex", 0)
        // 位置以「current 在上下文里的那一格」为准自我纠正:窗口裁剪与版本升级都可能让存的
        // 下标对不上,而对不上的后果是上一集/下一集整条错位在另一列里跳。
        if (cur != null) {
            val found = context.indexOfFirst { it.id == cur.id }
            if (found >= 0) idx = found
        }
        if (context.isEmpty() && cur != null) idx = 0
        else if (idx !in context.indices) idx = 0
        return Snapshot(
            current = cur,
            listTag = root.optString("listTag"),
            context = context,
            contextIndex = idx,
            upNext = upNext
        )
    }

    private fun readList(arr: JSONArray?): List<Episode> {
        if (arr == null) return emptyList()
        val out = ArrayList<Episode>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val e = runCatching { EpisodeJson.fromJson(o) }.getOrNull()
            if (e != null && e.audioUrl.isNotBlank()) out.add(e)
        }
        return out
    }

    companion object {
        private const val TAG = "State"
        private const val FILE_NAME = "playback_state.json"

        /** 口径变了要让旧数据作废时改这里(硬规矩 11)。目前只有一版。 */
        private const val VERSION = 1

        /** 上下文窗口:当前集前后各留这么多集。 */
        private const val CONTEXT_HALF = 40

        /** up next 的条数上限:超出截断队尾(没人真会排 300 集,留这个数是防文件无限长)。 */
        private const val UP_NEXT_CAP = 300
    }
}
