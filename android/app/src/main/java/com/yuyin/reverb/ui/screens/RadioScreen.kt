package com.yuyin.reverb.ui.screens

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AddCircleOutline
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.data.model.Station
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.DirectoryState
import com.yuyin.reverb.ui.StationSaveError
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.PillChip
import com.yuyin.reverb.ui.radioViewModel

/**
 * 直播电台页:自己的电台账本(增 / 改 / 删)+ 在线目录检索 + 随包精选兜底。
 *
 * 起播走 `RadioViewModel.play` → 合成 `isLive` 的 Episode,与"把流地址粘进搜索框"
 * 是同一条播放路径(历史 / 缓存 / 断点续播全部不参与)。
 *
 * ⚠️ 这一页是顶层 tab,列表底部必须让出 `LocalGlassBottomPad`(悬浮玻璃栏叠在内容上),
 * 否则最后一条会被栏压住、滚不出来。
 */
@Composable
fun RadioScreen(scrollTopToken: Int = 0) {
    val vm = radioViewModel()
    val context = LocalContext.current
    val keyboard = LocalSoftwareKeyboardController.current
    val stations by vm.stations.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val seed = remember { vm.seedStations() }
    val listState = rememberLazyListState()

    var editorOpen by remember { mutableStateOf(false) }
    var editorFor by remember { mutableStateOf<Station?>(null) }
    var deleteFor by remember { mutableStateOf<Station?>(null) }

    val liveLabel = stringResource(R.string.radio_live_name)
    val alreadyAdded = stringResource(R.string.radio_already_added)
    val savedToast = stringResource(R.string.radio_added)

    LaunchedEffect(Unit) { vm.ensureDirectory() }
    LaunchedEffect(scrollTopToken) {
        if (scrollTopToken > 0) listState.animateScrollToItem(0)
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = stringResource(R.string.nav_radio),
            subtitle = stringResource(R.string.radio_subtitle)
        )
        RadioSearchField(
            query = vm.query,
            onQueryChange = vm::onQueryChange,
            onSearch = {
                keyboard?.hide()
                vm.search()
            }
        )
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                top = 4.dp,
                bottom = LocalGlassBottomPad.current + 24.dp
            )
        ) {
            item(key = "my-header") {
                SectionTitle(
                    title = stringResource(R.string.radio_my_stations),
                    action = {
                        IconButton(onClick = {
                            vm.resetSaveState()
                            editorFor = null
                            editorOpen = true
                        }) {
                            Icon(Icons.Rounded.Add, contentDescription = stringResource(R.string.radio_add))
                        }
                    }
                )
            }
            if (stations.isEmpty()) {
                item(key = "my-empty") { HintText(stringResource(R.string.radio_empty_my)) }
            } else {
                items(stations, key = { "my:${it.id}" }) { st ->
                    StationRow(
                        station = st,
                        playing = current?.id == "live:${st.url}",
                        subtitle = subtitleOf(st),
                        onClick = { vm.play(st, liveLabel) },
                        trailing = {
                            IconButton(onClick = {
                                vm.resetSaveState()
                                editorFor = st
                                editorOpen = true
                            }) {
                                Icon(Icons.Rounded.Edit, contentDescription = stringResource(R.string.radio_edit))
                            }
                            IconButton(onClick = { deleteFor = st }) {
                                Icon(
                                    Icons.Rounded.DeleteOutline,
                                    contentDescription = stringResource(R.string.radio_delete)
                                )
                            }
                        }
                    )
                }
            }

            item(key = "dir-header") {
                SectionTitle(
                    title = stringResource(
                        if (vm.query.isBlank()) R.string.radio_hot_stations else R.string.radio_search_results
                    )
                )
            }
            when (val s = vm.directoryState) {
                is DirectoryState.Loading -> item(key = "dir-loading") {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(stringResource(R.string.loading), style = MaterialTheme.typography.bodySmall)
                    }
                }

                is DirectoryState.Error -> item(key = "dir-error") {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            stringResource(R.string.radio_load_failed),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f)
                        )
                        TextButton(onClick = vm::retry) { Text(stringResource(R.string.radio_retry)) }
                    }
                }

                is DirectoryState.Empty -> item(key = "dir-empty") {
                    HintText(stringResource(R.string.radio_empty_search))
                }

                is DirectoryState.Success -> items(s.stations, key = { "dir:${it.id}" }) { st ->
                    val saved = vm.isSaved(st)
                    StationRow(
                        station = st,
                        playing = current?.id == "live:${st.url}",
                        subtitle = subtitleOf(st),
                        onClick = { vm.play(st, liveLabel) },
                        trailing = {
                            IconButton(
                                enabled = !saved,
                                onClick = {
                                    val added = vm.addCopy(st)
                                    Toast.makeText(
                                        context,
                                        if (added) savedToast else alreadyAdded,
                                        Toast.LENGTH_SHORT
                                    ).show()
                                }
                            ) {
                                Icon(
                                    if (saved) Icons.Rounded.CheckCircle else Icons.Rounded.AddCircleOutline,
                                    contentDescription = stringResource(
                                        if (saved) R.string.radio_already_added else R.string.radio_add
                                    ),
                                    tint = if (saved) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    )
                }

                DirectoryState.Idle -> Unit
            }

            if (vm.query.isBlank() && seed.isNotEmpty()) {
                item(key = "seed-header") {
                    SectionTitle(title = stringResource(R.string.radio_seed_stations))
                }
                items(seed, key = { "seed:${it.url}" }) { st ->
                    val saved = vm.isSaved(st)
                    StationRow(
                        station = st,
                        playing = current?.id == "live:${st.url}",
                        subtitle = subtitleOf(st),
                        onClick = { vm.play(st, liveLabel) },
                        trailing = {
                            IconButton(
                                enabled = !saved,
                                onClick = {
                                    val added = vm.addCopy(st)
                                    Toast.makeText(
                                        context,
                                        if (added) savedToast else alreadyAdded,
                                        Toast.LENGTH_SHORT
                                    ).show()
                                }
                            ) {
                                Icon(
                                    if (saved) Icons.Rounded.CheckCircle else Icons.Rounded.AddCircleOutline,
                                    contentDescription = stringResource(
                                        if (saved) R.string.radio_already_added else R.string.radio_add
                                    ),
                                    tint = if (saved) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    )
                }
            }
        }
    }

    if (editorOpen) {
        StationEditorDialog(
            station = editorFor,
            saving = vm.saving,
            error = vm.saveError,
            onDismiss = {
                vm.resetSaveState()
                editorOpen = false
            },
            onSave = { name, url, logo, group ->
                vm.save(editorFor, name, url, logo, group) { editorOpen = false }
            }
        )
    }

    deleteFor?.let { st ->
        AlertDialog(
            onDismissRequest = { deleteFor = null },
            title = { Text(stringResource(R.string.radio_delete)) },
            text = { Text(stringResource(R.string.radio_delete_msg, st.name)) },
            confirmButton = {
                TextButton(onClick = {
                    vm.remove(st.id)
                    deleteFor = null
                }) {
                    Text(
                        stringResource(R.string.action_delete),
                        color = MaterialTheme.colorScheme.error
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteFor = null }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }
}

@Composable
private fun RadioSearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
        placeholder = { Text(stringResource(R.string.radio_search_hint)) },
        leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotBlank()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.action_clear))
                }
            }
        },
        singleLine = true,
        shape = RoundedCornerShape(24.dp),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { onSearch() })
    )
}

@Composable
private fun SectionTitle(title: String, action: (@Composable () -> Unit)? = null) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 12.dp, top = 16.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.weight(1f)
        )
        action?.invoke()
    }
}

@Composable
private fun HintText(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp)
    )
}

/** 一行电台:封面 + 名称 + 副标(分组/国家)+ 尾部动作。整行可点即起播。 */
@Composable
private fun StationRow(
    station: Station,
    playing: Boolean,
    subtitle: String,
    onClick: () -> Unit,
    trailing: @Composable () -> Unit
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box {
            Artwork(station.logo, 48)
            if (playing) {
                Box(
                    Modifier
                        .matchParentSize()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.Black.copy(alpha = 0.38f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Rounded.GraphicEq, contentDescription = null, tint = Color.White)
                }
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                station.name,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (subtitle.isNotBlank()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        trailing()
    }
}

@Composable
private fun subtitleOf(station: Station): String {
    val group = when (station.group) {
        "news" -> stringResource(R.string.radio_group_news)
        "music" -> stringResource(R.string.radio_group_music)
        "talk" -> stringResource(R.string.radio_group_talk)
        "retro" -> stringResource(R.string.radio_group_retro)
        else -> ""
    }
    return listOf(group, station.country).filter { it.isNotBlank() }.joinToString(" · ")
}

@Composable
private fun StationEditorDialog(
    station: Station?,
    saving: Boolean,
    error: StationSaveError?,
    onDismiss: () -> Unit,
    onSave: (name: String, url: String, logo: String, group: String) -> Unit
) {
    var name by remember { mutableStateOf(station?.name.orEmpty()) }
    var url by remember { mutableStateOf(station?.url.orEmpty()) }
    var logo by remember { mutableStateOf(station?.logo.orEmpty()) }
    var group by remember { mutableStateOf(station?.group.orEmpty()) }

    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        title = {
            Text(stringResource(if (station == null) R.string.radio_add else R.string.radio_edit))
        },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.radio_name)) },
                    placeholder = { Text(stringResource(R.string.radio_name_hint)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it },
                    label = { Text(stringResource(R.string.radio_url)) },
                    placeholder = { Text("https://") },
                    singleLine = true,
                    isError = error == StationSaveError.INVALID_URL || error == StationSaveError.NOT_STREAM,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = logo,
                    onValueChange = { logo = it },
                    label = { Text(stringResource(R.string.radio_logo_optional)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    stringResource(R.string.radio_group),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(6.dp))
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    PillChip(
                        selected = group.isBlank(),
                        text = stringResource(R.string.radio_group_none),
                        onClick = { group = "" }
                    )
                    stationGroups().forEach { g ->
                        PillChip(
                            selected = group == g,
                            text = groupLabel(g),
                            onClick = { group = g }
                        )
                    }
                }
                if (error != null) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = when (error) {
                            StationSaveError.INVALID_URL -> stringResource(R.string.radio_invalid_url)
                            StationSaveError.DUPLICATE -> stringResource(R.string.radio_duplicate)
                            StationSaveError.NOT_STREAM -> stringResource(R.string.radio_not_stream)
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
                if (saving) {
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            stringResource(R.string.radio_checking),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving,
                onClick = { onSave(name, url, logo, group) }
            ) { Text(stringResource(R.string.action_save)) }
        },
        dismissButton = {
            TextButton(enabled = !saving, onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel))
            }
        }
    )
}

/** 分组代码表只有一份(模型里的 `Station.GROUPS`),这里只负责把代码翻成当前语言。 */
private fun stationGroups(): List<String> = Station.GROUPS

@Composable
private fun groupLabel(g: String): String = when (g) {
    "news" -> stringResource(R.string.radio_group_news)
    "music" -> stringResource(R.string.radio_group_music)
    "talk" -> stringResource(R.string.radio_group_talk)
    "retro" -> stringResource(R.string.radio_group_retro)
    else -> g
}
