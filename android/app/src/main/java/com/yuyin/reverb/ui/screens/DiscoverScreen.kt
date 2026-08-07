package com.yuyin.reverb.ui.screens

import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.LightMode
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material.icons.rounded.WbTwilight
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.roundToInt
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.HistoryEntry
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.ui.Category
import com.yuyin.reverb.ui.DiscoverState
import com.yuyin.reverb.ui.DiscoverViewModel
import com.yuyin.reverb.ui.REGION_OPTIONS
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.playback.RadioStation
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.components.PodcastListItem
import com.yuyin.reverb.ui.discoverViewModel
import java.util.Locale
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun DiscoverScreen(onOpen: (Podcast) -> Unit) {
    val vm = discoverViewModel()
    val keyboard = LocalSoftwareKeyboardController.current
    val scope = rememberCoroutineScope()
    val container = (LocalContext.current.applicationContext as ReverbApp).container

    val regionOverride by container.regionStore.override.collectAsStateWithLifecycle()
    val region = remember(regionOverride) {
        (regionOverride ?: Locale.getDefault().country).lowercase().ifBlank { "us" }
    }

    val categories = vm.orderedCategories
    val radioMode by PlayerController.radioMode.collectAsStateWithLifecycle()
    val radioPreparingMode by RadioStation.preparingMode.collectAsStateWithLifecycle()
    val radioKind by RadioStation.mode.collectAsStateWithLifecycle()
    val contextualRadio by container.settingsStore.contextualRadio.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var showReorder by remember { mutableStateOf(false) }
    val browsing = vm.state is DiscoverState.Idle
    val pagerState = rememberPagerState(pageCount = { categories.size })
    val chipsState = rememberLazyListState()

    // 继续收听:进度在 10s..95% 之间且未播完的历史条目,最新在前,最多 15 条
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val inProgress = remember(history) {
        history.filter {
            it.durationMs > 0 &&
                it.positionMs in 10_000..(it.durationMs * 0.95).toLong() &&
                !it.played
        }.take(15)
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.app_name),
            subtitle = stringResource(R.string.slogan),
            action = {
                // 单个电台入口:模式在设置里切换(随机/情境)。短按开台/换下一首;长按显示名称,运行中长按则停止。
                val mode = if (contextualRadio) RadioStation.Mode.CONTEXTUAL else RadioStation.Mode.RANDOM
                val label = stringResource(if (contextualRadio) R.string.radio_contextual else R.string.radio_start)
                val stopped = stringResource(R.string.radio_stopped)
                // 情境模式下图标随时段变化(日出/白日/日落/月亮),随机模式固定为随机图标
                val icon = if (!contextualRadio) Icons.Rounded.Shuffle else contextualRadioIcon()
                RadioActionButton(
                    icon = icon,
                    desc = stringResource(if (radioMode && radioKind == mode) R.string.radio_next else R.string.radio_start),
                    active = radioMode,
                    preparing = radioPreparingMode != null,
                    onShort = {
                        RadioStation.configure(container.repository, region, categories.map { it.genreId })
                        if (radioMode && radioKind == mode) {
                            RadioStation.skip() // 已在同模式电台:下一首
                        } else scope.launch {
                            if (!RadioStation.start(mode)) Toast.makeText(context, R.string.radio_empty, Toast.LENGTH_SHORT).show()
                        }
                    },
                    onLong = {
                        if (radioMode) {
                            RadioStation.stop()
                            Toast.makeText(context, "$label · $stopped", Toast.LENGTH_SHORT).show()
                        } else {
                            Toast.makeText(context, label, Toast.LENGTH_SHORT).show()
                        }
                    }
                )
            }
        )

        OutlinedTextField(
            value = vm.query,
            onValueChange = vm::onQueryChange,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            placeholder = { Text(stringResource(R.string.search_hint)) },
            leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
            trailingIcon = {
                if (vm.query.isNotEmpty()) {
                    IconButton(onClick = {
                        vm.clearQuery()
                        keyboard?.hide()
                    }) {
                        Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.action_clear))
                    }
                }
            },
            singleLine = true,
            shape = RoundedCornerShape(14.dp),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = {
                keyboard?.hide()
                vm.search(region)
            }),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = MaterialTheme.colorScheme.primary,
                unfocusedBorderColor = MaterialTheme.colorScheme.outline,
                cursorColor = MaterialTheme.colorScheme.primary
            )
        )

        if (browsing) {
            val selectedIndex = pagerState.currentPage.coerceIn(0, (categories.size - 1).coerceAtLeast(0))
            // 分类 chips 紧贴搜索框(靠顶),不被继续收听横条挤到屏幕中部
            // 横滑切到屏幕外的分类时，自动把选中标签滚动进可视区
            LaunchedEffect(selectedIndex) {
                chipsState.animateScrollToItem(selectedIndex)
            }
            // 分类 chips（当前页高亮）+ 排序入口
            CategoryChipsRow(
                state = chipsState,
                categories = categories,
                selectedIndex = selectedIndex,
                onSelect = { i -> scope.launch { pagerState.animateScrollToPage(i) } },
                onEdit = { showReorder = true }
            )
            // 横滑左右切换分类:列表占满剩余空间,继续收听横条作为列表首项一起滚动
            HorizontalPager(
                state = pagerState,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
            ) { page ->
                CategoryPage(
                    vm = vm,
                    category = categories[page],
                    region = region,
                    onOpen = onOpen,
                    continueEntries = inProgress
                )
            }
        } else {
            when (val s = vm.state) {
                DiscoverState.Loading -> LoadingBox()
                DiscoverState.Empty -> EmptyHint(stringResource(R.string.load_failed))
                is DiscoverState.Success -> SearchResults(s = s, onOpen = onOpen)
                DiscoverState.Idle -> Unit
            }
        }
    }

    if (showReorder) {
        ReorderCategoriesDialog(
            initial = categories,
            onDismiss = { showReorder = false },
            onSave = {
                vm.saveOrder(it)
                showReorder = false
            }
        )
    }
}

/** 情境电台按钮图标:按当前时段呈现 日出 / 白日 / 日落 / 月亮。 */
private fun contextualRadioIcon(): androidx.compose.ui.graphics.vector.ImageVector {
    val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    return when (hour) {
        in 5..10 -> Icons.Rounded.WbTwilight   // 日出·晨曦
        in 11..16 -> Icons.Rounded.WbSunny      // 白日
        in 17..19 -> Icons.Rounded.WbTwilight   // 日落·黄昏
        else -> Icons.Rounded.DarkMode          // 夜·月
    }
}

/** 电台按钮:关台态灰、在台态高亮,抓取中转圈;短按开台/换台,长按显示名称或停止。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RadioActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    desc: String,
    active: Boolean,
    preparing: Boolean,
    onShort: () -> Unit,
    onLong: () -> Unit
) {
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .combinedClickable(
                enabled = !preparing,
                onClickLabel = desc,
                onClick = onShort,
                onLongClick = onLong
            ),
        contentAlignment = Alignment.Center
    ) {
        if (preparing) {
            CircularProgressIndicator(
                modifier = Modifier.size(22.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.primary
            )
        } else {
            Icon(
                icon,
                contentDescription = desc,
                tint = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CategoryPage(
    vm: DiscoverViewModel,
    category: Category,
    region: String,
    onOpen: (Podcast) -> Unit,
    continueEntries: List<HistoryEntry> = emptyList()
) {
    // 先展示缓存，秒开；再后台刷新，数据回来替换。地区变化时按新地区重载。
    var list by remember(category.key, region) { mutableStateOf(vm.cachedCategory(category, region)) }
    var loading by remember(category.key, region) { mutableStateOf(list.isEmpty()) }
    val pullState = rememberPullToRefreshState()

    LaunchedEffect(category.key, region) {
        val fresh = vm.refreshCategory(category, region)
        if (fresh.isNotEmpty()) list = fresh
        loading = false
    }
    // 下拉刷新：强制重新拉取最新榜单。分类榜单接口很快（~0.4s），加一个最短可见时长，
    // 让每个分类都有可感知的“刷新中”过程，而非一闪而过（finally 兜底，异常也收起）。
    if (pullState.isRefreshing) {
        LaunchedEffect(true) {
            try {
                coroutineScope {
                    val fetch = async { vm.refreshCategory(category, region) }
                    delay(600)
                    val fresh = fetch.await()
                    if (fresh.isNotEmpty()) list = fresh
                }
            } finally {
                pullState.endRefresh()
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .clipToBounds() // 裁掉静止态越界露出的指示器（分类栏下方的白块）
            .nestedScroll(pullState.nestedScrollConnection)
    ) {
        when {
            list.isNotEmpty() -> PodcastResultList(
                header = stringResource(R.string.discover_daily_hot, stringResource(category.labelRes)),
                podcasts = list,
                onOpen = onOpen,
                topContent = if (continueEntries.isNotEmpty()) {
                    { ContinueListeningStrip(continueEntries) }
                } else null
            )
            loading -> LoadingBox()
            else -> EmptyHint(stringResource(R.string.discover_empty_category, stringResource(category.labelRes)))
        }
        // 跟手下拉指示器；静止态越界部分被 clipToBounds 裁掉，不残留
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }
}

@Composable
private fun CategoryChipsRow(
    state: LazyListState,
    categories: List<Category>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    onEdit: () -> Unit
) {
    LazyRow(
        state = state,
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        itemsIndexed(categories) { i, cat ->
            FilterChip(
                selected = i == selectedIndex,
                onClick = { onSelect(i) },
                label = { Text(stringResource(cat.labelRes)) },
                modifier = Modifier.padding(end = 8.dp),
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = MaterialTheme.colorScheme.primary,
                    selectedLabelColor = MaterialTheme.colorScheme.onPrimary
                )
            )
        }
        item {
            IconButton(onClick = onEdit) {
                Icon(
                    Icons.Rounded.Tune,
                    contentDescription = stringResource(R.string.reorder_title),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun ReorderCategoriesDialog(
    initial: List<Category>,
    onDismiss: () -> Unit,
    onSave: (List<Category>) -> Unit
) {
    val items = remember { initial.toMutableStateList() }
    val rowHeight = 48.dp
    val rowPx = with(LocalDensity.current) { rowHeight.toPx() }
    var dragIndex by remember { mutableIntStateOf(-1) }
    var dragOffsetY by remember { mutableFloatStateOf(0f) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.reorder_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    stringResource(R.string.reorder_hint),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 8.dp)
                )
                items.forEachIndexed { index, cat ->
                    key(cat.key) {
                        val dragging = index == dragIndex
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .height(rowHeight)
                                .zIndex(if (dragging) 1f else 0f)
                                .graphicsLayer { translationY = if (dragging) dragOffsetY else 0f }
                                .background(
                                    if (dragging) MaterialTheme.colorScheme.surfaceVariant else Color.Transparent,
                                    RoundedCornerShape(8.dp)
                                )
                                .pointerInput(cat.key) {
                                    detectDragGesturesAfterLongPress(
                                        onDragStart = {
                                        // 按条目身份取当前真实位置，避免重排后闭包 index 过期导致抓错行
                                        dragIndex = items.indexOfFirst { it.key == cat.key }
                                        dragOffsetY = 0f
                                    },
                                        onDragEnd = { dragIndex = -1; dragOffsetY = 0f },
                                        onDragCancel = { dragIndex = -1; dragOffsetY = 0f },
                                        onDrag = { change, drag ->
                                            change.consume()
                                            dragOffsetY += drag.y
                                            val cur = dragIndex
                                            val target = cur + (dragOffsetY / rowPx).roundToInt()
                                            if (cur in items.indices && target in items.indices && target != cur) {
                                                items.add(target, items.removeAt(cur))
                                                dragOffsetY -= (target - cur) * rowPx
                                                dragIndex = target
                                            }
                                        }
                                    )
                                }
                                .padding(horizontal = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                stringResource(cat.labelRes),
                                style = MaterialTheme.typography.bodyLarge,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.weight(1f)
                            )
                            Icon(
                                Icons.Rounded.DragHandle,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(items.toList()) }) { Text(stringResource(R.string.action_done)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } }
    )
}

/** 继续收听:未听完的历史横滑卡片。封面 + 标题(2 行) + 进度条,点按续播。 */
@Composable
private fun ContinueListeningStrip(entries: List<HistoryEntry>) {
    if (entries.isEmpty()) return
    Column {
        Text(
            stringResource(R.string.continue_listening),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 6.dp)
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            items(entries, key = { it.episode.id }) { h ->
                ContinueCard(entry = h, onClick = { PlayerController.play(h.episode) })
            }
        }
    }
}

@Composable
private fun ContinueCard(entry: HistoryEntry, onClick: () -> Unit) {
    val progress = if (entry.durationMs > 0)
        (entry.positionMs.toFloat() / entry.durationMs).coerceIn(0f, 1f) else 0f
    Column(
        Modifier
            .width(132.dp)
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(bottom = 8.dp)
    ) {
        com.yuyin.reverb.ui.components.Artwork(entry.episode.artworkUrl, size = 132, corner = 12)
        Spacer(Modifier.height(6.dp))
        Text(
            entry.episode.title,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 2,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 2.dp)
        )
        Spacer(Modifier.height(6.dp))
        LinearProgressIndicator(
            progress = { progress },
            modifier = Modifier
                .fillMaxWidth()
                .height(3.dp),
            color = MaterialTheme.colorScheme.primary,
            trackColor = MaterialTheme.colorScheme.surfaceVariant
        )
    }
}

/** 搜索结果：单集 / 节目 两个分段。单集点击即播，节目点进详情。 */
@Composable
private fun SearchResults(s: DiscoverState.Success, onOpen: (Podcast) -> Unit) {
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    // 默认停在「单集」；若本次无单集则落到「节目」，避免进来一片空白
    var tab by remember(s) { mutableIntStateOf(if (s.episodes.isNotEmpty()) 0 else 1) }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            SearchTabChip(
                selected = tab == 0,
                text = "${stringResource(R.string.search_tab_episodes)} (${s.episodes.size})",
                onClick = { tab = 0 }
            )
            SearchTabChip(
                selected = tab == 1,
                text = "${stringResource(R.string.search_tab_shows)} (${s.podcasts.size})",
                onClick = { tab = 1 }
            )
        }
        if (tab == 0) {
            if (s.episodes.isEmpty()) {
                EmptyHint(stringResource(R.string.search_empty_episodes))
            } else {
                LazyColumn(
                    Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = 24.dp)
                ) {
                    items(s.episodes) { ep ->
                        val played = history.firstOrNull { it.episode.id == ep.id }?.played ?: false
                        EpisodeListItem(
                            episode = ep,
                            isCurrent = current?.id == ep.id,
                            isPlaying = isPlaying,
                            onPlay = { PlayerController.playOrToggle(ep, s.episodes) },
                            showPodcastTitle = true,
                            played = played,
                            onTogglePlayed = { container.historyStore.markPlayed(ep.id, !played) },
                            onPlayNext = { PlayerController.playNext(ep) },
                            onEnqueue = { PlayerController.enqueue(ep) }
                        )
                    }
                }
            }
        } else {
            if (s.podcasts.isEmpty()) {
                EmptyHint(stringResource(R.string.search_empty_shows))
            } else {
                PodcastResultList(
                    header = stringResource(R.string.discover_source, s.source),
                    podcasts = s.podcasts,
                    onOpen = onOpen
                )
            }
        }
    }
}

@Composable
private fun SearchTabChip(selected: Boolean, text: String, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(text) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = MaterialTheme.colorScheme.primary,
            selectedLabelColor = MaterialTheme.colorScheme.onPrimary
        )
    )
}

@Composable
private fun PodcastResultList(
    header: String,
    podcasts: List<Podcast>,
    onOpen: (Podcast) -> Unit,
    topContent: (@Composable () -> Unit)? = null // 列表首项(如“继续收听”横条),随列表一起滚动
) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 24.dp)
    ) {
        if (topContent != null) {
            item { topContent() }
        }
        item {
            Text(
                header,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 4.dp)
            )
        }
        items(podcasts) { p ->
            PodcastListItem(p) { onOpen(p) }
        }
    }
}
