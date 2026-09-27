package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.layout.Box
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
                        onPlay = { PlayerController.playOrToggle(ep, episodes) },
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
