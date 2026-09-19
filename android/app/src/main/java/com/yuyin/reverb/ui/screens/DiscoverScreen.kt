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
import androidx.compose.foundation.lazy.items
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
import androidx.compose.material.icons.rounded.PlayCircleOutline
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
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.roundToInt
import com.yuyin.reverb.R
import android.content.Context
import androidx.compose.material3.Button
import com.yuyin.reverb.AppContainer
import com.yuyin.reverb.data.remote.OpmlSupport
import com.yuyin.reverb.BuildConfig
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.HistoryEntry
import com.yuyin.reverb.data.model.GuideEpisode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.ui.Category
import com.yuyin.reverb.ui.DiscoverState
import com.yuyin.reverb.ui.DiscoverViewModel
import com.yuyin.reverb.ui.REGION_OPTIONS
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.playback.RadioStation
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.components.GLASS_CHIPS_TOP_PAD
import com.yuyin.reverb.ui.components.GlassChipsRow
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.PillChip
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

    // 继续收听:进度在 10s..95% 之间且未播完的历史条目,最新在前,最多 15 条
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val inProgress = remember(history) {
        history.filter {
            it.durationMs > 0 &&
                it.positionMs in 10_000..(it.durationMs * 0.95).toLong() &&
                !it.played
        }.take(15)
    }

    // 全新用户(既没订阅也没听过任何东西)才展示内置引导音频入口。
    // 一旦有任何使用痕迹就不再出现 —— 它是引导,不是常驻功能。
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    val firstRun = subs.isEmpty() && history.isEmpty()

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.app_name),
            subtitle = stringResource(R.string.slogan),
            action = {
                // 电台受内容目录开关门控;若合规要求降级为纯 RSS 工具,会随 CATALOG 一起隐藏。
                if (BuildConfig.CATALOG) {
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
            }
        )

        OutlinedTextField(
            value = vm.query,
            onValueChange = vm::onQueryChange,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            placeholder = {
                Text(stringResource(if (BuildConfig.CATALOG) R.string.search_hint else R.string.search_hint_url))
            },
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
                // 无内容目录的渠道**不做关键词检索** —— 关键词返回的是节目列表,同样构成动态目录。
                // 只接受 http(s) 的 RSS 地址;输入别的就提示一句,不发请求。
                val q = vm.query.trim()
                if (!BuildConfig.CATALOG && !q.startsWith("http://", true) && !q.startsWith("https://", true)) {
                    if (q.isNotEmpty()) Toast.makeText(context, R.string.search_url_only, Toast.LENGTH_SHORT).show()
                } else {
                    vm.search(region)
                }
            }),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = MaterialTheme.colorScheme.primary,
                unfocusedBorderColor = MaterialTheme.colorScheme.outline,
                cursorColor = MaterialTheme.colorScheme.primary
            )
        )

        if (browsing && !BuildConfig.CATALOG) {
            // 无内容目录的渠道:首屏就是「导入推荐订阅」+ 继续收听 + 引导卡,
            // 不出现任何可浏览的节目目录(分类榜 / 电台 / 内置清单一律没有)。
            SubscribeStarter(
                continueEntries = inProgress,
                showGuide = firstRun
            )
        } else if (browsing) {
            val selectedIndex = pagerState.currentPage.coerceIn(0, (categories.size - 1).coerceAtLeast(0))
            // 分类玻璃条悬浮在 pager 之上(内容从条下滚过,玻璃才有得"透");胶囊随拖动
            // 1:1 平移、选中项滚进可视区都收在 GlassChipsRow 内部 —— 外部不再需要
            // chipsState 与 reveal 的 LaunchedEffect
            Box(Modifier.fillMaxWidth().weight(1f)) {
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize()
                ) { page ->
                    CategoryPage(
                        vm = vm,
                        category = categories[page],
                        region = region,
                        onOpen = onOpen,
                        continueEntries = inProgress,
                        showGuide = firstRun,
                        topPad = GLASS_CHIPS_TOP_PAD
                    )
                }
                GlassChipsRow(
                    modifier = Modifier.align(Alignment.TopCenter),
                    labels = categories.map { stringResource(it.labelRes) },
                    selected = selectedIndex,
                    progress = { pagerState.currentPage + pagerState.currentPageOffsetFraction },
                    onSelect = { i -> scope.launch { pagerState.animateScrollToPage(i) } },
                    trailing = {
                        IconButton(onClick = { showReorder = true }) {
                            Icon(
                                Icons.Rounded.Tune,
                                contentDescription = stringResource(R.string.reorder_title),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
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
    continueEntries: List<HistoryEntry> = emptyList(),
    showGuide: Boolean = false,
    // 悬浮分类玻璃条占掉的高度:列表要能从条下滚过,首项又要从条下露出,全靠这个让位
    topPad: androidx.compose.ui.unit.Dp = androidx.compose.ui.unit.Dp.Unspecified
) {
    // 先展示缓存（无缓存则用随包内置清单），秒开；再后台刷新，数据回来替换。地区变化时按新地区重载。
    var list by remember(category.key, region) { mutableStateOf(vm.cachedCategory(category, region)) }
    // isSeed 决定标题是「每日热门」还是「内置精选」：内置清单是打包时的榜单快照，不是今天的榜，
    // 标成每日热门会误导。联网刷新成功后置为 false。
    var isSeed by remember(category.key, region) { mutableStateOf(vm.isSeedCategory(category, region)) }
    var loading by remember(category.key, region) { mutableStateOf(list.isEmpty()) }
    val pullState = rememberPullToRefreshState()

    LaunchedEffect(category.key, region) {
        val fresh = vm.refreshCategory(category, region)
        if (fresh.isNotEmpty()) { list = fresh; isSeed = false }
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
                    if (fresh.isNotEmpty()) { list = fresh; isSeed = false }
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
                header = stringResource(
                    if (isSeed) R.string.discover_seed_list else R.string.discover_daily_hot,
                    stringResource(category.labelRes)
                ),
                podcasts = list,
                onOpen = onOpen,
                topPad = topPad,
                topContent = when {
                    continueEntries.isNotEmpty() -> { { ContinueListeningStrip(continueEntries) } }
                    showGuide -> { { GuideCard() } }
                    else -> null
                }
            )
            loading -> LoadingBox()
            else -> EmptyHint(stringResource(R.string.discover_empty_category, stringResource(category.labelRes)))
        }
        // 跟手下拉指示器;静止态越界部分被 clipToBounds 裁掉,不残留。
        // 下移躲开悬浮的玻璃分类条,否则转圈被玻璃罩着看不清。
        PullToRefreshContainer(
            state = pullState,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = topPad)
        )
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

/**
 * `CATALOG=false` 时的纯 RSS 首屏,**按有没有订阅分成两种布局**。
 *
 * 这条降级路径为合规要求纯 RSS 工具时保留:推荐清单是一份挂在官网的 OPML,
 * 点一下**整份导入**,不做“列出来让你挑”的中间页 —— 那等于把目录又搬回应用。
 *
 * 为什么按订阅数分叉:原先不论有 0 个还是几十个订阅,首屏都顶着一大块
 * 「从添加订阅开始 + 导入推荐订阅」。那是给零订阅新用户看的引导,已有一堆订阅的人
 * 每次打开先看它很怪,而且首屏没有任何“我的订阅有什么新的”——那恰恰是播客应用首屏最该有的。
 *
 * 「最新更新」直接用已有的 InboxStore,与「音阁 · 最新」是同一份数据、两个入口:
 * 首屏看新内容,音阁做管理。
 */
@Composable
private fun SubscribeStarter(
    continueEntries: List<HistoryEntry>,
    showGuide: Boolean
) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()

    if (subs.isEmpty()) StarterOnboarding(continueEntries, showGuide)
    else HomeFeed(continueEntries)
}

/** 零订阅时的引导：说明 + 通栏导入按钮 + 内置引导音频卡。 */
@Composable
private fun StarterOnboarding(
    continueEntries: List<HistoryEntry>,
    showGuide: Boolean
) {
    val context = LocalContext.current
    val container = (context.applicationContext as ReverbApp).container
    val scope = rememberCoroutineScope()
    var importing by remember { mutableStateOf(false) }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 24.dp + LocalGlassBottomPad.current)
    ) {
        item {
            Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
                Text(
                    stringResource(R.string.starter_title),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Medium
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    stringResource(R.string.starter_desc),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(14.dp))
                Button(
                    onClick = {
                        if (importing) return@Button
                        importing = true
                        scope.launch {
                            val n = importRecommended(context, container)
                            importing = false
                            Toast.makeText(context, importMessage(context, n), Toast.LENGTH_SHORT).show()
                        }
                    },
                    enabled = !importing,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    if (importing) {
                        CircularProgressIndicator(
                            Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(stringResource(R.string.importing))
                    } else {
                        Text(stringResource(R.string.import_recommended))
                    }
                }
            }
        }
        if (showGuide) item { GuideCard() }
        if (continueEntries.isNotEmpty()) item { ContinueListeningStrip(continueEntries) }
    }
}

/**
 * 有订阅时的首屏：继续收听 + 最新更新 + 底部一行不显眼的导入入口。
 *
 * 整屏是**一个 LazyColumn**（继续收听横条与底部入口都是列表项），不做"固定头 + 可滚列表"
 * —— 那会在小屏上把最新更新压成一条缝。
 *
 * 刷新与「音阁 · 最新」共用 InboxStore：进页 LaunchedEffect(subs) 触发一次，
 * InboxStore 自带防重入，两处同时进入不会重复抓。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeFeed(continueEntries: List<HistoryEntry>) {
    val context = LocalContext.current
    val container = (context.applicationContext as ReverbApp).container
    val scope = rememberCoroutineScope()
    var importing by remember { mutableStateOf(false) }

    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    val episodes by container.inboxStore.episodes.collectAsStateWithLifecycle()
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val pullState = rememberPullToRefreshState()

    // 首刷标记：仅在「有订阅但缓存为空」时显示有界的转圈，刷新结束（成功/失败）即收起，
    // 避免无内容时无限转圈。与 InboxBody 同一策略。
    var firstLoading by remember { mutableStateOf(episodes.isEmpty()) }
    LaunchedEffect(subs) {
        if (subs.isNotEmpty() && episodes.isEmpty()) firstLoading = true
        try {
            container.inboxStore.refresh(subs, container.repository)
        } finally {
            firstLoading = false
        }
    }
    // 下拉刷新：多源刷新可能耗时数秒，不 await 到完成（否则指示器挂很久），
    // 丢到后台跑、指示器只短暂示意。理由同 InboxBody。
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
            .clipToBounds() // 裁掉静止态越界露出的指示器（圆圈常驻的根因）
            .nestedScroll(pullState.nestedScrollConnection)
    ) {
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 24.dp + LocalGlassBottomPad.current)
        ) {
            if (continueEntries.isNotEmpty()) item { ContinueListeningStrip(continueEntries) }
            item {
                Text(
                    stringResource(R.string.home_latest),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(start = 16.dp, top = 4.dp, bottom = 6.dp)
                )
            }
            if (episodes.isNotEmpty()) {
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
            } else item {
                if (firstLoading) LoadingBox()
                else EmptyHint(stringResource(R.string.inbox_empty_no_updates))
            }
            item {
                // 底部导入入口：刻意是文字按钮而非通栏大按钮 —— 对已有订阅的人，
                // 这是个偶尔才用一次的东西。
                Column(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    HorizontalDivider(
                        Modifier.padding(bottom = 4.dp),
                        color = MaterialTheme.colorScheme.outline.copy(alpha = 0.6f)
                    )
                    TextButton(
                        onClick = {
                            if (importing) return@TextButton
                            importing = true
                            scope.launch {
                                val n = importRecommended(context, container)
                                importing = false
                                Toast.makeText(context, importMessage(context, n), Toast.LENGTH_SHORT).show()
                                // 订阅集变了，「最新」要跟着重聚合 —— 否则刚导入完首屏还是旧的，
                                // 得等用户去一趟音阁才刷。
                                if (n > 0) {
                                    container.inboxStore.refresh(
                                        container.subscriptionStore.subscriptions.value,
                                        container.repository
                                    )
                                }
                            }
                        },
                        enabled = !importing
                    ) {
                        Text(stringResource(if (importing) R.string.importing else R.string.import_recommended))
                    }
                    Text(
                        stringResource(R.string.starter_have_subs, subs.size),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }
}

/** 导入结果的提示文案（成功条数 / 清单为空 / 失败）。两处入口共用。 */
private fun importMessage(context: Context, n: Int): String = when {
    n > 0 -> context.getString(R.string.import_done, n)
    n == 0 -> context.getString(R.string.import_none)
    else -> context.getString(R.string.import_failed)
}

/**
 * 拉官网那份推荐 OPML 并整份订阅。返回订阅成功的条数；网络/解析失败返回 -1。
 *
 * 逐个解析 RSS 是为了拿到完整的频道信息（封面 / 作者 / 简介）——OPML 里只有标题与地址，
 * 少了封面订阅列表会是一排占位图。15 条量级顺序请求，配合按钮上的转圈可以接受。
 * 与设置页的 importOpml 是同一套流程，只是来源从本地文件换成官网 URL。
 */
private suspend fun importRecommended(context: Context, container: AppContainer): Int {
    val url = context.getString(R.string.recommended_opml_url)
    val text = container.repository.httpText(url) ?: return -1
    val urls = OpmlSupport.extractFeedUrls(text)
    if (urls.isEmpty()) return -1
    val podcasts = ArrayList<Podcast>()
    for (u in urls) {
        val fr = runCatching { container.repository.feed(u) }.getOrNull()
        if (fr != null) podcasts.add(fr.podcast)
    }
    if (podcasts.isNotEmpty()) container.subscriptionStore.addAll(podcasts)
    com.yuyin.reverb.util.Logger.i("Starter", "导入推荐订阅 ${podcasts.size}/${urls.size}")
    return podcasts.size
}

/**
 * 首次使用时的引导卡：点一下播放随包内置的 30 秒音频。
 *
 * 存在意义是让「全新安装 + 没网」也能走通完整播放链路（播放条/进度/倍速/后台/锁屏），
 * 而不是对着一片空白猜是 App 坏了还是网不通。有任何订阅或收听记录后即不再出现。
 */
@Composable
private fun GuideCard() {
    val context = LocalContext.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.08f))
            .clickable { PlayerController.play(GuideEpisode.get(context)) }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            Icons.Rounded.PlayCircleOutline,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                stringResource(R.string.guide_title),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium
            )
            Text(
                stringResource(R.string.guide_card_sub),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
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
                    contentPadding = PaddingValues(bottom = 24.dp + LocalGlassBottomPad.current)
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
    PillChip(selected = selected, text = text, onClick = onClick)
}

@Composable
private fun PodcastResultList(
    header: String,
    podcasts: List<Podcast>,
    onOpen: (Podcast) -> Unit,
    topContent: (@Composable () -> Unit)? = null, // 列表首项(如“继续收听”横条),随列表一起滚动
    // 悬浮分类玻璃条的让位:列表视口从条下开始,首项要滚出条上方
    topPad: androidx.compose.ui.unit.Dp = androidx.compose.ui.unit.Dp(0f)
) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = topPad,
            bottom = 24.dp + LocalGlassBottomPad.current
        )
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
