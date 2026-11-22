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
import com.yuyin.reverb.data.local.StationStore
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.FeedCredential
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.data.model.Station
import com.yuyin.reverb.data.remote.LiveStreamSource
import com.yuyin.reverb.data.remote.PodcastRepository
import com.yuyin.reverb.data.remote.RadioBrowserSource
import com.yuyin.reverb.playback.PlayerController
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import java.util.UUID

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

    /**
     * 用户粘的是一路**直播流**:它既不是 RSS 也不是视频,解析不出任何节目/分集,
     * 因此用单独一档把"这一条能播"这件事交给界面,而不是让它落进 [Empty] 里
     * 被读成"没搜到/加载失败"。
     */
    data class Live(val episode: Episode) : DiscoverState
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

/** 私有订阅源被 401 打回时,界面要弹的输入框。 */
data class FeedAuthPrompt(val feedUrl: String, val failed: Boolean = false)

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

    /** 粘进来的私有源要求 Basic 认证时非 null —— 界面据此弹输入框。 */
    var authPrompt by mutableStateOf<FeedAuthPrompt?>(null)
        private set

    // 最近一次检索的私有源地址(去掉 userinfo 的那一份)与地区;401 回来时用来判断
    // "这一枪是不是冲着当前输入打的" —— 旧请求的 401 不该弹到新词下面。
    private var lastRegion = ""
    private var lastAuthUrl: String? = null
    private var authAttempted = false

    init {
        viewModelScope.launch {
            repo.authRequired.collect { url ->
                if (url != lastAuthUrl) return@collect
                authPrompt = FeedAuthPrompt(url, failed = authAttempted)
            }
        }
    }

    fun dismissAuth() {
        authPrompt = null
    }

    /** 输入框里点了「保存」:落进本机凭据账本,然后用同一地区再搜一次。 */
    fun submitAuth(username: String, password: String) {
        val prompt = authPrompt ?: return
        authAttempted = true
        repo.saveAuth(prompt.feedUrl, username, password)
        authPrompt = null
        search(lastRegion)
    }

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
        if (q.isBlank()) {
            searchGen++      // 作废在途请求,否则它回来还会把结果盖回空输入框下面
            lastAuthUrl = null
            state = DiscoverState.Idle
        }
    }

    fun clearQuery() {
        query = ""
        searchGen++
        lastAuthUrl = null
        state = DiscoverState.Idle
    }

    /**
     * 搜索请求的**代次**。
     *
     * 为什么必须有(见 REVIEW-2026-10-25 低·族 C-1):这一路原先没有任何守卫 ——
     * 用户连输两次「播客」「播客行业」,或从结果页返回后改词再搜,两次 `search()` 的协程同时在跑;
     * 谁**后回来**谁写 `state`,而"后回来"由网络决定,不是由用户输入顺序决定。
     * 慢的那个旧请求完全可能最后到达,于是界面显示的是**上一次那个词**的结果,
     * 而输入框里是当前那个词 —— 症状是"搜不到/结果和关键词对不上",且无法复现。
     *
     * 同一条经验在 `PodcastViewModel.load` 里已经有了(`loadedFeed != feedUrl` 那道判据,见那里),
     * 本类之前只补了详情页、漏了搜索页。
     *
     * 口径:每次**新的搜索动作**(以及清空/改空)都让代次 +1;协程回来时发现自己不是最新一代就丢弃。
     * 只丢结果、不取消旧协程 —— 旧请求已经发出去了,取消省不下什么,而这里要防的是它盖新结果。
     * (仓库没有自动化测试,这条的判据见代码注释下方的真机判据。)
     * 真机判据:飞行模式关掉但用限速(或热键连点搜索)输入 A、立刻改成 B,B 的结果必须最终胜出。
     */
    private var searchGen = 0

    fun search(region: String) {
        val q = query.trim()
        lastRegion = region
        // URL 直连分支才会触发 401;关键词检索把 lastAuthUrl 清掉,免得旧的 401 弹到新词上
        lastAuthUrl = if (q.startsWith("http://", true) || q.startsWith("https://", true)) {
            FeedCredential.splitUrl(q).first
        } else null
        if (q.isBlank()) {
            searchGen++
            state = DiscoverState.Idle
            return
        }
        val gen = ++searchGen
        viewModelScope.launch {
            state = DiscoverState.Loading
            /**
             * 直播探针与目录检索**并行发**。粘一条电台地址时 `repo.search` 会先把它当 RSS
             * 直连去拉、一路白等到超时才算"空的",串行等于让用户先干等十几秒才看到
             * "这就是那一路流"。探针先回来就先上屏 —— 但只在当前仍是 loading / empty 时落,
             * 目录已经给出结果的话,直播不该反过来盖掉它。
             */
            if (LiveStreamSource.looksLikeStream(q)) {
                viewModelScope.launch {
                    val live = repo.live.resolve(q)
                    if (gen == searchGen && live != null
                        && (state is DiscoverState.Loading || state is DiscoverState.Empty)) {
                        state = DiscoverState.Live(live)
                    }
                }
            }
            // 频道与单集并行检索，切换分段时不再重复请求
            val outcome: PodcastRepository.SearchOutcome
            val episodes: List<Episode>
            coroutineScope {
                val podsJob = async { repo.search(q, region) }
                val epsJob = async { repo.searchEpisodes(q, region) }
                outcome = podsJob.await()
                episodes = epsJob.await()
            }
            // 期间又发起了新的搜索(或清空了输入):这一份结果作废
            if (gen != searchGen) {
                com.yuyin.reverb.util.Logger.i("DiscoverVM", "搜索结果作废 gen=$gen cur=$searchGen q=$q")
                return@launch
            }
            // 这次拿到了内容 —— 之前那对凭据被接受,下次 401 就不该再说"不对"
            if (outcome.podcasts.isNotEmpty()) authAttempted = false
            state = if (outcome.podcasts.isEmpty() && episodes.isEmpty()) {
                // 探针可能已经上屏;还在路上的那一份回来时会自己落状态,这里保持不动即可。
                if (state is DiscoverState.Live) state else DiscoverState.Empty
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

    /** 这个订阅源要求 Basic 认证时非 null —— 界面据此弹输入框。 */
    var authPrompt by mutableStateOf<FeedAuthPrompt?>(null)
        private set

    private var loadedFeed: String? = null
    private var authAttempted = false

    init {
        viewModelScope.launch {
            repo.authRequired.collect { url ->
                // 401 可能来自上一页的源或后台巡检 —— 只认当前这一列
                val current = loadedFeed ?: return@collect
                if (FeedCredential.splitUrl(current).first != url) return@collect
                authPrompt = FeedAuthPrompt(url, failed = authAttempted)
            }
        }
    }

    fun dismissAuth() {
        authPrompt = null
    }

    /** 输入框里点了「保存」:落盘后强制重拉这一列(不等下拉刷新)。 */
    fun submitAuth(username: String, password: String) {
        val prompt = authPrompt ?: return
        authAttempted = true
        repo.saveAuth(prompt.feedUrl, username, password)
        authPrompt = null
        loadedFeed?.let { load(it, force = true) }
    }

    /**
     * 先出缓存（秒开、断网也有内容），再后台刷新替换。
     * 刷新失败时**保留缓存内容并标记为陈旧**，只有连缓存都没有才是 Error。
     *
     * @param force 跳过"已经是这个 feed 的 Loaded 态就早退"那道门。401 之后补了凭据
     *              必须真的再发一次请求,否则界面看起来像保存没生效。
     */
    fun load(feedUrl: String, force: Boolean = false) {
        if (!force && loadedFeed == feedUrl && state is PodcastState.Loaded) return
        val switched = loadedFeed != feedUrl
        loadedFeed = feedUrl
        if (switched) authAttempted = false
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
            if (result != null) authAttempted = false
        }
    }

    /** 下拉刷新：强制重新拉取；失败保持现状（不把已有内容换成错误页）。
     *  挂起式：调用方（详情页的拉取协程）能等到完成，指示器不会比网络先收起。 */
    suspend fun refresh(feedUrl: String) {
        val result = repo.feed(feedUrl)
        if (loadedFeed != feedUrl) return
        if (result != null) state = PodcastState.Loaded(result.podcast, result.episodes)
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

// ---------- 直播电台 ----------

/** 在线目录这一段的三态之外还多一档 [Error]:空结果与连不上对用户的下一步动作不同。 */
sealed interface DirectoryState {
    data object Idle : DirectoryState
    data object Loading : DirectoryState
    data class Success(val stations: List<Station>) : DirectoryState
    data object Empty : DirectoryState
    data object Error : DirectoryState
}

/** 保存失败的三类,由界面翻成五语种文案(VM 不碰 Context)。 */
enum class StationSaveError { INVALID_URL, DUPLICATE, NOT_STREAM }

/**
 * 直播电台页的状态:本机账本直接观察 [StationStore],目录检索与保存是这里的两笔异步。
 *
 * 目录请求带**代次守卫**,与发现页同一条理由(见 `DiscoverViewModel.searchGen`):
 * 用户连续换词时,先发后到的旧结果不能盖住新词的结果。
 */
class RadioViewModel(
    private val store: StationStore,
    private val directory: RadioBrowserSource,
    private val live: LiveStreamSource
) : ViewModel() {

    val stations: StateFlow<List<Station>> = store.stations

    var directoryState by mutableStateOf<DirectoryState>(DirectoryState.Idle)
        private set
    var query by mutableStateOf("")
        private set
    var saving by mutableStateOf(false)
        private set
    var saveError by mutableStateOf<StationSaveError?>(null)
        private set

    /** 热门那一屏的进程内缓存:清空搜索框回到热门时不必再等一次网络。 */
    private var popular: List<Station>? = null
    private var requestGen = 0

    fun seedStations(): List<Station> = store.seedStations()

    fun onQueryChange(q: String) {
        query = q
        if (q.isBlank()) {
            requestGen++
            showPopular()
        }
    }

    /** 进页时调一次;已有内容(热门或搜索结果)就不动,免得每次切回 tab 都重发。 */
    fun ensureDirectory() {
        if (directoryState !is DirectoryState.Idle) return
        showPopular()
    }

    private fun showPopular() {
        val cached = popular
        if (cached != null) {
            directoryState = if (cached.isEmpty()) DirectoryState.Error else DirectoryState.Success(cached)
            return
        }
        val gen = ++requestGen
        viewModelScope.launch {
            directoryState = DirectoryState.Loading
            val list = directory.popular()
            if (gen != requestGen) return@launch
            popular = list
            // 热门拉空与没连上分开报:前者大概率是镜像回了个空数组,后者是两条都超时
            directoryState = if (list.isEmpty()) DirectoryState.Error else DirectoryState.Success(list)
        }
    }

    fun search() {
        val q = query.trim()
        if (q.isBlank()) {
            showPopular()
            return
        }
        val gen = ++requestGen
        viewModelScope.launch {
            directoryState = DirectoryState.Loading
            // 只记词数与结果数,不记原词(隐私政策第二节)
            com.yuyin.reverb.util.Logger.i("RadioVM", "dir search words=${q.split(Regex("\\s+")).size}")
            val list = directory.search(q)
            if (gen != requestGen) return@launch
            directoryState = if (list.isEmpty()) DirectoryState.Empty else DirectoryState.Success(list)
        }
    }

    fun retry() {
        if (query.isBlank()) {
            popular = null
            showPopular()
        } else {
            search()
        }
    }

    fun isSaved(station: Station): Boolean = store.containsUrl(station.url)

    /** 目录 / 精选里点「+」。返回 false 表示这台已经在自己的列表里。 */
    fun addCopy(station: Station): Boolean = store.add(station)

    fun remove(id: String) = store.remove(id)

    fun resetSaveState() {
        saveError = null
        saving = false
    }

    /**
     * 新增或修改一条电台。
     *
     * **地址变了才探针**(新条目也算):只改名字不该被网络卡住,而一个新地址若不先确认
     * 能当音频流播,用户会遇到"列表里有一条,点了没反应" —— 那比当场拒绝更难解释。
     * 名称留空时用探针拿到的台名(ICY 的 icy-name,其次主机名)兜底。
     */
    fun save(
        existing: Station?,
        name: String,
        url: String,
        logo: String,
        group: String,
        onSaved: () -> Unit
    ) {
        if (saving) return
        val cleanUrl = url.trim()
        if (!cleanUrl.startsWith("http://", ignoreCase = true) &&
            !cleanUrl.startsWith("https://", ignoreCase = true)
        ) {
            saveError = StationSaveError.INVALID_URL
            return
        }
        val duplicate = if (existing == null) store.containsUrl(cleanUrl)
        else store.containsUrlExcept(cleanUrl, existing.id)
        if (duplicate) {
            saveError = StationSaveError.DUPLICATE
            return
        }
        saveError = null
        saving = true
        viewModelScope.launch {
            val changedUrl = existing == null || existing.url.trim() != cleanUrl
            val probe = if (changedUrl) live.resolve(cleanUrl) else null
            if (changedUrl && probe == null) {
                saveError = StationSaveError.NOT_STREAM
                saving = false
                return@launch
            }
            val finalName = name.trim()
                .ifBlank { probe?.title.orEmpty() }
                .ifBlank { hostOf(cleanUrl) }
            val st = Station(
                id = existing?.id ?: "local:${UUID.randomUUID()}",
                name = finalName,
                url = cleanUrl,
                logo = logo.trim(),
                group = Station.normalizeGroup(group),
                country = existing?.country ?: "",
                source = existing?.source ?: Station.SOURCE_MANUAL
            )
            if (existing == null) store.add(st) else store.update(st)
            saving = false
            onSaved()
        }
    }

    /**
     * 起播。合成出来的 Episode 与搜索框粘流那条**同 id**(`live:<url>`):
     * 同一路流不管从哪个入口点,队列里都只算一条;`isLive` 让播放层关掉历史/缓存/续播。
     */
    fun play(station: Station, liveLabel: String) {
        PlayerController.play(
            Episode(
                id = "live:${station.url}",
                title = station.name,
                description = "",
                audioUrl = station.url,
                artworkUrl = station.logo,
                podcastTitle = liveLabel,
                durationSec = 0,
                pubDate = "",
                feedUrl = "",
                isLive = true
            )
        )
    }

    private fun hostOf(url: String): String =
        url.substringAfter("://").substringBefore('/').ifBlank { url }
}

@Composable
fun radioViewModel(): RadioViewModel = viewModel(
    factory = viewModelFactory {
        initializer {
            val app = this[APPLICATION_KEY] as ReverbApp
            RadioViewModel(app.container.stationStore, app.container.radioBrowser, app.container.repository.live)
        }
    }
)
