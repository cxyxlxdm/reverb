package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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

/** 最新:合并所有订阅的最新单集。缓存秒显 + 进入即刷新 + 下拉刷新。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxScreen() {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    val episodes by container.inboxStore.episodes.collectAsStateWithLifecycle()
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val pullState = rememberPullToRefreshState()

    // 进入即后台刷新(缓存已先显示);订阅变化时也重刷
    LaunchedEffect(subs) {
        container.inboxStore.refresh(subs, container.repository)
    }
    if (pullState.isRefreshing) {
        LaunchedEffect(true) {
            try {
                container.inboxStore.refresh(subs, container.repository)
            } finally {
                pullState.endRefresh()
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(title = stringResource(R.string.nav_inbox))
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
                else -> LoadingBox() // 有订阅但缓存为空:首刷进行中
            }
            PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
        }
    }
}
