package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.BuildConfig
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.playback.asr.AsrFactory
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.InkWave
import com.yuyin.reverb.ui.components.formatTime
import com.yuyin.reverb.ui.components.rememberSpectrumState
import com.yuyin.reverb.ui.share.ShareCards
import com.yuyin.reverb.ui.share.rememberImageSaver
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PlayerScreen(onBack: () -> Unit, onOpenChannel: (String) -> Unit = {}, onOpenQueue: () -> Unit = {}) {
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val position by PlayerController.position.collectAsStateWithLifecycle()
    val duration by PlayerController.duration.collectAsStateWithLifecycle()
    val speed by PlayerController.speed.collectAsStateWithLifecycle()
    val sleepRemaining by PlayerController.sleepRemainingMs.collectAsStateWithLifecycle()
    val sleepEnd by PlayerController.sleepEndOfEpisode.collectAsStateWithLifecycle()

    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val backSec by container.settingsStore.skipBackSec.collectAsStateWithLifecycle()
    val fwdSec by container.settingsStore.skipForwardSec.collectAsStateWithLifecycle()
    val favorites by container.favoriteStore.favorites.collectAsStateWithLifecycle()
    val hasNext by PlayerController.hasNext.collectAsStateWithLifecycle()
    val hasPrev by PlayerController.hasPrev.collectAsStateWithLifecycle()
    val spectrumEnabled by container.settingsStore.spectrumEnabled.collectAsStateWithLifecycle()
    val appContext = LocalContext.current.applicationContext
    val hasAudioPerm = remember {
        ContextCompat.checkSelfPermission(appContext, android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }
    // 仅在开启真频谱、已授权且正在播放时采集,其余走程序化墨纹。
    // BuildConfig.SPECTRUM 为渠道门控:商店渠道不含该功能,恒为 false(见 app/build.gradle)。
    val spectrum by rememberSpectrumState(
        active = BuildConfig.SPECTRUM && spectrumEnabled && hasAudioPerm && isPlaying
    )

    val episode = current
    if (episode == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.player_not_playing), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    val isFavorite = favorites.any { it.id == episode.id }

    val stamps by container.stampStore.stamps.collectAsStateWithLifecycle()
    val currentSeal = stamps.firstOrNull { it.episodeId == episode.id }?.seal
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    val saveImage = rememberImageSaver()
    var sealDialogOpen by remember { mutableStateOf(false) }
    /**
     * 批注弹层。**时间是按下那一刻的快照,不是跟随播放器的实时值**:
     * `position` 每 500ms 随 ticker 重算(PlayerController 的 ticker),而写一句话要十几秒 ——
     * 若弹层直接读 `position`,标题里的时间会在用户打字时一路往后走,
     * 保存下来的秒与看到的那一秒不是同一秒(功能名义上就是"记下这一秒",这正是它唯一的意义)。
     */
    var noteDialogOpen by remember { mutableStateOf(false) }
    var noteAtMs by remember { mutableStateOf(0L) }

    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableStateOf(0f) }
    val sliderValue = if (dragging) dragValue else position.toFloat()
    val maxValue = if (duration > 0) duration.toFloat() else 1f

    /**
     * 是否有第三页(逐字稿)。两个渠道的规则**用同一个表达式**表达:
     * - 默认渠道有离线识别引擎(`AsrFactory.HAS_ENGINE`),跟设置开关走 ⇒ 任何一集都能转;
     * - 大陆商店渠道没有引擎 ⇒ **只有发布方给了逐字稿的那些集才出现第三页**
     *   (用户定的:没稿就别出空页)。
     */
    val transcriptEnabled by container.settingsStore.transcriptionEnabled.collectAsStateWithLifecycle()
    val showTranscript = (AsrFactory.HAS_ENGINE && transcriptEnabled) || episode.transcriptUrl.isNotBlank()
    val pageCount = if (showTranscript) 3 else 2
    val uiLanguage by container.settingsStore.language.collectAsStateWithLifecycle()
    val pagerState = rememberPagerState(pageCount = { pageCount })

    Column(
        Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp)
    ) {
        // 顶部：收起 + 倍速
        Row(
            Modifier
                .fillMaxWidth()
                .padding(top = 12.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.Rounded.KeyboardArrowDown, contentDescription = stringResource(R.string.a11y_collapse_player))
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onOpenQueue) {
                    Icon(
                        Icons.AutoMirrored.Rounded.QueueMusic,
                        contentDescription = stringResource(R.string.a11y_queue),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                SpeedChip(speed = speed)
                SleepChip(remainingMs = sleepRemaining, endOfEpisode = sleepEnd)
                FavoriteButton(
                    favorited = isFavorite,
                    onToggle = { container.favoriteStore.toggle(episode) }
                )
                MoreMenu(
                    stamped = currentSeal != null,
                    onClip = {
                        scope.launch {
                            val bmp = ShareCards.momentCard(ctx, episode, position)
                            ShareCards.share(ctx, bmp, "reverb-moment-${kotlin.math.abs(episode.id.hashCode())}.png", ctx.getString(R.string.clip_share))
                        }
                    },
                    onSave = {
                        scope.launch {
                            val bmp = ShareCards.momentCard(ctx, episode, position)
                            saveImage(bmp, "reverb-moment-${kotlin.math.abs(episode.id.hashCode())}.png")
                        }
                    },
                    onStamp = { sealDialogOpen = true },
                    onNote = { noteAtMs = position; noteDialogOpen = true }
                )
            }
        }

        // 横滑：封面 ↔ 节目笔记
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) { page ->
            when (page) {
                0 -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    InkWave(
                        playing = isPlaying,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.fillMaxSize(),
                        amplitudes = spectrum
                    )
                    Artwork(episode.artworkUrl, size = 260, corner = 24)
                }
                1 -> ShownotesPage(episode)
                else -> TranscriptPane(
                    episode = episode,
                    store = container.transcriptStore,
                    uiLanguage = uiLanguage,
                    // 已下载的单集直接用本地文件转写:不必再下一遍,飞行模式下也能转
                    localPath = container.downloadStore.get(episode.id)?.localPath,
                    engine = container.asrEngine,
                    active = pagerState.currentPage == 2
                )
            }
        }

        // 页码指示点
        PagerDots(current = pagerState.currentPage, count = pageCount)

        Spacer(Modifier.height(12.dp))
        Text(
            episode.title,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(Modifier.height(6.dp))
        // 频道名:有 feedUrl 时可点,跳转频道主页(随机电台尤其有用)
        val canOpenChannel = episode.feedUrl.isNotBlank()
        Text(
            episode.podcastTitle,
            style = MaterialTheme.typography.bodyMedium,
            color = if (canOpenChannel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.secondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (canOpenChannel)
                        Modifier.clickable { onOpenChannel(episode.feedUrl) }
                    else Modifier
                )
        )

        Spacer(Modifier.height(20.dp))
        Slider(
            value = sliderValue.coerceIn(0f, maxValue),
            onValueChange = { dragging = true; dragValue = it },
            onValueChangeFinished = {
                PlayerController.seekTo(dragValue.toLong())
                dragging = false
            },
            valueRange = 0f..maxValue,
            colors = SliderDefaults.colors(
                thumbColor = MaterialTheme.colorScheme.primary,
                activeTrackColor = MaterialTheme.colorScheme.primary,
                inactiveTrackColor = MaterialTheme.colorScheme.outline
            )
        )
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                formatTime(sliderValue.toLong()),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                formatTime(duration),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Spacer(Modifier.height(20.dp))
        // 主控制行:快退 · 上一集 · 播放 · 下一集 · 快进
        Row(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 28.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SkipButton(seconds = backSec, forward = false) { PlayerController.skipBackward() }
            PrevNextButton(next = false, enabled = hasPrev) { PlayerController.previous() }
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .size(76.dp)
                    .clip(CircleShape)
            ) {
                IconButton(onClick = { PlayerController.togglePlayPause() }, modifier = Modifier.fillMaxSize()) {
                    Icon(
                        if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        contentDescription = stringResource(if (isPlaying) R.string.a11y_pause else R.string.a11y_play),
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(40.dp)
                    )
                }
            }
            PrevNextButton(next = true, enabled = hasNext) { PlayerController.next() }
            SkipButton(seconds = fwdSec, forward = true) { PlayerController.skipForward() }
        }
    }

    if (sealDialogOpen) {
        SealDialog(
            current = currentSeal,
            onPick = { seal ->
                container.stampStore.set(episode.id, seal, episode.title, episode.podcastTitle, System.currentTimeMillis())
                sealDialogOpen = false
            },
            onRemove = { container.stampStore.remove(episode.id); sealDialogOpen = false },
            onDismiss = { sealDialogOpen = false }
        )
    }

    if (noteDialogOpen) {
        NoteDialog(
            atMs = noteAtMs,
            onSave = { text ->
                container.noteStore.add(episode, noteAtMs, text, System.currentTimeMillis())
                noteDialogOpen = false
            },
            onDismiss = { noteDialogOpen = false }
        )
    }
}

@Composable
private fun ShownotesPage(episode: Episode) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(vertical = 8.dp)
    ) {
        Text(
            stringResource(R.string.shownotes),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground
        )
        Spacer(Modifier.height(10.dp))
        Text(
            episode.description.ifBlank { stringResource(R.string.shownotes_empty) },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun PagerDots(current: Int, count: Int) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        repeat(count) { i ->
            val active = i == current
            Box(
                Modifier
                    .padding(horizontal = 4.dp)
                    .size(if (active) 8.dp else 6.dp)
                    .clip(CircleShape)
                    .background(
                        if (active) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.outline
                    )
            )
        }
    }
}

/** 倍速:点开下拉框选择,替代过去点一下换一档。 */
@Composable
private fun SpeedChip(speed: Float) {
    var open by remember { mutableStateOf(false) }
    Box {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .clickable { open = true }
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 14.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)
            ) {
                Text(
                    "${formatSpeed(speed)}×",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary
                )
                Icon(
                    Icons.Rounded.ArrowDropDown,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp)
                )
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            PlayerController.speedSteps.forEach { s ->
                DropdownMenuItem(
                    text = {
                        Text(
                            "${formatSpeed(s)}×",
                            color = if (kotlin.math.abs(s - speed) < 0.01f) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurface
                        )
                    },
                    onClick = { PlayerController.setSpeed(s); open = false }
                )
            }
        }
    }
}

/** 更多:剪藏(分享此刻)、保存此刻、写批注、盖章(听觉印记)收进溢出菜单,避免顶栏按钮过多。 */
@Composable
private fun MoreMenu(
    stamped: Boolean,
    onClip: () -> Unit,
    onSave: () -> Unit,
    onStamp: () -> Unit,
    onNote: () -> Unit
) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Rounded.MoreVert, contentDescription = stringResource(R.string.more), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.clip_save)) },
                onClick = { open = false; onSave() }
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.clip_moment)) },
                onClick = { open = false; onClip() }
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.note_add)) },
                onClick = { open = false; onNote() }
            )
            DropdownMenuItem(
                text = { Text(stringResource(if (stamped) R.string.stamp_edit else R.string.stamp_add)) },
                onClick = { open = false; onStamp() }
            )
        }
    }
}

/**
 * 写一条批注:标题带**按下的那一刻**的时间,正文一句话。
 *
 * 空文字**直接不放进去**(`NoteStore.add` 返回 null)而不是弹个"请输入内容"——
 * 用户点了保存又什么也没写,最自然的意图是"这条不要",关掉即可;
 * 而列表里出现一条空白批注,以后无从分辨它是不是误触(且它没有可删的正文,删除确认框会显示成空)。
 */
@Composable
private fun NoteDialog(atMs: Long, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.note_title)) },
        text = {
            Column {
                Text(
                    formatTime(atMs),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.note_hint)) },
                    minLines = 3,
                    maxLines = 6
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(text) }) { Text(stringResource(R.string.action_save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        }
    )
}

// 以 Ekman 基本情绪为骨架、替换掉听播客用不上的「惧/厌」,凑成 3×3 情绪方阵;每枚附小字注明。
private val SEALS = listOf(
    "喜" to "开心", "暖" to "治愈", "燃" to "热血",
    "惊" to "震撼", "思" to "沉思", "悟" to "领悟",
    "悲" to "难过", "怒" to "愤怒", "疲" to "疲惫"
)

/** 盖章选择:3×3 水墨情绪印章(附小字)。点选即盖,再点同一枚即取消;点外部关闭。 */
@Composable
private fun SealDialog(current: String?, onPick: (String) -> Unit, onRemove: () -> Unit, onDismiss: () -> Unit) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                stringResource(R.string.stamp_title),
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )
        },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    stringResource(R.string.stamp_hint),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center
                )
                Spacer(Modifier.height(14.dp))
                SEALS.chunked(3).forEach { row ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        row.forEach { (s, label) ->
                            val sel = s == current
                            Column(
                                Modifier.weight(1f),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Surface(
                                    shape = RoundedCornerShape(12.dp),
                                    color = if (sel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(56.dp)
                                        .clip(RoundedCornerShape(12.dp))
                                        .clickable { if (sel) onRemove() else onPick(s) } // 再点同一枚即取消
                                ) {
                                    Box(contentAlignment = Alignment.Center) {
                                        Text(
                                            s,
                                            style = MaterialTheme.typography.headlineSmall,
                                            color = if (sel) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
                                        )
                                    }
                                }
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    label,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = if (sel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                }
            }
        },
        confirmButton = {} // 无需按钮:点选即生效,点外部关闭
    )
}

/** 收藏当前单集:填充心表示已收藏,描边心表示未收藏。 */
@Composable
private fun FavoriteButton(favorited: Boolean, onToggle: () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier
            .clip(CircleShape)
            .clickable(onClick = onToggle)
    ) {
        Icon(
            if (favorited) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            contentDescription = stringResource(if (favorited) R.string.a11y_unfavorite else R.string.a11y_favorite),
            tint = if (favorited) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .padding(8.dp)
                .size(20.dp)
        )
    }
}

private fun formatSpeed(speed: Float): String =
    "%.2f".format(speed).trimEnd('0').trimEnd('.')

/** 上一集 / 下一集按钮:不可用时置灰。 */
@Composable
private fun PrevNextButton(next: Boolean, enabled: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(52.dp)) {
        Icon(
            if (next) Icons.Rounded.SkipNext else Icons.Rounded.SkipPrevious,
            contentDescription = stringResource(if (next) R.string.a11y_next else R.string.a11y_prev),
            tint = if (enabled) MaterialTheme.colorScheme.onBackground else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f),
            modifier = Modifier.size(34.dp)
        )
    }
}

@Composable
private fun SkipButton(seconds: Int, forward: Boolean, onClick: () -> Unit) {
    // 图标居中(与播放/上一集/下一集图标对齐),秒数悬在图标下一行、不顶高图标
    Box(contentAlignment = Alignment.Center, modifier = Modifier.height(76.dp)) {
        IconButton(onClick = onClick, modifier = Modifier.size(52.dp)) {
            Icon(
                Icons.Rounded.Replay,
                contentDescription = stringResource(if (forward) R.string.a11y_skip_fwd else R.string.a11y_skip_back, seconds),
                tint = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier
                    .size(32.dp)
                    .then(if (forward) Modifier.graphicsLayer(scaleX = -1f) else Modifier)
            )
        }
        Text(
            "$seconds",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .align(Alignment.Center)
                .offset(y = 22.dp)
        )
    }
}

@Composable
private fun SleepChip(remainingMs: Long, endOfEpisode: Boolean) {
    var open by remember { mutableStateOf(false) }
    val active = remainingMs > 0 || endOfEpisode
    val label = when {
        remainingMs > 0 -> formatTime(remainingMs)
        endOfEpisode -> stringResource(R.string.sleep_current)
        else -> stringResource(R.string.sleep)
    }
    val tint = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    Box {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .clickable { open = true }
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                Icon(Icons.Rounded.Bedtime, contentDescription = stringResource(R.string.sleep), tint = tint, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text(label, style = MaterialTheme.typography.labelLarge, color = tint)
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            listOf(15, 30, 45, 60).forEach { m ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sleep_minutes, m)) },
                    onClick = { PlayerController.setSleepTimer(m); open = false }
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.sleep_end_of_episode)) },
                onClick = { PlayerController.setSleepEndOfEpisode(); open = false }
            )
            if (active) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sleep_off)) },
                    onClick = { PlayerController.cancelSleep(); open = false }
                )
            }
        }
    }
}
