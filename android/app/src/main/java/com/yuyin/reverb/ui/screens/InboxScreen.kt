package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.components.PlayModeButton
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 「最新」列表主体:合并所有订阅的最新单集。缓存秒显 + 进入即后台刷新 + 下拉刷新。
 * 不含标题栏(供「音阁」的「最新」分段内嵌复用)。
 *
 * 顺序固定「最新发布在前」(InboxStore 的口径,发现首页那条「最新」是同一份);
 * 想按别的走法连着听,是播放模式的事(见 `playback.PlayMode`)。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxBody(topPad: Dp = Dp(0f)) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    val episodes by container.inboxStore.episodes.collectAsStateWithLifecycle()
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val pullState = rememberPullToRefreshState()

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
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    top = topPad,
                    bottom = 24.dp + LocalGlassBottomPad.current
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
                        onTogglePlayed = { container.historyStore.markPlayed(ep.id, !played) },
                        onPlayNext = { PlayerController.playNext(ep) },
                        onEnqueue = { PlayerController.enqueue(ep) }
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
 * 为什么提上来:内容是"全部订阅的最新单集",是每天打开 App 要看的第一眼,
 * 而它原先埋在音阁六个分段里、要靠横滑才够得着。
 *
 * ⚠️ [DiscoverScreen] 首屏那条「最新更新」读的是**同一个 inboxStore、同一份全量列表**,
 * 所以这一页与那一节内容是重复的 —— 有意保留:那一节是给「降级首屏」(无目录时打开就看到
 * 新内容)用的,这一页才是这一列自己的管理入口(标题栏那颗按钮按 `TAG_INBOX` 存这一列的
 * 播放模式;那一节起播走不带 tag 的重载,因此读不到这个模式)。
 *
 * 标题栏右端那颗是**本列的播放模式按钮**,与频道主页、收藏、下载用的是同一颗
 * (`Components.kt PlayModeButton`)。位置从分段条右端搬到标题栏,功能不能因为搬家而丢。
 */
@Composable
fun FeedScreen() {
    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.nav_feed),
            action = { PlayModeButton(TAG_INBOX) }
        )
        InboxBody()
    }
}
