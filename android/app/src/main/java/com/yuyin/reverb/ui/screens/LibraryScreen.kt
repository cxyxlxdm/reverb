package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ViewList
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.local.EpisodeNote
import com.yuyin.reverb.data.model.DownloadStatus
import com.yuyin.reverb.data.model.DownloadedEpisode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.components.GLASS_CHIPS_TOP_PAD
import com.yuyin.reverb.ui.components.GlassChipsRow
import com.yuyin.reverb.ui.components.PlayModeButton
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.PodcastGridItem
import com.yuyin.reverb.ui.components.PodcastListItem
import com.yuyin.reverb.ui.components.formatTime
import kotlinx.coroutines.launch

/**
 * 音阁各段的「列身份」。同一个串用在**两处**:段条右端那颗模式按钮按它读写自己那一格,
 * 段内某一行起播时把它随 `playQueue` 传下去(装机日志里 `tag='…'` 读到的就是它)。
 * 两边必须是同一个值 —— 否则「在这一列设的模式」和「这一列起播时用的模式」各走各的,
 * 而且不会报错,只会表现成"设了没生效"。
 *
 * 频道主页用的是 `"podcast:" + (feedUrl 或频道名)`,那个前缀保证它撞不上这些。
 *
 * 「最新」那一列的 `TAG_INBOX` 不在这里:2026-10-08 它提升成顶层「追更」页,串跟着
 * 搬到 `InboxScreen.kt`。**值一个字母没改** —— 模式是按这个串存盘的,改值会让用户
 * 设备上已设的那一格静默失效。
 */
const val TAG_FAV = "fav"
const val TAG_DL = "dl"

/**
 * 音阁六段的**页号**。段条右端那颗动作和 `when (page)` 都用它,不用裸数字。
 *
 * 为什么不写裸数字(见 H164 / H165):这两处是**按序号**挂的,而序号会随增删段变化 ——
 * 「最新」提升成顶层页那次,若只改 sections 列表不改判断,历史段就会挂上待播的动作。
 * 具名常量把契约写在名字上:**加一段时改的是这一组数,漏改会编译期对不上名字**;
 * 值本身仍是那六个数(顺序与鸿蒙 `LibraryPage` 同,用户肌肉记忆也挂在这儿)。
 */
private const val SEG_SUBS = 0
private const val SEG_FAV = 1
private const val SEG_DL = 2
private const val SEG_QUEUE = 3
private const val SEG_HISTORY = 4
private const val SEG_NOTES = 5

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(onOpen: (Podcast) -> Unit, onOpenSettings: () -> Unit, onOpenListenStats: () -> Unit) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val subsGrid by container.settingsStore.subsGrid.collectAsStateWithLifecycle()
    // 订阅分段右端那颗「行 / 宫格」切换要按**有没有内容**决定摆不摆,
    // 所以这份数据在**栏这一层**也要读一遍(订阅页自己还会再 collect 同一个 flow ——
    // StateFlow 的订阅很轻,且这个列表只在进页刷新时整体替换,不会逐帧变)。
    // 收藏 / 下载两份**不在这里读了**:段尾那颗现在只有播放模式,与列空不空无关。
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    // 待播段右端那颗「清空」同样要按有没有内容决定摆不摆,所以队列也在栏这一层读一份
    // (`userQueue` 是 StateFlow,只在用户排队/移除时整体替换,不会逐帧变)。
    val queue by PlayerController.userQueue.collectAsStateWithLifecycle()
    // 分段用 HorizontalPager 承载,可横滑切换;chips 与 pager 双向联动。
    // 订阅 / 收藏 / 下载 / 待播 / 历史 / 批注。
    // 「最新」不在这份列表里了:2026-10-08 它提升成底部第三格「追更」(见 `FeedScreen`),
    // 音阁这一层同时放进「待播」。页号因此是**净不移位** —— 删掉 1 号段把后面全往前顶一位,
    // 又把待播插在历史之前把它们顶回来,所以 4=历史、5=批注 和改之前一样。
    val sections = listOf(
        stringResource(R.string.lib_subscriptions),
        stringResource(R.string.lib_favorites),
        stringResource(R.string.lib_downloads),
        stringResource(R.string.lib_queue),
        stringResource(R.string.lib_history),
        stringResource(R.string.lib_notes)
    )
    val pagerState = rememberPagerState(pageCount = { sections.size })
    val section = pagerState.currentPage
    val scope = rememberCoroutineScope()
    // 待确认的「清空哪一段」(-1 = 没有)。段尾那两颗清空按钮只写这个数,确认框在这儿统一弹,
    // 于是「历史」与「待播」两条清空路径共用同一个形状(与队列页那颗也一致)。
    var pendingClear by remember { mutableIntStateOf(-1) }

    if (pendingClear == SEG_QUEUE || pendingClear == SEG_HISTORY) {
        val isHistory = pendingClear == SEG_HISTORY
        AlertDialog(
            onDismissRequest = { pendingClear = -1 },
            title = {
                Text(stringResource(
                    if (isHistory) R.string.set_clear_history else R.string.queue_title
                ))
            },
            text = {
                Text(stringResource(
                    if (isHistory) R.string.confirm_clear_history else R.string.confirm_clear_queue
                ))
            },
            confirmButton = {
                TextButton(onClick = {
                    if (isHistory) container.historyStore.clear() else PlayerController.clearQueue()
                    pendingClear = -1
                }) { Text(stringResource(R.string.action_clear_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingClear = -1 }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.nav_library),
            action = {
                Row {
                    IconButton(onClick = onOpenListenStats) {
                        Icon(Icons.Rounded.BarChart, contentDescription = stringResource(R.string.listen_stats_title), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Rounded.Settings, contentDescription = stringResource(R.string.a11y_settings), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        )

        // 分段玻璃条悬浮在 pager 之上(内容从条下滚过),胶囊随拖动 1:1 平移。
        // 段尾动作浮在条的右端(不占 chips 流式布局),条的半透明表面就是它们的衬底
        // —— 原先自带的 background 填块去掉了。
        Box(Modifier.fillMaxWidth().weight(1f)) {
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize()
            ) { page ->
                when (page) {
                    SEG_SUBS -> SubscriptionsSection(subsGrid, onOpen)
                    SEG_FAV -> FavoritesSection()
                    SEG_DL -> DownloadsSection()
                    // 待播段就是 `PlayerController.userQueue` 本体 —— 与独立队列页同源,
                    // 不是另一份列表。复用 `QueueBody`(独立页标题栏以下的那一段)。
                    SEG_QUEUE -> QueueBody(topPad = GLASS_CHIPS_TOP_PAD)
                    // 从这里开始**必须写显式页号**:原来是 `else -> HistorySection`,
                    // 加第 6 段时若不拆开,历史会被挤到批注段的位置上(点了历史看到批注)。
                    SEG_HISTORY -> HistorySection(history)
                    SEG_NOTES -> NotesSection()
                }
            }
            GlassChipsRow(
                modifier = Modifier.align(Alignment.TopCenter),
                labels = sections,
                selected = section,
                progress = { pagerState.currentPage + pagerState.currentPageOffsetFraction },
                onSelect = { i -> scope.launch { pagerState.animateScrollToPage(i) } },
                // 段尾动作:**交给条自己摆**(条内右端 + 垂直居中)。
                // 之前是浮在条外面的一个 TopEnd 覆盖层,靠 `top=2dp` / `offset=-2dp`
                // 两个手工数把它凑到 44dp 条的中线上 —— 按钮高度或条高一动就错位,
                // 而且那颗按钮自带一块实底,压在玻璃条上像贴了块补丁。
                //
                // 前五段各有一颗自己的动作(有内容时),所以条改回通栏之后右端基本不是死区
                // (条宽固定的理由见 Components.kt `GlassChipsRow`)。
                // 规则:**这一段没内容就不摆动作** —— 空列表上的"清空/排列"点了
                // 什么都不会发生,是个假按钮。**唯一的例外是播放模式那颗**:它改的是
                // 这一列的模式设置,列空着照样能设(下次有内容时起播就按它走)。
                //
                // 第 6 段(批注)**刻意没有动作**:
                //  · 不放播放模式按钮 —— 点一条批注走 `PlayerController.playAt`,队列里只有
                //    它那**一集**(批注是跨集的散点,把整列拼成队列会让「下一集」跳出用户点的那条),
                //    既然不参与队列播放,模式对这列就没有意义;
                //  · 也不放「清空」—— 批注是用户自己写的字,一键清光没有回旋余地
                //    (`NoteStore` 也没有 clear),要删只能逐条删。
                endAction = {
                    // 两段单集列表(收藏 / 下载):一颗**本列的播放模式按钮**。
                    // 三态图标与点击口径收在 `Components.kt PlayModeButton`
                    // (频道主页「共 N 集」那一行与顶层「追更」页用的都是同一颗)。
                    // 两段各有一份模式,所以这里传的是**这一段自己的** tag —— 两段看到两个值。
                    if (section == SEG_FAV || section == SEG_DL) PlayModeButton(
                        if (section == SEG_FAV) TAG_FAV else TAG_DL
                    )
                    // 待播段**刻意不挂模式按钮**:这一列就是 `PlayerController.userQueue` 本体,
                    // 起播走 `playFromQueue`,模式(顺序/单曲循环/随机)在播放器那一层已经生效。
                    // 给它挂一颗,它改的是"另一列的设置"而那一列就是它自己 —— 只是多一个能设错的地方。
                    //
                    // 两颗「清空」现在都**不直接动手**,只记下要清哪一段:一刀切且没有找回办法,
                    // 与设置页里「清空播放历史」同待遇(那边一直是先确认再清)。
                    if (section == SEG_QUEUE && queue.isNotEmpty()) {
                        TextButton(
                            onClick = { pendingClear = SEG_QUEUE },
                            contentPadding = PaddingValues(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)
                        ) { Text(stringResource(R.string.action_clear_confirm)) }
                    }
                    if (section == SEG_HISTORY && history.isNotEmpty()) {
                        TextButton(
                            onClick = { pendingClear = SEG_HISTORY },
                            // start 16dp:与左边正在横滚的 chips 留出可见的缝(装机反馈
                            // 「间距再大一些」);end 8dp + 容器那 8dp ⇒ 文字离条的右圆顶 16dp。
                            // 鸿蒙 `LibraryPage.barActions()` 的 padding 是同一组数,改要两端一起改。
                            contentPadding = PaddingValues(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)
                        ) { Text(stringResource(R.string.action_clear_confirm)) }
                    }
                    // 订阅分段:右侧「行 / 宫格」排列切换。图标显示切换后的目标布局。
                    //
                    // ⚠️ **不看订阅数**(鸿蒙 `LibraryPage.barActions()` 同一条,那边还留着实测记录):
                    // 排列方式是**全局设置**,列表空着也能设,下次进来看得到;加上 `isNotEmpty()`
                    // 就成了「一台没订阅的手机两边行为立刻不一样」+ 用户反馈的「右侧没有排序按钮」。
                    if (section == SEG_SUBS) {
                        IconButton(onClick = { container.settingsStore.setSubsGrid(!subsGrid) }) {
                            Icon(
                                if (subsGrid) Icons.AutoMirrored.Rounded.ViewList else Icons.Rounded.GridView,
                                contentDescription = stringResource(R.string.subs_layout_toggle),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            )
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
    // 存储里就是「最新收藏在前」(`FavoriteStore.toggle` 用 add(0, …)),显示不再翻。
    // 行内点某一集起播时,整列 favorites 会成为播放队列 —— 显示顺序与队列顺序必须是同一份。
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
                // 队列跟着屏幕上的顺序走
                onPlay = { PlayerController.playOrToggle(ep, favorites, TAG_FAV) },
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
    // 与收藏段同理:存储顺序即「最新下载在前」,显示不再翻。
    // 行内点某一集起播时,整列 `downloads.map { it.episode }` 会成为播放队列 —— 顺序必须是同一份。
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
                onPlay = { PlayerController.playOrToggle(d.episode, downloads.map { it.episode }, TAG_DL) },
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

/**
 * 批注段:**跨集的一句话时间线**,按写的先后倒序(新写的置顶,`NoteStore.add` 用 add(0, …))。
 *
 * 与另五段最大的不同是**点一行不是「播这一列」**:批注散落在几十档节目里,
 * 把整列拼成播放队列等于"点第 3 条之后,下一首是另一档节目的某一句",那不是任何人想要的顺序。
 * 所以走 [PlayerController.playAt] —— 队列只放被点的那一集,起点是**那条批注的那一秒**
 * (不是上次听到的位置;这条区别为什么必须存在见 `PlayerController.playAt` 的注释)。
 */
@Composable
private fun NotesSection() {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val notes by container.noteStore.notes.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    var pendingDelete by remember { mutableStateOf<EpisodeNote?>(null) }

    if (notes.isEmpty()) {
        EmptyHint(stringResource(R.string.note_empty))
        return
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = GLASS_CHIPS_TOP_PAD,
            bottom = 24.dp + LocalGlassBottomPad.current
        )
    ) {
        items(notes, key = { it.id }) { n ->
            NoteRowItem(
                note = n,
                isCurrent = current?.id == n.episode.id,
                isPlaying = isPlaying,
                onPlay = { PlayerController.playAt(n.episode, n.positionMs) },
                onDelete = { pendingDelete = n }
            )
        }
    }

    // 二次确认,且**正文里带上被删的那句话**(与删除下载同一口径,见 #41)。
    // 批注是用户自己写的字,删掉没有任何东西能补回来(零后端、没有回收站),
    // 而确认框里只写"确定删除?"时,误删往往要过几天才发现,那时已经无从恢复。
    pendingDelete?.let { n ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.note_delete_title)) },
            text = { Text(stringResource(R.string.note_delete_message, n.text)) },
            confirmButton = {
                TextButton(onClick = {
                    container.noteStore.remove(n.id)
                    pendingDelete = null
                }) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }
}

/**
 * 一行批注。沿用 [EpisodeListItem] 的行视觉语言(封面 52dp → 14dp 缝 → 双行文本列 → 尾部动作),
 * 换掉的只有主次:**主行是自己写的那句话**,次行才是「哪一秒 · 哪一集」——
 * 这一列的主角是批注,那一集只是它的出处。
 */
@Composable
private fun NoteRowItem(
    note: EpisodeNote,
    isCurrent: Boolean,
    isPlaying: Boolean,
    onPlay: () -> Unit,
    onDelete: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onPlay)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(52.dp), contentAlignment = Alignment.Center) {
            Artwork(note.episode.artworkUrl, size = 52, corner = 10)
            Box(
                Modifier
                    .matchParentSize()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Color.Black.copy(alpha = if (isCurrent) 0.42f else 0.28f))
            )
            Icon(
                if (isCurrent && isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = stringResource(if (isCurrent && isPlaying) R.string.a11y_pause else R.string.a11y_play),
                tint = Color.White,
                modifier = Modifier.size(24.dp)
            )
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                note.text,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onBackground,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 「那一秒」做成小徽标而不是纯文字:它是这一行的**入口信息**
                // (点开就跳到这里),而不只是元数据。底色用 primary 的 12% 透明,
                // 与 PlayCircle / 各处的强调底同一路(见 Components.kt)。
                Box(
                    Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f))
                        .padding(horizontal = 6.dp, vertical = 2.dp)
                ) {
                    Text(
                        formatTime(note.positionMs),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
                Spacer(Modifier.width(8.dp))
                Text(
                    note.episode.title,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
            }
        }
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Rounded.DeleteOutline,
                contentDescription = stringResource(R.string.a11y_note_delete),
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
