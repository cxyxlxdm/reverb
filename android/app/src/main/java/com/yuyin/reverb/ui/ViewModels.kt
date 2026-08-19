package com.yuyin.reverb.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.compose.runtime.Composable
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.local.CategoryStore
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.data.remote.PodcastRepository
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

// ---------- 发现（检索）----------

sealed interface DiscoverState {
    data object Idle : DiscoverState
    data object Loading : DiscoverState
    data object Empty : DiscoverState
    data class Success(
        val podcasts: List<Podcast>,
        val episodes: List<Episode>,
        val source: String
    ) : DiscoverState
}

/** 发现页分类。key 为稳定标识(用于持久化/身份)，labelRes 为本地化显示名，genreId 对应 Apple 分类。 */
data class Category(val key: String, val labelRes: Int, val genreId: Int?)

val DISCOVER_CATEGORIES = listOf(
    Category("recommend", R.string.cat_recommend, null),
    Category("news", R.string.cat_news, 1489),
    Category("business", R.string.cat_business, 1321),
    Category("tech", R.string.cat_tech, 1318),
    Category("culture", R.string.cat_culture, 1324),
    Category("knowledge", R.string.cat_knowledge, 1533),
    Category("education", R.string.cat_education, 1304),
    Category("comedy", R.string.cat_comedy, 1303),
    Category("health", R.string.cat_health, 1512),
    Category("history", R.string.cat_history, 1487),
    Category("sports", R.string.cat_sports, 1545),
    Category("food", R.string.cat_food, 1306),
    Category("travel", R.string.cat_travel, 1320),
    Category("anime", R.string.cat_anime, 1499),
    Category("relationship", R.string.cat_relationship, 1517),
    Category("arts", R.string.cat_arts, 1301),
    Category("music", R.string.cat_music, 1310),
    Category("kids", R.string.cat_kids, 1305),
    Category("tv", R.string.cat_tv, 1309)
)

/** 地区选项。code 为 null 表示自动跟随设备；labelRes 为本地化显示名。 */
data class RegionOption(val code: String?, val labelRes: Int)

val REGION_OPTIONS = listOf(
    RegionOption(null, R.string.region_auto),
    RegionOption("cn", R.string.region_cn),
    RegionOption("hk", R.string.region_hk),
    RegionOption("tw", R.string.region_tw),
    RegionOption("us", R.string.region_us),
    RegionOption("jp", R.string.region_jp),
    RegionOption("kr", R.string.region_kr),
    RegionOption("gb", R.string.region_gb),
    RegionOption("sg", R.string.region_sg),
    RegionOption("au", R.string.region_au),
    RegionOption("ca", R.string.region_ca),
    RegionOption("de", R.string.region_de)
)

/** 地区选项。code 为 null 表示「自动跟随设备」。 */
class DiscoverViewModel(
    private val repo: PodcastRepository,
    private val categoryStore: CategoryStore
) : ViewModel() {

    var query by mutableStateOf("")
        private set
    var state by mutableStateOf<DiscoverState>(DiscoverState.Idle)
        private set

    // 用户自定义顺序的分类列表
    var orderedCategories by mutableStateOf(loadOrdered())
        private set

    private fun loadOrdered(): List<Category> {
        val saved = categoryStore.loadOrder()
        if (saved.isEmpty()) return DISCOVER_CATEGORIES
        val byKey = DISCOVER_CATEGORIES.associateBy { it.key }
        val ordered = saved.mapNotNull { byKey[it] }
        val missing = DISCOVER_CATEGORIES.filter { it.key !in saved }
        return (ordered + missing).ifEmpty { DISCOVER_CATEGORIES }
    }

    fun saveOrder(newOrder: List<Category>) {
        if (newOrder.isEmpty()) return
        orderedCategories = newOrder
        categoryStore.saveOrder(newOrder.map { it.key })
    }

    /** 立即返回该分类可展示的列表（秒开）。缓存为空时是随包内置清单，不会是空白。 */
    fun cachedCategory(category: Category, region: String): List<Podcast> = repo.cachedPopular(category.genreId, region)

    /** 当前给出的是内置清单而非联网榜单 —— 标题据此显示「内置精选」。 */
    fun isSeedCategory(category: Category, region: String): Boolean = repo.isSeedList(category.genreId, region)

    /** 拉取该分类最新列表（成功回写缓存）。 */
    suspend fun refreshCategory(category: Category, region: String): List<Podcast> = repo.refreshPopular(category.genreId, region)

    fun onQueryChange(q: String) {
        query = q
        // 清空输入即回到热门推荐，清掉上一次的搜索结果
        if (q.isBlank()) state = DiscoverState.Idle
    }

    fun clearQuery() {
        query = ""
        state = DiscoverState.Idle
    }

    fun search(region: String) {
        val q = query.trim()
        if (q.isBlank()) {
            state = DiscoverState.Idle
            return
        }
        viewModelScope.launch {
            state = DiscoverState.Loading
            // 频道与单集并行检索，切换分段时不再重复请求
            val outcome: PodcastRepository.SearchOutcome
            val episodes: List<Episode>
            coroutineScope {
                val podsJob = async { repo.search(q, region) }
                val epsJob = async { repo.searchEpisodes(q, region) }
                outcome = podsJob.await()
                episodes = epsJob.await()
            }
            state = if (outcome.podcasts.isEmpty() && episodes.isEmpty()) {
                DiscoverState.Empty
            } else {
                DiscoverState.Success(outcome.podcasts, episodes, outcome.sourceLabel)
            }
        }
    }
}

// ---------- 播客详情 ----------

sealed interface PodcastState {
    data object Loading : PodcastState
    data object Error : PodcastState

    /**
     * @param staleAt 非 0 表示这是**缓存内容**（联网刷新还没成功），值为缓存落盘时刻；
     *                刷新成功后置 0。UI 据此显示「离线 · 上次更新于 X」。
     */
    data class Loaded(
        val podcast: Podcast,
        val episodes: List<Episode>,
        val staleAt: Long = 0L
    ) : PodcastState
}

class PodcastViewModel(private val repo: PodcastRepository) : ViewModel() {
    var state by mutableStateOf<PodcastState>(PodcastState.Loading)
        private set

    private var loadedFeed: String? = null

    /**
     * 先出缓存（秒开、断网也有内容），再后台刷新替换。
     * 刷新失败时**保留缓存内容并标记为陈旧**，只有连缓存都没有才是 Error。
     */
    fun load(feedUrl: String) {
        if (loadedFeed == feedUrl && state is PodcastState.Loaded) return
        loadedFeed = feedUrl
        val cached = repo.cachedFeed(feedUrl)
        state = if (cached != null) {
            PodcastState.Loaded(cached.podcast, cached.episodes, repo.feedCachedAt(feedUrl))
        } else {
            PodcastState.Loading
        }
        viewModelScope.launch {
            val result = repo.feed(feedUrl)
            // 期间用户可能已经翻到别的频道，别把结果盖到当前页上
            if (loadedFeed != feedUrl) return@launch
            state = when {
                result != null -> PodcastState.Loaded(result.podcast, result.episodes)
                cached != null -> PodcastState.Loaded(cached.podcast, cached.episodes, repo.feedCachedAt(feedUrl))
                else -> PodcastState.Error
            }
        }
    }

    /** 下拉刷新：强制重新拉取；失败保持现状（不把已有内容换成错误页）。 */
    fun refresh(feedUrl: String) {
        viewModelScope.launch {
            val result = repo.feed(feedUrl)
            if (loadedFeed != feedUrl) return@launch
            if (result != null) state = PodcastState.Loaded(result.podcast, result.episodes)
        }
    }
}

// ---------- Compose 工厂 ----------

@Composable
fun discoverViewModel(): DiscoverViewModel = viewModel(
    factory = viewModelFactory {
        initializer {
            val app = this[APPLICATION_KEY] as ReverbApp
            DiscoverViewModel(app.container.repository, app.container.categoryStore)
        }
    }
)

@Composable
fun podcastViewModel(): PodcastViewModel = viewModel(
    factory = viewModelFactory {
        initializer {
            val app = this[APPLICATION_KEY] as ReverbApp
            PodcastViewModel(app.container.repository)
        }
    }
)
