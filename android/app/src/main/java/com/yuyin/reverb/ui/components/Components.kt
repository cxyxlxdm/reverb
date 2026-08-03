package com.yuyin.reverb.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.yuyin.reverb.R
import coil.compose.AsyncImage
import com.yuyin.reverb.data.model.DownloadStatus
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.ui.theme.CeladonDim

fun formatTime(ms: Long): String {
    if (ms <= 0) return "00:00"
    val totalSec = ms / 1000
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    val s = totalSec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

fun formatDurationSec(sec: Long): String = if (sec <= 0) "" else formatTime(sec * 1000)

@Composable
fun Artwork(url: String, size: Int, corner: Int = 12) {
    val shape = RoundedCornerShape(corner.dp)
    if (url.isBlank()) {
        Box(
            modifier = Modifier
                .size(size.dp)
                .clip(shape)
                .background(CeladonDim.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Rounded.GraphicEq,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary
            )
        }
    } else {
        AsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(size.dp)
                .clip(shape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
        )
    }
}

@Composable
fun PodcastListItem(podcast: Podcast, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Artwork(podcast.artworkUrl, size = 60)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                podcast.title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onBackground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (podcast.author.isNotBlank()) {
                Text(
                    podcast.author,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (podcast.isPaid) {
                Text(
                    "付费",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.secondary
                )
            }
        }
    }
}

@Composable
fun EpisodeListItem(
    episode: Episode,
    isCurrent: Boolean,
    isPlaying: Boolean,
    onPlay: () -> Unit,
    downloadStatus: DownloadStatus? = null,
    onDownload: (() -> Unit)? = null,
    onDeleteDownload: (() -> Unit)? = null,
    showPodcastTitle: Boolean = false, // 搜索结果里同列多个不同播客的单集，需标出所属频道
    isFavorite: Boolean = false,
    onToggleFavorite: (() -> Unit)? = null
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onPlay)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 封面缩略图 + 播放/暂停轻蒙层:更有色彩,并保留播放态与播放入口(整行可点)
        Box(Modifier.size(52.dp), contentAlignment = Alignment.Center) {
            Artwork(episode.artworkUrl, size = 52, corner = 10)
            Box(
                Modifier
                    .matchParentSize()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Color.Black.copy(alpha = if (isCurrent) 0.42f else 0.28f))
            )
            Icon(
                if (isCurrent && isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = stringResource(if (isPlaying && isCurrent) R.string.a11y_pause else R.string.a11y_play),
                tint = Color.White,
                modifier = Modifier.size(24.dp)
            )
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                episode.title,
                style = MaterialTheme.typography.bodyLarge,
                color = if (isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onBackground,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            val meta = listOf(episode.pubDate.take(16), formatDurationSec(episode.durationSec))
                .filter { it.isNotBlank() }
                .joinToString("  ·  ")
            val showTitle = showPodcastTitle && episode.podcastTitle.isNotBlank()
            // 搜索结果：同一行内 频道名靠左（最多 10 字符，超出前 9 字 + 省略号）、时间靠右
            // （时间宽度固定，右缘天然整齐）；其它场景保持时间单独左对齐。
            if (showTitle) {
                val name = episode.podcastTitle
                val shown = if (name.length > 10) name.take(9) + "…" else name
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        shown,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1
                    )
                    if (meta.isNotBlank()) {
                        Text(
                            meta,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1
                        )
                    }
                }
            } else if (meta.isNotBlank()) {
                Text(
                    meta,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1
                )
            }
        }
        if (onToggleFavorite != null) {
            IconButton(onClick = onToggleFavorite) {
                Icon(
                    if (isFavorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                    contentDescription = stringResource(if (isFavorite) R.string.a11y_unfavorite else R.string.a11y_favorite),
                    tint = if (isFavorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        if (onDownload != null || onDeleteDownload != null) {
            DownloadControl(downloadStatus, onDownload, onDeleteDownload)
        }
    }
}

@Composable
private fun DownloadControl(
    status: DownloadStatus?,
    onDownload: (() -> Unit)?,
    onDelete: (() -> Unit)?
) {
    when (status) {
        is DownloadStatus.Completed -> IconButton(onClick = { onDelete?.invoke() }) {
            Icon(
                Icons.Rounded.DownloadDone,
                contentDescription = stringResource(R.string.a11y_downloaded),
                tint = MaterialTheme.colorScheme.primary
            )
        }
        is DownloadStatus.Downloading -> Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(
                progress = { status.progress },
                modifier = Modifier.size(22.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.primary
            )
        }
        DownloadStatus.Queued -> Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.primary)
        }
        else -> IconButton(onClick = { onDownload?.invoke() }) {
            Icon(
                Icons.Rounded.Download,
                contentDescription = stringResource(R.string.a11y_download),
                tint = if (status is DownloadStatus.Failed) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/** 节目列表左侧的圆形播放按钮：外圈轮廓 + 中心三角，播放中显示暂停并高亮。 */
@Composable
private fun PlayCircle(isCurrent: Boolean, isPlaying: Boolean, onClick: () -> Unit) {
    val accent = if (isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(
                if (isCurrent) MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                else Color.Transparent
            )
            .border(1.5.dp, accent.copy(alpha = 0.6f), CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            if (isCurrent && isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
            contentDescription = stringResource(if (isCurrent && isPlaying) R.string.a11y_pause else R.string.a11y_play),
            tint = accent,
            modifier = Modifier.size(22.dp)
        )
    }
}

@Composable
fun MiniPlayer(
    episode: Episode,
    isPlaying: Boolean,
    buffering: Boolean,
    progress: Float,
    hasNext: Boolean,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onExpand: () -> Unit
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column {
            LinearProgressIndicator(
                progress = { progress.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(2.dp),
                color = MaterialTheme.colorScheme.primary,
                trackColor = Color.Transparent
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onExpand)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Artwork(episode.artworkUrl, size = 44, corner = 8)
                Column(Modifier.weight(1f)) {
                    Text(
                        episode.title,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onBackground,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        episode.podcastTitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                if (buffering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.primary
                    )
                } else {
                    IconButton(onClick = onToggle) {
                        Icon(
                            if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary
                        )
                    }
                }
                IconButton(onClick = onNext, enabled = hasNext) {
                    Icon(
                        Icons.Rounded.SkipNext,
                        contentDescription = stringResource(R.string.a11y_next),
                        tint = if (hasNext) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                    )
                }
            }
        }
    }
}
