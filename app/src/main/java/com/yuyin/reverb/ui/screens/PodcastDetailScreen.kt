package com.yuyin.reverb.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.PodcastState
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.podcastViewModel

@Composable
fun PodcastDetailScreen(feedUrl: String, onBack: () -> Unit) {
    val vm = podcastViewModel()
    LaunchedEffect(feedUrl) { vm.load(feedUrl) }

    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val downloadStates by DownloadManager.states.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 4.dp, top = 24.dp, end = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.a11y_back))
            }
        }

        when (val s = vm.state) {
            PodcastState.Loading -> LoadingBox()
            PodcastState.Error -> EmptyHint(stringResource(R.string.load_failed))
            is PodcastState.Loaded -> {
                val subscribed = subs.any { it.feedUrl == s.podcast.feedUrl }
                LazyColumn(
                    Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = 24.dp)
                ) {
                    item {
                        PodcastDetailHeader(
                            podcast = s.podcast,
                            episodeCount = s.episodes.size,
                            subscribed = subscribed,
                            onSubscribe = { container.subscriptionStore.toggle(s.podcast) }
                        )
                    }
                    items(s.episodes) { ep ->
                        EpisodeListItem(
                            episode = ep,
                            isCurrent = current?.id == ep.id,
                            isPlaying = isPlaying,
                            onPlay = { PlayerController.playOrToggle(ep) },
                            downloadStatus = downloadStates[ep.id],
                            onDownload = { DownloadManager.download(ep) },
                            onDeleteDownload = { DownloadManager.delete(ep.id) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun PodcastDetailHeader(
    podcast: Podcast,
    episodeCount: Int,
    subscribed: Boolean,
    onSubscribe: () -> Unit
) {
    val context = LocalContext.current
    Column(Modifier.padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Artwork(podcast.artworkUrl, size = 96, corner = 16)
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    podcast.title,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onBackground,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis
                )
                if (podcast.author.isNotBlank()) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        podcast.author,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }

        if (podcast.isPaid) {
            Spacer(Modifier.height(12.dp))
            PaidBadge()
        }

        Spacer(Modifier.height(16.dp))

        if (subscribed) {
            OutlinedButton(onClick = onSubscribe) {
                Icon(Icons.Rounded.Check, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.action_subscribed))
            }
        } else {
            Button(
                onClick = onSubscribe,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary
                )
            ) {
                Icon(Icons.Rounded.Add, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.action_subscribe))
            }
        }

        if (podcast.fundingUrl.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            FundingLink(
                label = podcast.fundingLabel,
                onOpen = {
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(podcast.fundingUrl)))
                    }
                }
            )
        }

        if (podcast.description.isNotBlank()) {
            Spacer(Modifier.height(16.dp))
            ExpandableDescription(podcast.description)
        }

        Spacer(Modifier.height(16.dp))
        Text(
            stringResource(R.string.episode_count, episodeCount),
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onBackground
        )
    }
}

/** 简介：默认最多显示 4 行，被截断时出现「展开」箭头，点击展开全文，可再收起。 */
@Composable
private fun ExpandableDescription(text: String) {
    var expanded by remember { mutableStateOf(false) }
    var hasOverflow by remember { mutableStateOf(false) }
    val collapsedLines = 4

    Column {
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = if (expanded) Int.MAX_VALUE else collapsedLines,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { result ->
                if (!expanded) hasOverflow = result.hasVisualOverflow
            }
        )
        if (hasOverflow || expanded) {
            Row(
                modifier = Modifier
                    .padding(top = 6.dp)
                    .clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    stringResource(if (expanded) R.string.action_collapse else R.string.action_expand),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary
                )
                Icon(
                    if (expanded) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
            }
        }
    }
}

/** 付费节目醒目标识（金色胶囊）。 */
@Composable
private fun PaidBadge() {
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.secondary
    ) {
        Text(
            stringResource(R.string.paid_badge),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSecondary,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
        )
    }
}

/** 会员 / 购买 / 支持页跳转按钮（RSS podcast:funding）。 */
@Composable
private fun FundingLink(label: String, onOpen: () -> Unit) {
    val text = label.ifBlank { stringResource(R.string.funding_default) }.let { if (it.length > 16) it.take(15) + "…" else it }
    OutlinedButton(onClick = onOpen) {
        Icon(Icons.AutoMirrored.Rounded.OpenInNew, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(text)
    }
}
