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
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.InkWave
import com.yuyin.reverb.ui.components.formatTime

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PlayerScreen(onBack: () -> Unit) {
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

    val episode = current
    if (episode == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.player_not_playing), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    val isFavorite = favorites.any { it.id == episode.id }

    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableStateOf(0f) }
    val sliderValue = if (dragging) dragValue else position.toFloat()
    val maxValue = if (duration > 0) duration.toFloat() else 1f

    val pagerState = rememberPagerState(pageCount = { 2 })

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
                SleepChip(remainingMs = sleepRemaining, endOfEpisode = sleepEnd)
                SpeedChip(speed = speed)
                FavoriteButton(
                    favorited = isFavorite,
                    onToggle = { container.favoriteStore.toggle(episode) }
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
                        modifier = Modifier.fillMaxSize()
                    )
                    Artwork(episode.artworkUrl, size = 260, corner = 24)
                }
                else -> ShownotesPage(episode)
            }
        }

        // 页码指示点
        PagerDots(current = pagerState.currentPage, count = 2)

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
        Text(
            episode.podcastTitle,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.secondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
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
        Row(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 28.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            SkipButton(seconds = backSec, forward = false) { PlayerController.skipBackward() }
            Spacer(Modifier.size(24.dp))
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
            Spacer(Modifier.size(24.dp))
            SkipButton(seconds = fwdSec, forward = true) { PlayerController.skipForward() }
        }
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
            modifier = Modifier.clickable { open = true }
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

/** 收藏当前单集:填充心表示已收藏,描边心表示未收藏。 */
@Composable
private fun FavoriteButton(favorited: Boolean, onToggle: () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.clickable(onClick = onToggle)
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

@Composable
private fun SkipButton(seconds: Int, forward: Boolean, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
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
            color = MaterialTheme.colorScheme.onSurfaceVariant
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
            modifier = Modifier.clickable { open = true }
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
