package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
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
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.EpisodeListItem

/**
 * 「最新」列表主体:合并所有订阅的最新单集。缓存秒显 + 进入即后台刷新 + 下拉刷新。
 * 不含标题栏(供「音阁」的「最新」分段内嵌复用)。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxBody() {
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
    // 下拉刷新:增量刷新会持续较久(要等各源),故指示器只短暂显示即收起,刷新在后台继续增量填充,
    // 避免"内容早出来了圈还在转"的卡死观感。刷新放在长生命周期 scope,不随指示器收起被取消。
    val scope = rememberCoroutineScope()
    if (pullState.isRefreshing) {
        LaunchedEffect(true) {
            scope.launch {
                try { container.inboxStore.refresh(subs, container.repository) } catch (_: Exception) {}
            }
            kotlinx.coroutines.delay(700)
            pullState.endRefresh()
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .nestedScroll(pullState.nestedScrollConnection)
    ) {
        when {
            episodes.isNotEmpty() -> LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 24.dp)
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
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }
}
