package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.data.model.TranscribedWord
import com.yuyin.reverb.data.remote.TranscriptFetcher
import com.yuyin.reverb.playback.asr.AsrEngine
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
 * 「转写」的状态机与缓存。对应 macOS `Data/TranscriptStore.swift`,状态与缓存格式一一对齐。
 *
 * 两条取稿路径,**先官方稿、后本机识别**:
 * 1. 发布方自己给的逐字稿(RSS `podcast:transcript`)—— 准、快、不耗电,所有分发都有;
 * 2. 本机离线识别 —— 引擎在 `playback/asr/AsrFactory` 里(合并前只有自分发那个 flavor 带,
 *    商店那份工厂返回 null、状态直接落在 `NoEngine`;现在只有一份包,见 H205)。
 *
 * 缓存:每单集 × 每语言一份 JSON,放 `filesDir/transcripts/`。命中即秒显,不重转。
 * **格式与 macOS 完全一致**(`{localeId, complete, segments:[{text,startMs,endMs,words?}]}`),
 * 鸿蒙那端可以直接复用。
 *
 * 不进备份(`BackupManager.Section` 没有它):可重生成、体积大,与 macOS 一致。
 */
class TranscriptStore(context: Context, private val fetcher: TranscriptFetcher) {

    /**
     * 界面要显示的状态。比 macOS 多一个 `NoEngine` —— 那端不存在"这个版本没有识别能力"
     * 这种情况(系统框架总在),而 Android 要有这个状态可如实告诉用户
     * (合并前商店那份恒落这里;现在只在 `HAS_ENGINE` 被降级、或 `.so` 加载失败时出现)。
     */
    sealed interface State {
        /** 没有稿,可以开始转写(带引擎的那份包)*/
        data object Idle : State
        /** 正在取发布方的官方稿 */
        data object FetchingOfficial : State
        /** 流式单集:先把音频下载到临时文件 */
        data object DownloadingAudio : State
        /** 首次加载识别模型 */
        data object LoadingModel : State
        data object Running : State
        data object Done : State
        data class Failed(val message: String) : State
        /** 这份包不含可用的离线识别引擎,且这一集没有官方稿 */
        data object NoEngine : State
        /**
         * 识别前要下的那整集音频被**蜂窝/计费链路闸门**拦下了(见 REVIEW-2026-10-25 中-3)。
         *
         * 为什么不是一个 `Failed("…")`:失败态给用户的只有"再点一次",而再点一次会被同样拦下,
         * 表现就是"这个功能坏了"。这一态说的是**改哪个设置就能用**,不是"出了错"。
         *
         * 界面用的串是既有的 `set_wifi_only_sub`(「关闭后蜂窝网络也允许下载与缓存」,五语都已翻),
         * **没有新增文案** —— 本轮的约束是不往 5 个 strings.xml 里塞没翻译的新串。
         * 想要一句更贴这场景的话,得五语一起补,那是要人拍板的事。
         */
        data object NeedUnmetered : State
    }

    private val dir = File(context.filesDir, "transcripts").apply { mkdirs() }
    private val scope = CoroutineScope(SupervisorJob())
    private val TAG = "Transcript"

    private val _segments = MutableStateFlow<List<TranscribedSegment>>(emptyList())
    val segments: StateFlow<List<TranscribedSegment>> = _segments

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state

    /// 生成期未定稿的实时尾巴(打字机效果)。缓存命中时为空。
    private val _volatileTail = MutableStateFlow("")
    val volatileTail: StateFlow<String> = _volatileTail

    private var episodeId: String = ""
    private var localeId: String = ""

    /**
     * 代次。切集/切语言/重新开始都自增,旧任务发现代次变了就悄悄退出 ——
     * 光靠 `job.cancel()` 不够:协程取消是协作式的,回调可能已经在路上,
     * 不带代次判断就会把上一集的句子写进这一集(macOS 侧同样的 `generation` 机制)。
     */
    private var generation = 0
    private var job: Job? = null

    // ── 对外 ──

    /**
     * 切到某单集/语言时调用。命中缓存直接显示;否则置初始态**等用户手动开始** ——
     * 不自动转写:那是几分钟的满载计算,得由用户点了才做。
     */
    fun prepare(episode: Episode, uiLanguage: String, hasEngine: Boolean) {
        val loc = localeFor(uiLanguage)
        if (episode.id == episodeId && loc == localeId && _state.value != State.Idle) return
        cancel()
        generation += 1
        episodeId = episode.id
        localeId = loc
        _volatileTail.value = ""

        val cached = loadCache(episode.id, loc)
        if (cached != null && cached.isNotEmpty()) {
            _segments.value = cached
            _state.value = State.Done
            return
        }
        _segments.value = emptyList()
        _state.value = when {
            episode.transcriptUrl.isNotBlank() -> State.Idle   // 有官方稿,点一下就能取
            hasEngine -> State.Idle
            else -> State.NoEngine
        }
    }

    /**
     * 开始取稿/转写。`localPath` 非空表示这一集已下载(纯离线),否则识别前要先下音频。
     * `engine` 为 null 表示这一份包里没有可用的引擎(降级档,或 `.so`/模型没打进包)。
     */
    fun start(
        episode: Episode,
        uiLanguage: String,
        localPath: String?,
        engine: AsrEngine?,
        wordTimestamps: Boolean
    ) {
        val loc = localeFor(uiLanguage)
        /**
         * **同一集正在转就别再起一遍。**
         *
         * 实测一次点击会跑两遍(日志里两条「开始转写」相隔十几秒):按钮所在的
         * `TranscriptPane` 在 `HorizontalPager` 里,页面重组/重建时那次点击的回调有机会再跑一遍。
         * 不挡住的话就是两倍的满载计算 —— 手机烫、电掉得快,而结果一模一样。
         *
         * 失败后的「重试」不受影响:那时 job 已经结束,isActive 为 false。
         */
        if (job?.isActive == true && episode.id == episodeId && loc == localeId) {
            com.yuyin.reverb.util.Logger.i(TAG, "已在转写中,忽略重复的开始请求 id=${episode.id}")
            return
        }
        cancel()
        generation += 1
        val gen = generation
        episodeId = episode.id
        localeId = loc
        _segments.value = emptyList()
        _volatileTail.value = ""

        job = scope.launch {
            runJob(gen, episode, loc, localPath, engine, wordTimestamps)
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
    }

    // ── 执行 ──

    private suspend fun runJob(
        gen: Int,
        episode: Episode,
        loc: String,
        localPath: String?,
        engine: AsrEngine?,
        wordTimestamps: Boolean
    ) {
        fun stale() = gen != generation

        // 1) 官方稿优先
        if (episode.transcriptUrl.isNotBlank()) {
            _state.value = State.FetchingOfficial
            val segs = fetcher.fetch(episode.transcriptUrl, episode.transcriptType)
            if (stale()) return
            if (!segs.isNullOrEmpty()) {
                _segments.value = segs
                _state.value = State.Done
                saveCache(episode.id, loc, segs)
                com.yuyin.reverb.util.Logger.i(TAG, "用官方稿 ${segs.size} 句 id=${episode.id}")
                return
            }
            // 取不到就往下走本机识别(有引擎的话)——「稿链接坏了」不该让功能整个不可用
            com.yuyin.reverb.util.Logger.w(TAG, "官方稿取不到,回退本机识别 id=${episode.id}")
        }

        // 2) 本机识别
        if (engine == null) {
            if (!stale()) _state.value = State.NoEngine
            return
        }
        engine.transcribe(
            episode = episode,
            localPath = localPath,
            localeId = loc,
            wordTimestamps = wordTimestamps,
            // 引擎只报"阶段",界面状态由这里映射 —— 引擎不该知道 UI 有哪些状态
            onStage = { stage ->
                if (!stale()) {
                    _state.value = when (stage) {
                        AsrEngine.Stage.DownloadingAudio -> State.DownloadingAudio
                        AsrEngine.Stage.LoadingModel -> State.LoadingModel
                        AsrEngine.Stage.Running -> State.Running
                        // 引擎说"被计费链路拦下",这里就照它是"拦下"报,不要折成泛泛的失败
                        AsrEngine.Stage.NeedUnmetered -> State.NeedUnmetered
                    }
                }
            },
            onVolatile = { t -> if (!stale()) _volatileTail.value = t },
            onSegment = { seg ->
                if (!stale()) {
                    _segments.value = _segments.value + seg
                    _volatileTail.value = ""
                    if (_state.value != State.Running) _state.value = State.Running
                }
            }
        )
        if (stale()) return
        _volatileTail.value = ""
        if (_segments.value.isEmpty()) {
            /**
             * 引擎已经给出**明确原因**(被蜂窝闸门拦下)时不要把它盖成泛泛的"转写失败":
             * 那一屏给的是"改哪个开关"和重试,而"失败"给的是"再点一次",后者在这个网络下必然又拦一次。
             * 见 REVIEW-2026-10-25 中-3。
             */
            if (_state.value != State.NeedUnmetered) _state.value = State.Failed("")
        } else {
            _state.value = State.Done
            saveCache(episode.id, loc, _segments.value)
        }
    }

    // ── 缓存 ──

    private fun cacheFile(episodeId: String, loc: String) =
        File(dir, "${sanitize(episodeId)}.${loc.ifEmpty { "auto" }}.json")

    /// 只认 `complete = true`、**时间轴口径没变**、且**归属对得上**的缓存 —— 半截的转写下次要重来,不该当成完整稿显示。
    private fun loadCache(episodeId: String, loc: String): List<TranscribedSegment>? {
        val f = cacheFile(episodeId, loc)
        if (!f.exists()) return null
        return try {
            val root = JSONObject(f.readText())
            if (!root.optBoolean("complete")) return null
            /**
             * **归属校验**(见 REVIEW-2026-10-25 低·族 A 末尾那条)。
             *
             * 文件名是 [sanitize] 出来的:非字母数字一律折成 `_`,所以 `abc:def` 与 `abc_def`
             * **写到同一个文件**。原先命中不校验归属,后果不是崩溃而是**张冠李戴** ——
             * 甲集显示乙集的逐字稿,时间轴还看着"像对的"(整句高亮),根本发现不了。
             * 播客 id 里带冒号很常见(guid/uri 形式的 id 就有)。
             *
             * 为什么不改文件名:文件名换成长哈希会让**现存的全部缓存同时作废**,
             * 而这里要防的只是"两个 id 撞同一个名"这一小概率,不是"名字不够长"。
             * 改成写侧带 `episodeId`、读侧比一句:不撞时零成本,撞了就是后写的那份生效、
             * 另一集重转一次 —— 两集反复横跳才会来回重转,而那已经不是本 App 的使用形状。
             *
             * **缺 `episodeId` 的旧缓存照认** —— 那些文件是这一版之前写的,里面没有这个字段;
             * 判它们不匹配等于把全部历史缓存一次作废,收益只有"更严格",代价是用户的全部稿子重转。
             */
            if (root.has("episodeId") && root.optString("episodeId") != episodeId) {
                com.yuyin.reverb.util.Logger.w(TAG, "缓存归属不符(文件名撞车),丢弃 id=$episodeId")
                return null
            }
            /**
             * **旧版本的稿一律作废重转。**
             *
             * 时间轴的算法改过之后,老缓存里的时刻是按旧口径存的 —— 界面无从分辨,
             * 只会照着显示,于是"修好了却还是对不上",而且用户根本没有清缓存的入口去自救。
             * 缺 `version` 字段的就是 v1(改用 whisper 自带 token_timestamps 之前的 DTW 时代)。
             */
            if (root.optInt("version", 1) < CACHE_VERSION) {
                com.yuyin.reverb.util.Logger.i(TAG, "缓存是旧口径(v${root.optInt("version", 1)}),丢弃重转")
                runCatching { f.delete() }
                return null
            }
            val arr = root.optJSONArray("segments") ?: return null
            val out = ArrayList<TranscribedSegment>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(
                    TranscribedSegment(
                        text = o.optString("text"),
                        startMs = o.optInt("startMs"),
                        endMs = o.optInt("endMs"),
                        words = o.optJSONArray("words")?.let { wa ->
                            val ws = ArrayList<TranscribedWord>(wa.length())
                            for (j in 0 until wa.length()) {
                                val w = wa.optJSONObject(j) ?: continue
                                ws.add(TranscribedWord(w.optString("text"), w.optInt("startMs"), w.optInt("endMs")))
                            }
                            ws.ifEmpty { null }
                        }
                    )
                )
            }
            out.ifEmpty { null }
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "缓存读坏了,当作没有:${e.message}")
            null
        }
    }

    private fun saveCache(episodeId: String, loc: String, segs: List<TranscribedSegment>) {
        try {
            val arr = JSONArray()
            for (s in segs) {
                val o = JSONObject()
                    .put("text", s.text)
                    .put("startMs", s.startMs)
                    .put("endMs", s.endMs)
                s.words?.let { ws ->
                    val wa = JSONArray()
                    for (w in ws) {
                        wa.put(JSONObject().put("text", w.text).put("startMs", w.startMs).put("endMs", w.endMs))
                    }
                    o.put("words", wa)
                }
                arr.put(o)
            }
            // 原子写(REVIEW-2026-10-25 高-3 A 步):逐字稿是这里体量最大的一份落盘(整集可达几百 KB),
            // 原先 `writeText` 截断重写时进程死在中间,留下的就是半截 JSON —— 读取侧正好把它当成
            // "没有缓存"(见 loadCache 的 catch),用户看到的是一集"跑完却没了"的稿子。
            // 这些文件可再生(重跑一次识别就有),所以只借 rename 这一件事,不上空态闸:
            // markLoadFailed 不标记,免得一次坏读反过来把后续正常结果也挡住。
            JsonWriter.writeAtomically(
                cacheFile(episodeId, loc),
                JSONObject()
                    .put("localeId", loc)
                    .put("complete", true)
                    .put("version", CACHE_VERSION)
                    // 归属自证:文件名是 sanitize(id) 来的,而 sanitize 将 `:` 与 `_` 折成同一个字符
                    // (`abc:def` 与 `abc_def` 同名),见 REVIEW-2026-10-25 低·族 A 末尾那条。
                    // 把原始 id 写进内容,读侧比一句就能分辨这份稿到底是谁的。
                    .put("episodeId", episodeId)
                    .put("segments", arr)
                    .toString()
            )
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "缓存写失败:${e.message}")
        }
    }

    /// 清缓存时一并删(设置页「清除缓存」会调)。
    fun clearAll() {
        runCatching { dir.listFiles()?.forEach { it.delete() } }
        _segments.value = emptyList()
        _state.value = State.Idle
        episodeId = ""
    }

    fun usageBytes(): Long =
        runCatching { dir.listFiles()?.sumOf { it.length() } ?: 0L }.getOrDefault(0L)

    companion object {
        /**
         * 缓存格式/时间轴口径的版本。**改了时刻的算法就要 +1**,否则用户手机上已经生成的稿
         * 会继续按旧时间轴显示,修复等于没生效。
         *
         * - v1:词级时刻取 whisper 的 DTW(`t_dtw`)—— 整体偏晚 0.4~0.9 秒,已废弃;
         * - v2:改用 whisper 自带的 `token_timestamps`(t0/t1),并保证起点单调不减。
         */
        const val CACHE_VERSION = 2

        /**
         * 界面语言 → 识别/取稿语言。与 macOS `TranscriptStore.locale(for:)` 同一张表。
         * `""`(跟随系统)交给识别引擎自己判断,不在这里猜。
         */
        fun localeFor(uiLanguage: String): String = when (uiLanguage) {
            "zh-Hans", "zh-CN" -> "zh-CN"
            "zh-Hant", "zh-TW" -> "zh-TW"
            "en" -> "en-US"
            "fr" -> "fr-FR"
            "es" -> "es-ES"
            // 「跟随系统」:**要解析成真实语言,不能传空串**。
            // 传空串等于让识别引擎自己猜,而中文猜出来的往往是繁体(见 WhisperEngine.promptFor);
            // 而且缓存 key 会退化成 "auto",换了系统语言也命中同一份旧稿。
            else -> systemLocaleId()
        }

        /// 设备语言 → 与上面同一套写法。中文按地区分简繁(CN/SG 为简,TW/HK/MO 为繁)。
        private fun systemLocaleId(): String {
            val l = java.util.Locale.getDefault()
            val lang = l.language.lowercase()
            if (lang != "zh") return if (l.country.isBlank()) lang else "$lang-${l.country.uppercase()}"
            return when (l.country.uppercase()) {
                "TW", "HK", "MO" -> "zh-TW"
                else -> "zh-CN"
            }
        }

        /// 文件名安全化。与 macOS 同口径:非字母数字换 `_`,截断 120。
        private fun sanitize(s: String): String =
            s.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("").take(120)
    }
}
