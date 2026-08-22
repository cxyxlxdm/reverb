package com.yuyin.reverb.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.yuyin.reverb.R
import coil.compose.AsyncImage
import com.yuyin.reverb.data.local.InboxStore
import com.yuyin.reverb.data.model.DownloadStatus
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.ui.theme.CeladonDim
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 分段/分类用的**药丸 chip**。
 *
 * 与 Material 的 `FilterChip` 默认样式相比,去掉了两样:圆角由 8dp 改为全圆,
 * 以及去掉 1dp 描边。这是**跟鸿蒙端对齐**的结果 —— 鸿蒙那边一直是全圆实底药丸,
 * 两端并排看时 Material 那种「圆角矩形 + 细描边」显得更硬。
 *
 * 未选中是 onSurfaceVariant 的 10% 实底(与鸿蒙 `ChipsRow` 同一配方),选中是强调色实底。
 *
 * 全项目三处 chip 都走这里:音阁分段、发现页分类(仅完整版渠道)、搜索结果的节目/单集分段。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PillChip(
    selected: Boolean,
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(text) },
        modifier = modifier,
        shape = RoundedCornerShape(percent = 50),
        border = null,
        colors = FilterChipDefaults.filterChipColors(
            containerColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.10f),
            labelColor = MaterialTheme.colorScheme.onSurfaceVariant,
            selectedContainerColor = MaterialTheme.colorScheme.primary,
            selectedLabelColor = MaterialTheme.colorScheme.onPrimary
        )
    )
}

fun formatTime(ms: Long): String {
    if (ms <= 0) return "00:00"
    val totalSec = ms / 1000
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    val s = totalSec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

fun formatDurationSec(sec: Long): String = if (sec <= 0) "" else formatTime(sec * 1000)

/**
 * 单集发布日期的展示形态:`Fri, 21 Aug 2026`。
 *
 * 原先这里是 `episode.pubDate.take(16)` —— 直接把 RSS 里的 pubDate 原始串**截前 16 字符**。
 * 对 RFC-822 的源(`Fri, 21 Aug 2026 10:00:00 +0800`)恰好得到想要的样子,所以一直没露馅,
 * 但换成 ISO-8601 的源就会截出 `2026-08-21T10:00` 这种半截货 —— 而 RSS 里两种都常见。
 * 格式保留(与鸿蒙侧 formatPubDate 逐字一致),取法改成**先解析再格式化**。
 *
 * 定死 `Locale.ENGLISH`,不跟随界面语言:两端定死才能保证同一集在两台机器上显示相同,
 * 对不了版就不好排查。解析失败时仍退回截前 16 字符 —— 至少还能看出个大概。
 */
fun formatPubDate(raw: String): String {
    val ms = InboxStore.parsePubMillis(raw)
    if (ms <= 0L) return raw.trim().take(16)
    return SimpleDateFormat("EEE, dd MMM yyyy", Locale.ENGLISH).format(Date(ms))
}

/** 人类可读的累计时长:"X 小时 Y 分" / "Y 分钟" / "小于 1 分钟"(用于收听时长展示)。 */
@Composable
fun formatListenDuration(sec: Long): String {
    if (sec < 60) return stringResource(R.string.listen_lt1m)
    val m = sec / 60
    return if (m >= 60) stringResource(R.string.listen_hm, m / 60, m % 60)
    else stringResource(R.string.listen_m, m)
}

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

/** 填满单元格宽度的方形封面(宫格用)。无封面时以主色频谱图标占位。 */
@Composable
fun SquareArtwork(url: String, corner: Int = 14) {
    val shape = RoundedCornerShape(corner.dp)
    if (url.isBlank()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(shape)
                .background(CeladonDim.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Rounded.GraphicEq, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        }
    } else {
        AsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(shape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
        )
    }
}

/** 宫格卡片:方形封面 + 标题 + 作者,与 macOS PodcastCard 对齐。 */
@Composable
fun PodcastGridItem(podcast: Podcast, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick)) {
        SquareArtwork(podcast.artworkUrl)
        Spacer(Modifier.height(8.dp))
        Text(
            podcast.title,
            style = MaterialTheme.typography.titleSmall,
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

@OptIn(ExperimentalFoundationApi::class)
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
    onToggleFavorite: (() -> Unit)? = null,
    played: Boolean = false,            // 已播完:标题变暗 + 打勾
    onTogglePlayed: (() -> Unit)? = null, // 长按菜单:标记已播完/未播完
    onPlayNext: (() -> Unit)? = null,     // 长按菜单:下一个播放
    onEnqueue: (() -> Unit)? = null       // 长按菜单:加入队列
) {
    var menuOpen by remember { mutableStateOf(false) }
    val hasMenu = onTogglePlayed != null || onPlayNext != null || onEnqueue != null
    val rowModifier = Modifier
        .fillMaxWidth()
        .then(
            if (hasMenu) Modifier.combinedClickable(onClick = onPlay, onLongClick = { menuOpen = true })
            else Modifier.clickable(onClick = onPlay)
        )
        .padding(horizontal = 16.dp, vertical = 12.dp)
    Box {
    Row(
        modifier = rowModifier,
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    episode.title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = when {
                        isCurrent -> MaterialTheme.colorScheme.primary
                        played -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                        else -> MaterialTheme.colorScheme.onBackground
                    },
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
                if (played) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        Icons.Rounded.Check,
                        contentDescription = stringResource(R.string.a11y_played),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
            val meta = listOf(formatPubDate(episode.pubDate), formatDurationSec(episode.durationSec))
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
        if (hasMenu) {
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                if (onPlayNext != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.queue_play_next)) },
                        onClick = { menuOpen = false; onPlayNext() }
                    )
                }
                if (onEnqueue != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.queue_add)) },
                        onClick = { menuOpen = false; onEnqueue() }
                    )
                }
                if (onTogglePlayed != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(if (played) R.string.mark_unplayed else R.string.mark_played)) },
                        onClick = { menuOpen = false; onTogglePlayed() }
                    )
                }
            }
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
