package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
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
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.ui.Category
import com.yuyin.reverb.ui.DiscoverState
import com.yuyin.reverb.ui.DiscoverViewModel
import com.yuyin.reverb.ui.REGION_OPTIONS
import com.yuyin.reverb.ui.components.PodcastListItem
import com.yuyin.reverb.ui.discoverViewModel
import java.util.Locale
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
    var showReorder by remember { mutableStateOf(false) }
    val browsing = vm.state is DiscoverState.Idle
    val pagerState = rememberPagerState(pageCount = { categories.size })
    val chipsState = rememberLazyListState()

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.app_name),
            subtitle = stringResource(R.string.slogan)
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
                onEdit = { showReorder = true },
                regionOverride = regionOverride,
                onPickRegion = { container.regionStore.setOverride(it) }
            )
            // 横滑左右切换分类
            HorizontalPager(
                state = pagerState,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
            ) { page ->
                CategoryPage(vm = vm, category = categories[page], region = region, onOpen = onOpen)
            }
        } else {
            when (val s = vm.state) {
                DiscoverState.Loading -> LoadingBox()
                DiscoverState.Empty -> EmptyHint(stringResource(R.string.load_failed))
                is DiscoverState.Success -> PodcastResultList(
                    header = stringResource(R.string.discover_source, s.source),
                    podcasts = s.podcasts,
                    onOpen = onOpen
                )
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

@Composable
private fun CategoryPage(vm: DiscoverViewModel, category: Category, region: String, onOpen: (Podcast) -> Unit) {
    // 先展示缓存，秒开；再后台刷新，数据回来替换。地区变化时按新地区重载。
    var list by remember(category.key, region) { mutableStateOf(vm.cachedCategory(category, region)) }
    var loading by remember(category.key, region) { mutableStateOf(list.isEmpty()) }
    LaunchedEffect(category.key, region) {
        val fresh = vm.refreshCategory(category, region)
        if (fresh.isNotEmpty()) list = fresh
        loading = false
    }
    when {
        list.isNotEmpty() -> PodcastResultList(
            header = stringResource(R.string.discover_daily_hot, stringResource(category.labelRes)),
            podcasts = list,
            onOpen = onOpen
        )
        loading -> LoadingBox()
        else -> EmptyHint(stringResource(R.string.discover_empty_category, stringResource(category.labelRes)))
    }
}

@Composable
private fun CategoryChipsRow(
    state: LazyListState,
    categories: List<Category>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    onEdit: () -> Unit,
    regionOverride: String?,
    onPickRegion: (String?) -> Unit
) {
    LazyRow(
        state = state,
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        item { RegionChip(regionOverride = regionOverride, onPick = onPickRegion) }
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
private fun RegionChip(regionOverride: String?, onPick: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val label = if (regionOverride == null) stringResource(R.string.region_short_auto)
    else REGION_OPTIONS.firstOrNull { it.code == regionOverride }?.let { stringResource(it.labelRes) }
        ?: regionOverride.uppercase()
    Box(Modifier.padding(end = 8.dp)) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier.clickable { open = true }
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
            ) {
                Icon(
                    Icons.Rounded.Public,
                    contentDescription = stringResource(R.string.set_region),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 4.dp)
                )
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            REGION_OPTIONS.forEach { opt ->
                DropdownMenuItem(
                    text = { Text(stringResource(opt.labelRes)) },
                    onClick = { onPick(opt.code); open = false }
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

@Composable
private fun PodcastResultList(
    header: String,
    podcasts: List<Podcast>,
    onOpen: (Podcast) -> Unit
) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 24.dp)
    ) {
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
