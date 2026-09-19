package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ViewList
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.DownloadStatus
import com.yuyin.reverb.data.model.DownloadedEpisode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.components.GLASS_CHIPS_TOP_PAD
import com.yuyin.reverb.ui.components.GlassChipsRow
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.PodcastGridItem
import com.yuyin.reverb.ui.components.PodcastListItem
import kotlinx.coroutines.launch

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(onOpen: (Podcast) -> Unit, onOpenSettings: () -> Unit, onOpenListenStats: () -> Unit) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val subsGrid by container.settingsStore.subsGrid.collectAsStateWithLifecycle()
    // 订阅 / 最新 / 收藏 / 下载 / 历史。「最新」= 全部订阅的更新聚合,归入音阁。
    val sections = listOf(
        stringResource(R.string.lib_subscriptions),
        stringResource(R.string.nav_inbox),
        stringResource(R.string.lib_favorites),
        stringResource(R.string.lib_downloads),
        stringResource(R.string.lib_history)
    )
    // 分段用 HorizontalPager 承载,可横滑切换;chips 与 pager 双向联动。
    val pagerState = rememberPagerState(pageCount = { sections.size })
    val section = pagerState.currentPage
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.nav_library),
            action = {
                Row {
                    IconButton(onClick = onOpenListenStats) {
                        Icon(Icons.Rounded.BarChart, contentDescription = stringResource(R.string.listen_stats_title), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Rounded.Settings, contentDescription = "设置", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        )

        // 分段玻璃条悬浮在 pager 之上(内容从条下滚过),胶囊随拖动 1:1 平移。
        // 清空历史/排列切换按钮浮在条的右端(不占 chips 流式布局),条的半透明
        // 表面就是它们的衬底 —— 原先自带的 background 填块去掉了。
        Box(Modifier.fillMaxWidth().weight(1f)) {
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize()
            ) { page ->
                when (page) {
                    0 -> SubscriptionsSection(subsGrid, onOpen)
                    1 -> InboxBody(topPad = GLASS_CHIPS_TOP_PAD)
                    2 -> FavoritesSection()
                    3 -> DownloadsSection()
                    else -> HistorySection(history)
                }
            }
            GlassChipsRow(
                modifier = Modifier.align(Alignment.TopCenter),
                labels = sections,
                selected = section,
                progress = { pagerState.currentPage + pagerState.currentPageOffsetFraction },
                onSelect = { i -> scope.launch { pagerState.animateScrollToPage(i) } }
            )
            if (section == 4 && history.isNotEmpty()) {
                TextButton(
                    onClick = { container.historyStore.clear() },
                    // 与 44dp 玻璃条对中:TextButton 高 40dp,top 补 (44-40)/2=2dp。
                    // 原先 top=5dp 让整体偏下(H90 用户反馈「置底」)。
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 2.dp, end = 20.dp)
                        .zIndex(1f)
                ) { Text(stringResource(R.string.action_clear_confirm)) }
            }
            // 订阅分段:右侧「行 / 宫格」排列切换。图标显示切换后的目标布局。
            if (section == 0) {
                IconButton(
                    onClick = { container.settingsStore.setSubsGrid(!subsGrid) },
                    // IconButton 高 48dp 比条高,负 offset 才能真正对中:(44-48)/2=-2dp
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .offset(y = (-2).dp)
                        .padding(end = 8.dp)
                        .zIndex(1f)
                ) {
                    Icon(
                        if (subsGrid) Icons.AutoMirrored.Rounded.ViewList else Icons.Rounded.GridView,
                        contentDescription = stringResource(R.string.subs_layout_toggle),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun SubscriptionsSection(gridLayout: Boolean, onOpen: (Podcast) -> Unit) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()

    if (subs.isEmpty()) {
        EmptyHint(stringResource(R.string.empty_library))
        return
    }

    // 与 macOS 对齐:订阅不再分类,直接平铺;排列方式(列表/宫格)由顶部按钮切换。
    if (gridLayout) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 104.dp),
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = 4.dp + GLASS_CHIPS_TOP_PAD,
                bottom = 24.dp + LocalGlassBottomPad.current
            ),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            items(subs, key = { it.id }) { p -> PodcastGridItem(p) { onOpen(p) } }
        }
    } else {
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                top = GLASS_CHIPS_TOP_PAD,
                bottom = 24.dp + LocalGlassBottomPad.current
            )
        ) {
            items(subs, key = { it.id }) { p -> PodcastListItem(p) { onOpen(p) } }
        }
    }
}

@Composable
private fun FavoritesSection() {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val favorites by container.favoriteStore.favorites.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()

    val history by container.historyStore.history.collectAsStateWithLifecycle()

    if (favorites.isEmpty()) {
        EmptyHint(stringResource(R.string.empty_favorites))
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = GLASS_CHIPS_TOP_PAD,
            bottom = 24.dp + LocalGlassBottomPad.current
        )
    ) {
        items(favorites, key = { it.id }) { ep ->
            val played = history.firstOrNull { it.episode.id == ep.id }?.played ?: false
            EpisodeListItem(
                episode = ep,
                isCurrent = current?.id == ep.id,
                isPlaying = isPlaying,
                onPlay = { PlayerController.playOrToggle(ep, favorites) },
                showPodcastTitle = true,
                isFavorite = true,
                onToggleFavorite = { container.favoriteStore.toggle(ep) },
                played = played,
                onTogglePlayed = { container.historyStore.markPlayed(ep.id, !played) },
                onPlayNext = { PlayerController.playNext(ep) },
                onEnqueue = { PlayerController.enqueue(ep) }
            )
        }
    }
}

@Composable
private fun DownloadsSection() {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val downloads by container.downloadStore.downloads.collectAsStateWithLifecycle()
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    // 删除是不可逆操作，点对号后先弹确认，避免误删
    var pendingDelete by remember { mutableStateOf<DownloadedEpisode?>(null) }

    if (downloads.isEmpty()) {
        EmptyHint(stringResource(R.string.empty_downloads))
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = GLASS_CHIPS_TOP_PAD,
            bottom = 24.dp + LocalGlassBottomPad.current
        )
    ) {
        items(downloads) { d ->
            val played = history.firstOrNull { it.episode.id == d.episode.id }?.played ?: false
            EpisodeListItem(
                episode = d.episode,
                isCurrent = current?.id == d.episode.id,
                isPlaying = isPlaying,
                onPlay = { PlayerController.playOrToggle(d.episode, downloads.map { it.episode }) },
                // 下载同样是跨节目混排,节目名要显示(见历史段注释)
                showPodcastTitle = true,
                downloadStatus = DownloadStatus.Completed,
                onDeleteDownload = { pendingDelete = d },
                played = played,
                onTogglePlayed = { container.historyStore.markPlayed(d.episode.id, !played) },
                onPlayNext = { PlayerController.playNext(d.episode) },
                onEnqueue = { PlayerController.enqueue(d.episode) }
            )
        }
    }

    pendingDelete?.let { d ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.download_delete_title)) },
            text = { Text(stringResource(R.string.download_delete_message, d.episode.title)) },
            confirmButton = {
                TextButton(onClick = {
                    DownloadManager.delete(d.episode.id)
                    pendingDelete = null
                }) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }
}

@Composable
private fun HistorySection(history: List<com.yuyin.reverb.data.model.HistoryEntry>) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()

    if (history.isEmpty()) {
        EmptyHint(stringResource(R.string.empty_history))
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = GLASS_CHIPS_TOP_PAD,
            bottom = 24.dp + LocalGlassBottomPad.current
        )
    ) {
        items(history) { h ->
            EpisodeListItem(
                episode = h.episode,
                isCurrent = current?.id == h.episode.id,
                isPlaying = isPlaying,
                onPlay = { PlayerController.playOrToggle(h.episode, history.map { it.episode }) },
                // 历史是跨节目混排,节目名要显示 —— 与「最新」「收藏」「下载」一致
                // (鸿蒙侧四段都传,Android 这里和下载段此前漏了)
                showPodcastTitle = true,
                played = h.played,
                onTogglePlayed = { container.historyStore.markPlayed(h.episode.id, !h.played) },
                onPlayNext = { PlayerController.playNext(h.episode) },
                onEnqueue = { PlayerController.enqueue(h.episode) }
            )
        }
    }
}
