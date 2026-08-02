package com.yuyin.reverb.playback

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.remote.PodcastRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * 随机电台:从热门榜单里随机取节目自动播放,播完自动接下一首(豆瓣FM 式体验)。
 *
 * 职责边界:只负责「下一首从哪来」与最近去重;是否在台、自动续播由 [PlayerController] 统一持有。
 * 因此电台开关状态请观察 [PlayerController.radioMode],本对象仅额外提供抓取中的 [preparing] 提示。
 */
object RadioStation {

    /** 随机(全分类) / 情境(按时段选分类)。 */
    enum class Mode { RANDOM, CONTEXTUAL }

    private var repo: PodcastRepository? = null
    private var region: String = "us"
    private var userGenreIds: List<Int?> = emptyList()

    // 最近播过的单集 id,避免短期内重复(容量有限,超出丢最旧)
    private val recent = ArrayDeque<String>()
    private const val RECENT_CAP = 40

    // 正在抓取下一首的电台类型(为 null 表示未在抓取);仅让对应按钮转圈,避免两个按钮同时转
    private val _preparingMode = MutableStateFlow<Mode?>(null)
    val preparingMode: StateFlow<Mode?> = _preparingMode

    // 当前电台类型(供 UI 高亮对应按钮);电台是否开启以 PlayerController.radioMode 为准
    private val _mode = MutableStateFlow<Mode?>(null)
    val mode: StateFlow<Mode?> = _mode

    /** 每次开台/换台前用最新的地区与分类刷新配置。 */
    fun configure(repo: PodcastRepository, region: String, genreIds: List<Int?>) {
        this.repo = repo
        this.region = region
        this.userGenreIds = genreIds
    }

    /** 开台:抓第一首并播放;成功返回 true,抓不到返回 false(不进入电台模式)。 */
    suspend fun start(mode: Mode): Boolean {
        _mode.value = mode
        val ep = fetchNext()
        if (ep == null) {
            if (!PlayerController.radioMode.value) _mode.value = null
            return false
        }
        PlayerController.startRadio { fetchNext() }
        PlayerController.play(ep, isRadio = true)
        return true
    }

    /** 换台:立刻切到下一首(沿用当前电台类型);抓不到返回 false(保持当前播放)。 */
    suspend fun skip(): Boolean {
        val ep = fetchNext() ?: return false
        PlayerController.play(ep, isRadio = true)
        return true
    }

    fun stop() {
        PlayerController.stopRadio()
        _mode.value = null
    }

    /** 情境电台:按当前时段挑选贴合心境的分类(Apple genreId)。 */
    private fun contextualGenreIds(): List<Int?> {
        val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
        return when (hour) {
            in 5..8 -> listOf(1489, 1321, 1533)        // 清晨:新闻·商业·知识
            in 9..11 -> listOf(1489, 1318, 1321)       // 上午:新闻·科技·商业
            in 12..13 -> listOf(1303, 1324, 1306)      // 午间:喜剧·文化·美食
            in 14..17 -> listOf(1318, 1533, 1324)      // 下午:科技·知识·文化
            in 18..21 -> listOf(1303, 1310, 1517, 1324) // 晚间:喜剧·音乐·情感·文化
            else -> listOf(1512, 1310, 1324)           // 深夜:健康(助眠)·音乐·文化
        }
    }

    private fun effectiveGenreIds(): List<Int?> =
        if (_mode.value == Mode.CONTEXTUAL) contextualGenreIds() else userGenreIds

    /** 抓一首没在最近列表里的随机单集(同时记录进最近列表)。 */
    private suspend fun fetchNext(): Episode? {
        val r = repo ?: return null
        _preparingMode.value = _mode.value
        return try {
            r.randomEpisode(region, effectiveGenreIds(), recent.toSet())?.also { remember(it.id) }
        } catch (e: Exception) {
            null
        } finally {
            _preparingMode.value = null
        }
    }

    private fun remember(id: String) {
        recent.addLast(id)
        while (recent.size > RECENT_CAP) recent.removeFirst()
    }
}
