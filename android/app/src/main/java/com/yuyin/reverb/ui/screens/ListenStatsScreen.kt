package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.formatListenDuration

/** 收听时长:按频道累计的收听时长,从多到少排序,用横条可视化(越长横条越长)。 */
@Composable
fun ListenStatsScreen(onBack: () -> Unit) {
    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val stats by container.listenStatsStore.stats.collectAsStateWithLifecycle()
    val rows = stats.filter { it.listenedMs > 0 }
    val maxMs = (rows.firstOrNull()?.listenedMs ?: 1L).coerceAtLeast(1L)

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 4.dp, top = 24.dp, end = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.a11y_back))
            }
            Text(
                stringResource(R.string.listen_stats_title),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f).padding(start = 4.dp)
            )
        }

        if (rows.isEmpty()) {
            EmptyHint(stringResource(R.string.listen_stats_empty))
            return
        }
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            items(rows, key = { it.key }) { c ->
                val fraction = (c.listenedMs.toFloat() / maxMs.toFloat()).coerceIn(0.02f, 1f)
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Artwork(url = c.artworkUrl, size = 40, corner = 8)
                        Spacer(Modifier.width(12.dp))
                        Text(
                            c.title.ifBlank { stringResource(R.string.unknown_channel) },
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            formatListenDuration(c.listenedMs / 1000),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    // 横条:底槽 + 按比例填充的强调色;最长者满宽
                    Box(
                        Modifier.fillMaxWidth().height(10.dp).clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                    ) {
                        Box(
                            Modifier.fillMaxWidth(fraction).fillMaxHeight().clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary)
                        )
                    }
                }
            }
        }
    }
}
