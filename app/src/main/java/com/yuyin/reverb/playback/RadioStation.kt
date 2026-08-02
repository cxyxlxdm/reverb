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

    private var repo: PodcastRepository? = null
    private var region: String = "us"
    private var genreIds: List<Int?> = emptyList()

    // 最近播过的单集 id,避免短期内重复(容量有限,超出丢最旧)
    private val recent = ArrayDeque<String>()
    private const val RECENT_CAP = 40

    private val _preparing = MutableStateFlow(false)
    /** 正在抓取下一首(开台/换台时按钮转圈)。 */
    val preparing: StateFlow<Boolean> = _preparing

    /** 每次开台/换台前用最新的地区与分类刷新配置。 */
    fun configure(repo: PodcastRepository, region: String, genreIds: List<Int?>) {
        this.repo = repo
        this.region = region
        this.genreIds = genreIds
    }

    /** 开台:抓第一首并播放;成功返回 true,抓不到返回 false(不进入电台模式)。 */
    suspend fun start(): Boolean {
        val ep = fetchNext() ?: return false
        PlayerController.startRadio { fetchNext() }
        PlayerController.play(ep, isRadio = true)
        return true
    }

    /** 换台:立刻切到下一首随机节目;抓不到返回 false(保持当前播放)。 */
    suspend fun skip(): Boolean {
        val ep = fetchNext() ?: return false
        PlayerController.play(ep, isRadio = true)
        return true
    }

    fun stop() = PlayerController.stopRadio()

    /** 抓一首没在最近列表里的随机单集(同时记录进最近列表)。 */
    private suspend fun fetchNext(): Episode? {
        val r = repo ?: return null
        _preparing.value = true
        return try {
            r.randomEpisode(region, genreIds, recent.toSet())?.also { remember(it.id) }
        } catch (e: Exception) {
            null
        } finally {
            _preparing.value = false
        }
    }

    private fun remember(id: String) {
        recent.addLast(id)
        while (recent.size > RECENT_CAP) recent.removeFirst()
    }
}
