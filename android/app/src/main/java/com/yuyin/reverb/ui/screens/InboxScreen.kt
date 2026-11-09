package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.EpisodeBatchBar
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.components.PlayModeButton
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.SELECTION_BAR_SLOT
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 「追更」列表主体:合并所有订阅的**全部单集**(2026-10-10 起不再只留每源最新几集)。
 * 缓存秒显 + 进入即后台刷新 + 下拉刷新。
 * 不含标题栏(留给 [FeedScreen] 包;提升成顶层页之后没有第二个内嵌方了)。
 *
 * 顺序固定「最新发布在前」(InboxStore 的口径,发现首页那一节是同一份列表的**最新 20 条**);
 * 想按别的走法连着听,是播放模式的事(见 `playback.PlayMode`)。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxBody(topPad: Dp = Dp(0f), scrollTopToken: Int = 0) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    val episodes by container.inboxStore.episodes.collectAsStateWithLifecycle()
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val pullState = rememberPullToRefreshState()
    val listState = rememberLazyListState()

    // 双击底部 tab 回顶(见 `ReverbRoot.MainShell` 的三颗 token)。
    LaunchedEffect(scrollTopToken) {
        if (scrollTopToken > 0) listState.animateScrollToItem(0)
    }
    /**
     * **内容更新了就从顶部看起**,不要把用户晾在"上次打开的位置"。
     *
     * 判据是**列表头那条的 id 变了** —— 也就是刷新真的插进了新集。`LazyColumn` 带 key 时
     * 会按 key 锚定当前可见项,不处理的话新集插在头上、视口仍钉着旧的那条,
     * 用户看到的是"更新了但也看不到新内容"。判 id 而不是判列表长度:换源/排序变化也可能
     * 让长度不变而内容全换,那种情况同样该回顶。
     *
     * 首次为 null 时只记不跳(`prev == null`):进页时列表本来就该停在它该停的地方
     * (冷启动就是顶部),而**这一趟刷新如果带来新头**,下一次 effect 就会跳 —— 两条分开。
     */
    var lastHeadId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(episodes.firstOrNull()?.id) {
        val head = episodes.firstOrNull()?.id
        val prev = lastHeadId
        lastHeadId = head
        if (prev != null && head != null && head != prev) listState.animateScrollToItem(0)
    }

    // 多选(批量加入待播)的已选集合。放在这一层而不是行里:行会被 LazyColumn 回收,
    // 且「全选」要一次改整列。空集 = 不在选择模式。
    var picked by remember { mutableStateOf(emptySet<String>()) }

    // 首刷标记:仅在「有订阅但缓存为空」时显示有界的「刷新中」,刷新结束(成功/失败)即收起,
    // 避免无内容时无限转圈。缓存已有时后台静默刷新,不打断浏览。
    var firstLoading by remember { mutableStateOf(subs.isNotEmpty() && episodes.isEmpty()) }

    // 进入即后台刷新(缓存已先显示);订阅变化时也重刷
    LaunchedEffect(subs) {
        if (subs.isNotEmpty() && episodes.isEmpty()) firstLoading = true
        try {
            container.inboxStore.refresh(subs, container.repository)
        } finally {
            firstLoading = false
        }
    }
    // 下拉刷新:多源刷新可能耗时数秒,不能像「发现」页那样 await 到完成(否则指示器挂很久)。
    // 故把刷新丢到长生命周期 scope 后台跑,指示器只短暂示意(600ms)即收起;内容就绪后由
    // InboxStore 原子替换(稳定排序→内容不变不重渲)。clipToBounds 已保证静止态指示器不残留。
    val scope = rememberCoroutineScope()
    if (pullState.isRefreshing) {
        LaunchedEffect(true) {
            scope.launch { container.inboxStore.refresh(subs, container.repository) }
            delay(600)
            pullState.endRefresh()
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .clipToBounds() // 裁掉静止态越界露出的指示器(圆圈常驻的根因)
            .nestedScroll(pullState.nestedScrollConnection)
    ) {
        when {
            episodes.isNotEmpty() -> LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    top = topPad,
                    bottom = 24.dp + LocalGlassBottomPad.current +
                        if (picked.isNotEmpty()) SELECTION_BAR_SLOT else 0.dp
                )
            ) {
                items(episodes, key = { it.id }) { ep ->
                    val played = history.firstOrNull { it.episode.id == ep.id }?.played ?: false
                    EpisodeListItem(
                        episode = ep,
                        isCurrent = current?.id == ep.id,
                        isPlaying = isPlaying,
                        onPlay = { PlayerController.playOrToggle(ep, episodes, TAG_INBOX) },
                        showPodcastTitle = true,
                        played = played,
                        // 不给「标记已播完」:这一列的语义是"订阅的最新更新",标完在这里
                        // 既看不出变化也没处撤 —— 而且这些集大多没有历史条目,markPlayed 对它们是
                        // **静默空操作**(见 HistoryStore.markPlayed 的入口判断)。规则见 Components.kt。
                        onPlayNext = { PlayerController.playNext(ep) },
                        onEnqueue = { PlayerController.enqueue(ep) },
                        selectionMode = picked.isNotEmpty(),
                        selected = ep.id in picked,
                        onToggleSelect = {
                            picked = if (ep.id in picked) picked - ep.id else picked + ep.id
                        },
                        onEnterSelection = { picked = setOf(ep.id) }
                    )
                }
            }
            subs.isEmpty() -> EmptyHint(stringResource(R.string.inbox_empty_no_subs))
            firstLoading -> LoadingBox() // 有订阅但缓存为空:首刷进行中(有界,结束即收起)
            else -> EmptyHint(stringResource(R.string.inbox_empty_no_updates)) // 刷新完仍无内容
        }
        // 同 CategoryPage:指示器下移躲开玻璃分类条,且不拉不转时不组合,
        // 免得 m3 1.2 静止态的圆从玻璃条下缘半露出来。
        if (pullState.isRefreshing || pullState.verticalOffset > 0f) {
            PullToRefreshContainer(
                state = pullState,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = topPad)
            )
        }
        EpisodeBatchBar(
            picked = picked,
            episodes = episodes,
            onPicked = { picked = it },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 16.dp)
                .padding(bottom = LocalGlassBottomPad.current + 4.dp)
        )
    }
}

/**
 * 「最新」这一列的身份串。用在**两处**,两边必须是同一个值:
 * 标题栏那颗播放模式按钮按它读写自己那一格,列表里某一行起播时把它随 `playQueue` 传下去
 * (装机日志里 `tag='…'` 读到的就是它)。否则「在这一列设的模式」和「这一列起播时用的模式」
 * 各走各的,而且不报错,只表现成"设了没生效"。
 *
 * 它原先与 `TAG_FAV`/`TAG_DL` 一起写在 `LibraryScreen.kt`(那时这一列是音阁的第 2 段);
 * 2026-10-08 这一列提升成顶层「追更」页,串跟着搬到这里来。**值没变** ——
 * 播放模式是按这个串存盘的,改值会让用户设备上已设的那一格失效。
 */
const val TAG_INBOX = "inbox"

/**
 * 顶层「追更」页 = 标题栏 + [InboxBody]。
 *
 * 为什么提上来:内容是"我订阅的频道播过的全部单集",是每天打开 App 要看的第一眼,
 * 而它原先埋在音阁六个分段里、要靠横滑才够得着。
 *
 * ⚠️ [DiscoverScreen] 首屏那一节「最新更新」读的是**同一个 inboxStore**,但**不是同一份列表**:
 * 这一页是全量(可一直往下翻到最早的集),那一节只是最新 `HOME_LATEST_MAX` 条。
 * 两个入口指向同一个数据源是有意保留的 —— 那一节是给「降级首屏」(无目录时打开就看到
 * 新内容)用的,且它的下面还挂着导入入口,不能顶到几千行以下;这一页才是这一列自己的管理入口
 * (标题栏那颗按钮按 `TAG_INBOX` 存这一列的播放模式;那一节起播走不带 tag 的重载,因此读不到这个模式)。
 *
 * 标题栏右端那颗是**本列的播放模式按钮**,与频道主页、收藏、下载用的是同一颗
 * (`Components.kt PlayModeButton`)。位置从分段条右端搬到标题栏,功能不能因为搬家而丢。
 */
@Composable
fun FeedScreen(scrollTopToken: Int = 0) {
    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.nav_feed),
            action = { PlayModeButton(TAG_INBOX) }
        )
        InboxBody(scrollTopToken = scrollTopToken)
    }
}
