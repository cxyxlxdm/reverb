package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * 一条批注:**某一集的某一秒 + 自己写的一句话**。
 *
 * 为什么不存 `episodeId` 去引用(像 stamps.json 那样),而要存整条 Episode 快照:
 * 引用式存储的前提是「被引用的对象还在原处可查」。这里不成立 ——
 * 发布方随时会从 RSS 里删掉旧集(常见做法,控制 feed 体积),而本项目**零后端、无云同步**,
 * 一旦那一集不在任何订阅的 feed 里,批注就成一个指不到地方的时间戳:列表还能读出这句话,
 * 但点回去什么都播不了,且用户没有任何自救入口(硬规矩 11 说的那个「修了等于没修」的同构情形)。
 * 收藏与历史早就面对同一个问题,两者的答案都是存整条 [Episode](`EpisodeJson.toJson`),
 * 批注照这个口径走 —— 空间代价约每条 1 KB,换「三年后点开仍能跳回那一秒」。
 */
data class EpisodeNote(
    val id: String,
    val episode: Episode,
    /** 那一秒,毫秒。字段名带单位是刻意的:H86 那次的根因是 macOS 写秒、Android 写毫秒,
     *  而备份里没有单位信息可辨;新格式不再留这个口子,三端一律毫秒。 */
    val positionMs: Long,
    val text: String,
    val createdAt: Long
)

/**
 * 听觉批注:一集可以有很多条,新写的置顶,JSON 持久化(`notes.json`,纯数组,与 stamps.json 同构)。
 */
class NoteStore(context: Context) {
    private val file = File(context.filesDir, "notes.json")
    private val lock = Any()

    private val _notes = MutableStateFlow(load())
    val notes: StateFlow<List<EpisodeNote>> = _notes

    /**
     * 落一条批注。返回 null 表示文字为空而放弃(空批注没有意义,且会让列表出现无法分辨的空行)。
     *
     * `positionMs` 在**这里**夹到 `[0, 该集时长]`:界面上的时间戳要能代表「那一秒真的在那一集里」,
     * 而取值来自播放器的 currentPosition —— 拖动进度条与 prepare 之间有个窗口,那一刻它可能是
     * 上一集的时长或一个超出本集的值(硬规矩 10:不变式在数据出口一次性保证,不在渲染侧兜底)。
     */
    fun add(episode: Episode, positionMs: Long, text: String, now: Long): EpisodeNote? {
        val body = text.trim()
        if (body.isEmpty()) return null
        val cap = if (episode.durationSec > 0) episode.durationSec * 1000L else Long.MAX_VALUE
        val note = EpisodeNote(
            id = UUID.randomUUID().toString(),
            episode = episode,
            positionMs = positionMs.coerceIn(0L, cap),
            text = body,
            createdAt = now
        )
        synchronized(lock) {
            val list = _notes.value.toMutableList()
            list.add(0, note)
            _notes.value = list
            persist(list)
            Logger.i("NoteStore", "add id=${note.id} pos=${note.positionMs}ms len=${body.length} total=${list.size}")
        }
        return note
    }

    fun remove(id: String) {
        synchronized(lock) {
            val list = _notes.value.filterNot { it.id == id }
            _notes.value = list
            persist(list)
            Logger.i("NoteStore", "remove id=$id total=${list.size}")
        }
    }

    /**
     * 备份恢复:按 id 去重(重复恢复同一份备份不会写出两份),再走同一条 `normalize`
     * —— 与 `load()` 一个口径,这样「从备份恢复出来的列表」和「下次冷启动从盘上读到的列表」是同一份内容。
     */
    fun addAll(items: List<EpisodeNote>) {
        synchronized(lock) {
            val list = _notes.value.toMutableList()
            for (n in items) if (list.none { it.id == n.id }) list.add(n)
            _notes.value = normalize(list)
            persist(_notes.value)
        }
    }

    /**
     * 从盘上或备份里读来的批注过一次**归一**:按落笔时刻倒序,并把 `positionMs` 的负值归 0。
     *
     * 为什么补在「读盘 + 恢复」这一道:时间线和「点一句跳到那一秒」直接吃这个列表,而
     * `notes.json` 是**三端共用**的文件 —— 本端的写入点管不住它的前任(另一端写的顺序、
     * 手工编辑过的内容、Android 系统级备份还原那种**整份文件覆盖回来**的路径,压根不经过 `addAll`)。
     * 硬规矩 10 说的「不变式在数据出口一次性保证」,对读盘而言那个出口就是这份文件的**入口**。
     * 排序与另两端同口径:`sortedByDescending` / `Array.sort` / Swift `sort` 都是稳定排序,
     * 同一毫秒写下的两条保持原有先后。
     *
     * **刻意不套用 `add` 那条「上限夹到该集时长」**:`add` 里那个夹成立,是因为按下「写批注」的
     * 那一刻手上有播放器实时位置作真值参照;而读盘时唯一可比的是 **RSS 元数据时长** ——
     * 它是发布方自报的近似值,常常比真实音频短。拿一个近似上限去改写用户早就写下的那一秒,
     * 比留着那个越界值更糟(界面上的时间戳自己跳了位,而用户无从知道是谁改的)。
     * 越界值走到播放那一步,由播放器按真实时长夹,不落在数据里做二次改写。
     */
    private fun normalize(list: List<EpisodeNote>): List<EpisodeNote> =
        list.map { if (it.positionMs < 0L) it.copy(positionMs = 0L) else it }
            .sortedByDescending { it.createdAt }

    private fun load(): List<EpisodeNote> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            val out = ArrayList<EpisodeNote>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val epObj = o.optJSONObject("episode") ?: continue
                // 逐条 runCatching:一条坏批注只丢那一条。**批注是用户写出来的字**,
                // 整份归零后再被任何一次 persist 落回盘上就永久没了(REVIEW-2026-10-25 高-3)
                val note = runCatching {
                    val ep = EpisodeJson.fromJson(epObj)
                    // 缺 episode 体或没有可播的音频地址就跳过,而不是造一条「点不动」的批注 ——
                    // 列表里躺一条永远播不了的记录,比少一条更让人怀疑是 bug。
                    if (ep.audioUrl.isBlank()) null
                    else EpisodeNote(
                        id = o.optString("noteId"),
                        episode = ep,
                        positionMs = o.optLong("positionMs"),
                        text = o.optString("text"),
                        createdAt = o.optLong("createdAt")
                    )
                }.getOrNull()
                if (note != null) out.add(note)
                else Logger.w("NoteStore", "notes.json 第 $i 条读坏了,跳过")
            }
            normalize(out)
        } catch (e: Exception) {
            // 读坏 ≠ 没有批注:标记 + 留证,空态整份写回由 JsonWriter 的空态闸挡下
            JsonWriter.markLoadFailed(file)
            Logger.e("NoteStore", "notes.json 读取失败,按空处理", e)
            emptyList()
        }
    }

    /**
     * 单条 = `{noteId, positionMs, text, createdAt, episode:{…}}`,episode 用 [EpisodeJson] 整条嵌进去
     * (与 history.json 同构)。
     *
     * ⚠️ 批注自己的 id **必须叫 `noteId`**:episode 体里已经有一个 `id`(= `Episode.id`,guid),
     * 若把两者摊平在同一个对象里,后写的键会静默盖掉前一个 —— 表现是"跳回那一秒"点了没反应
     * (下载状态、历史进度全按 `Episode.id` 查,而它变成了 UUID),且读回来看不出来。
     */
    private fun persist(list: List<EpisodeNote>) {
        try {
            val arr = JSONArray()
            for (n in list) {
                arr.put(
                    JSONObject()
                        .put("noteId", n.id)
                        .put("positionMs", n.positionMs)
                        .put("text", n.text)
                        .put("createdAt", n.createdAt)
                        .put("episode", EpisodeJson.toJson(n.episode))
                )
            }
            // 原子写:.part → rename,见 JsonWriter.writeAtomically(REVIEW-2026-10-25 高-3 A 步)
            JsonWriter.writeAtomically(file, arr.toString())
        } catch (e: Exception) {
            Logger.e("NoteStore", "notes.json 写入失败", e)
        }
    }
}
