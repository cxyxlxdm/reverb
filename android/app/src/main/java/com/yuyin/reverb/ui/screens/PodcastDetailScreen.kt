package com.yuyin.reverb.ui.screens

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.Surface
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.PodcastState
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.EpisodeListItem
import com.yuyin.reverb.ui.components.PlayModeButton
import com.yuyin.reverb.ui.components.formatListenDuration
import com.yuyin.reverb.ui.share.ShareCards
import com.yuyin.reverb.ui.podcastViewModel
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PodcastDetailScreen(feedUrl: String, onBack: () -> Unit) {
    val vm = podcastViewModel()
    LaunchedEffect(feedUrl) { vm.load(feedUrl) }

    val context = LocalContext.current
    val container = (context.applicationContext as ReverbApp).container
    val subs by container.subscriptionStore.subscriptions.collectAsStateWithLifecycle()
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val downloadStates by DownloadManager.states.collectAsStateWithLifecycle()
    val history by container.historyStore.history.collectAsStateWithLifecycle()
    val listenStats by container.listenStatsStore.stats.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var sharing by remember { mutableStateOf(false) }
    // 删除下载是不可逆操作,点删除图标先弹确认 —— 与「音阁 · 下载」同一颗框、同一句文案。
    // 此前只有下载段有确认,详情页漏了(鸿蒙同样漏,本轮两端一起补)。
    var pendingDelete by remember { mutableStateOf<Episode?>(null) }
    val state = vm.state

    // 下拉刷新:强制重新拉取最新单集。与发现页同款:加最短可见时长,让刷新
    // 有可感知的过程而非一闪而过(finally 兜底,异常也收起指示器)。
    val pullState = rememberPullToRefreshState()
    if (pullState.isRefreshing) {
        LaunchedEffect(true) {
            try {
                coroutineScope {
                    val fetch = async { vm.refresh(feedUrl) }
                    delay(600)
                    fetch.await()
                }
            } finally {
                pullState.endRefresh()
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier
                .fillMaxWidth()
                // 外层 FullScreen 已做 systemBarsPadding,这里只补 12dp 呼吸感 ——
                // 与播放页同值(播放页这个间距用户看着舒服);原先 24dp 叠加在
                // 状态栏让位之上,返回键离通知栏明显过远(H90 用户反馈)。
                .padding(start = 4.dp, top = 12.dp, end = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.a11y_back))
            }
            Spacer(Modifier.weight(1f))
            if (state is PodcastState.Loaded) {
                IconButton(
                    enabled = !sharing,
                    onClick = {
                        sharing = true
                        scope.launch {
                            try {
                                val podcast = state.podcast
                                val bitmap = ShareCards.channelCard(context, podcast)
                                ShareCards.share(
                                    context,
                                    bitmap,
                                    "reverb-channel-${kotlin.math.abs(podcast.feedUrl.hashCode())}.png",
                                    context.getString(R.string.channel_share)
                                )
                            } catch (_: Exception) {
                                Toast.makeText(context, R.string.share_failed, Toast.LENGTH_SHORT).show()
                            } finally {
                                sharing = false
                            }
                        }
                    }
                ) {
                    Icon(Icons.Rounded.Share, contentDescription = stringResource(R.string.channel_share))
                }
            }
        }

        Box(
            Modifier
                .fillMaxSize()
                // 与发现页同款:裁掉静止态越界露出的指示器(它会画在内容区上方的
                // 顶栏区域)。此前以为「详情页残留界内裁不掉」是未验证的误判 ——
                // 残留在 Box 顶边之外,裁剪即消失,标准容器可以照用。
                .clipToBounds()
                .nestedScroll(pullState.nestedScrollConnection)
        ) {
            when (val s = state) {
                PodcastState.Loading -> LoadingBox()
                PodcastState.Error -> EmptyHint(stringResource(R.string.load_failed))
                is PodcastState.Loaded -> {
                    val subscribed = subs.any { it.feedUrl == s.podcast.feedUrl }
                    // 听歌时长存的是这个 key(既有口径,不能改)
                    val channelKey = s.podcast.feedUrl.ifBlank { s.podcast.title }
                    // 这一列的身份,两处共用:行起播时随 playQueue 传下去(装机靠日志里
                    // `tag='…'` 认出点的是哪一列),右端那颗模式按钮也按它读写**本列**的模式。
                    // 用 feedUrl 而不是频道名 —— 同名频道不少,撞了名既分不出日志,也会
                    // 让两个频道共用同一格模式。
                    // 加前缀是为了**永不可能**撞上音阁那三个分段名(TAG_INBOX / TAG_FAV / TAG_DL)。
                    val listTag = "podcast:$channelKey"
                    LazyColumn(
                        Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(bottom = 24.dp)
                    ) {
                        // 展示的是缓存、刷新尚未成功 —— 明确告诉用户内容可能不是最新的
                        if (s.staleAt != 0L) {
                            item { OfflineNotice(s.staleAt) }
                        }
                        item {
                            val listenedMs = listenStats.firstOrNull { it.key == channelKey }?.listenedMs ?: 0L
                            PodcastDetailHeader(
                                podcast = s.podcast,
                                episodes = s.episodes,
                                listTag = listTag,
                                listenedMs = listenedMs,
                                subscribed = subscribed,
                                onSubscribe = { container.subscriptionStore.toggle(s.podcast) }
                            )
                        }
                        items(s.episodes) { ep ->
                            val played = history.firstOrNull { it.episode.id == ep.id }?.played ?: false
                            EpisodeListItem(
                                episode = ep,
                                isCurrent = current?.id == ep.id,
                                isPlaying = isPlaying,
                                onPlay = { PlayerController.playOrToggle(ep, s.episodes, listTag) },
                                downloadStatus = downloadStates[ep.id],
                                onDownload = { DownloadManager.download(ep) },
                                onDeleteDownload = { pendingDelete = ep },
                                played = played,
                                onTogglePlayed = { container.historyStore.markPlayed(ep.id, !played) },
                                onPlayNext = { PlayerController.playNext(ep) },
                                onEnqueue = { PlayerController.enqueue(ep) },
                                // 详情页行内「加入播放列表」键(对齐鸿蒙):浏览场景一步入队
                                showQueueAdd = true
                            )
                        }
                    }
                }
            }
            // 与发现页/收件箱同款的标准容器(跟手箭头 + 灰圆),静止态越界部分
            // 由上面的 clipToBounds 裁掉,不残留
            PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
        }
    }

    pendingDelete?.let { ep ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.download_delete_title)) },
            text = { Text(stringResource(R.string.download_delete_message, ep.title)) },
            confirmButton = {
                TextButton(onClick = {
                    DownloadManager.delete(ep.id)
                    pendingDelete = null
                }) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }
}

@Composable
private fun PodcastDetailHeader(
    podcast: Podcast,
    /** 这一列的单集:「共 N 集」那一行要显示条数。 */
    episodes: List<Episode>,
    /** 这一列的身份:模式按钮按它读写本列那一格(与行起播传的是同一个串)。 */
    listTag: String,
    listenedMs: Long,
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
        // 单集数这一行是这一列的标题行,所以模式按钮挂在它右端 —— 与音阁「段条右端」
        // 同一处语义(动作属于那一段列表,不属于页面顶栏)。
        // 起播没有专门那颗按钮:点下面任意一集就播这一整列(见 Components.kt `PlayModeButton`)。
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                stringResource(R.string.episode_count, episodes.size),
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onBackground
            )
            PlayModeButton(listTag)
        }
        if (listenedMs > 0) {
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.listened_prefix, formatListenDuration(listenedMs / 1000)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
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
