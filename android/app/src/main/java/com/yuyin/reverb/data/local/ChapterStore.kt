package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Chapter
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.remote.ChaptersFetcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 章节表的状态机与缓存。与 `TranscriptStore` 同一种形状:切集即重置、命中缓存秒显、失败可重试。
 *
 * 缓存放 `filesDir/chapters/`,**不进备份**:章表能从 RSS 再取一遍,与逐字稿/音频缓存同待遇。
 *
 * 为什么值得落盘:章节的价值恰恰在"已经下载好、正在离线听"的时候最大 ——
 * 每次点开都现取一次,飞行模式下就永远只有"加载失败"。
 *
 * 与逐字稿不同的是**没有代次机制**:章表只有"一次请求 → 一份列表",没有流式输出,
 * 也没有跨集的半截状态;换集时把旧结果清空即可。但请求仍可能晚回来,
 * 所以回来时再核一次 `episodeId`(见 [load] 里那条判断),不能无条件写进当前状态。
 */
class ChapterStore(context: Context, private val fetcher: ChaptersFetcher) {

    sealed interface State {
        data object Idle : State
        data object Loading : State
        data class Done(val chapters: List<Chapter>) : State
        /** 章表取到了、但里面没有可用章节 —— 与"取失败"分开,界面不摆重试 */
        data object Empty : State
        data object Failed : State
    }

    private val dir = File(context.filesDir, "chapters").apply { mkdirs() }
    private val scope = CoroutineScope(SupervisorJob())
    private val TAG = "Chapters"

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state

    private var episodeId = ""
    private var job: Job? = null

    /**
     * 切到某一集。有缓存直接进 [State.Done],否则停在 [State.Idle] ——
     * **不自动请求**:章节弹层要用户点开才有意义,冷启动时没有人看得见那份列表。
     */
    fun prepare(episode: Episode) {
        if (episode.id == episodeId) return
        job?.cancel()
        job = null
        episodeId = episode.id
        _state.value = State.Idle
    }

    /** 用户点开章节弹层时调用。已成功或正在跑就不重复请求;失败过的允许再点一次。 */
    fun load(episode: Episode) {
        if (episode.chaptersUrl.isBlank()) {
            _state.value = State.Empty
            return
        }
        if (episode.id != episodeId) prepare(episode)
        val cached = loadCache(episode)
        if (cached != null) {
            _state.value = if (cached.isEmpty()) State.Empty else State.Done(cached)
            return
        }
        if (_state.value is State.Loading) return
        if (_state.value is State.Done) return

        job?.cancel()
        _state.value = State.Loading
        val id = episode.id
        job = scope.launch {
            val list = fetcher.fetch(episode.chaptersUrl)
            // 请求期间用户可能已经切到别的集(自动续播),这一份不能写进当前状态
            if (id != episodeId) return@launch
            when {
                list == null -> _state.value = State.Failed
                list.isEmpty() -> {
                    saveCache(episode, list)
                    _state.value = State.Empty
                }
                else -> {
                    saveCache(episode, list)
                    _state.value = State.Done(list)
                }
            }
        }
    }

    // ── 缓存 ──

    private fun cacheFile(episodeId: String) =
        File(dir, "${com.yuyin.reverb.util.ShortHash.hex16(episodeId)}.json")

    /**
     * 只认**同一条章节地址**的缓存。
     *
     * 判据必须带 URL:发布方换了章表地址(或同一集被重新发布),旧文件里的章节仍然"看得懂"、
     * 时间也对得上,但它已经不是这一版节目了 —— 这种过期比读不出来更难发现。
     */
    private fun loadCache(episode: Episode): List<Chapter>? {
        val f = cacheFile(episode.id)
        if (!f.exists()) return null
        return try {
            val root = JSONObject(f.readText())
            if (root.optInt("version") != CACHE_VERSION) return null
            if (root.optString("url") != episode.chaptersUrl) return null
            val arr = root.optJSONArray("chapters") ?: return null
            val out = ArrayList<Chapter>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(
                    Chapter(
                        startMs = o.optInt("startMs"),
                        title = o.optString("title"),
                        imageUrl = o.optString("imageUrl"),
                        url = o.optString("url")
                    )
                )
            }
            out
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "缓存读不了,丢弃 id=${com.yuyin.reverb.util.ShortHash.hex16(episode.id)}")
            runCatching { f.delete() }
            null
        }
    }

    private fun saveCache(episode: Episode, chapters: List<Chapter>) {
        try {
            val arr = JSONArray()
            for (c in chapters) {
                arr.put(
                    JSONObject()
                        .put("startMs", c.startMs)
                        .put("title", c.title)
                        .put("imageUrl", c.imageUrl)
                        .put("url", c.url)
                )
            }
            val root = JSONObject()
                .put("version", CACHE_VERSION)
                .put("url", episode.chaptersUrl)
                .put("chapters", arr)
            cacheFile(episode.id).writeText(root.toString())
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "缓存写不进去 id=${com.yuyin.reverb.util.ShortHash.hex16(episode.id)}")
        }
    }

    private companion object {
        /**
         * 章表缓存的口径版本。字段形状一变就加一 —— 旧文件读出来是"能解析但缺字段"的章,
         * 那种错不会崩,只会显示一片空白(与 `TranscriptStore.CACHE_VERSION` 同一条教训,硬规矩 11)。
         */
        const val CACHE_VERSION = 1
    }
}
