package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ViewList
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
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
import com.yuyin.reverb.ui.components.PodcastGridItem
import com.yuyin.reverb.ui.components.PodcastListItem
import kotlinx.coroutines.launch

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(onOpen: (Podcast) -> Unit, onOpenSettings: () -> Unit) {
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
                IconButton(onClick = onOpenSettings) {
                    Icon(Icons.Rounded.Settings, contentDescription = "设置", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        )

        // 分段切换栏。清空历史按钮浮在同一行右侧（zIndex 更高、不占 chips 流式布局），
        // 这样以后要在右侧再加按钮也不会影响左侧 chips 排布。
        Box(Modifier.fillMaxWidth()) {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
                itemsIndexed(sections) { i, s ->
                    FilterChip(
                        selected = section == i,
                        onClick = { scope.launch { pagerState.animateScrollToPage(i) } },
                        label = { Text(s) },
                        modifier = Modifier.padding(end = 8.dp),
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primary,
                            selectedLabelColor = MaterialTheme.colorScheme.onPrimary
                        )
                    )
                }
            }
            if (section == 4 && history.isNotEmpty()) {
                TextButton(
                    onClick = { container.historyStore.clear() },
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .zIndex(1f)
                        .background(MaterialTheme.colorScheme.background)
                ) { Text(stringResource(R.string.action_clear_confirm)) }
            }
            // 订阅分段:右侧「行 / 宫格」排列切换。图标显示切换后的目标布局。
            if (section == 0) {
                IconButton(
                    onClick = { container.settingsStore.setSubsGrid(!subsGrid) },
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .zIndex(1f)
                        .background(MaterialTheme.colorScheme.background)
                ) {
                    Icon(
                        if (subsGrid) Icons.AutoMirrored.Rounded.ViewList else Icons.Rounded.GridView,
                        contentDescription = stringResource(R.string.subs_layout_toggle),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxWidth().weight(1f)
        ) { page ->
            when (page) {
                0 -> SubscriptionsSection(subsGrid, onOpen)
                1 -> InboxBody()
                2 -> FavoritesSection()
                3 -> DownloadsSection()
                else -> HistorySection(history)
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
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            items(subs, key = { it.id }) { p -> PodcastGridItem(p) { onOpen(p) } }
        }
    } else {
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 24.dp)
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
        contentPadding = PaddingValues(bottom = 24.dp)
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
        contentPadding = PaddingValues(bottom = 24.dp)
    ) {
        items(downloads) { d ->
            val played = history.firstOrNull { it.episode.id == d.episode.id }?.played ?: false
            EpisodeListItem(
                episode = d.episode,
                isCurrent = current?.id == d.episode.id,
                isPlaying = isPlaying,
                onPlay = { PlayerController.playOrToggle(d.episode, downloads.map { it.episode }) },
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
        contentPadding = PaddingValues(bottom = 24.dp)
    ) {
        items(history) { h ->
            EpisodeListItem(
                episode = h.episode,
                isCurrent = current?.id == h.episode.id,
                isPlaying = isPlaying,
                onPlay = { PlayerController.playOrToggle(h.episode, history.map { it.episode }) },
                played = h.played,
                onTogglePlayed = { container.historyStore.markPlayed(h.episode.id, !h.played) },
                onPlayNext = { PlayerController.playNext(h.episode) },
                onEnqueue = { PlayerController.enqueue(h.episode) }
            )
        }
    }
}
