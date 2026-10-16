package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.coverChannelJump

/**
 * 待播(up next):手动排的接下来播放列表,点击单集直接跳播,可上下移动、移除、清空。
 *
 * 标题栏里那颗「清空」**只在独立页出现**:音阁里它是内嵌的一「段」,那颗动作由
 * [QueueBody] 的调用方(分段条右端)去摆,与「历史」段同一个走法。
 */
@Composable
fun QueueScreen(onBack: () -> Unit) {
    val queue by PlayerController.userQueue.collectAsStateWithLifecycle()
    // 与音阁「待播」段那颗清空同一个走法:先确认再清(一刀切没有找回办法)。
    var askClear by remember { mutableStateOf(false) }

    if (askClear) {
        AlertDialog(
            onDismissRequest = { askClear = false },
            title = { Text(stringResource(R.string.queue_title)) },
            text = { Text(stringResource(R.string.confirm_clear_queue)) },
            confirmButton = {
                TextButton(onClick = {
                    PlayerController.clearQueue()
                    askClear = false
                }) { Text(stringResource(R.string.action_clear_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { askClear = false }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 4.dp, top = 24.dp, end = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.a11y_back))
            }
            Spacer(Modifier.width(4.dp))
            Text(
                stringResource(R.string.queue_title),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f)
            )
            if (queue.isNotEmpty()) {
                TextButton(onClick = { askClear = true }) {
                    Text(stringResource(R.string.action_clear_confirm))
                }
            }
        }
        QueueBody()
    }
}

/**
 * 队列主体(不含标题栏),供音阁「待播」段内嵌复用 —— 与 [InboxBody] 同一个形状。
 *
 * ⚠️ 这里 collect 的是 `PlayerController.userQueue`(StateFlow)。它在用户增删队列时整份替换,
 * 不是逐帧变,所以挂在段这一层不会像鸿蒙那侧的睡眠倒计时一样把整页打回重建
 * (那条坑记在 H64 / H77,判据是"它多久变一次")。
 */
@Composable
fun QueueBody(topPad: Dp = Dp(0f)) {
    val queue by PlayerController.userQueue.collectAsStateWithLifecycle()
    val openChannelLabel = stringResource(R.string.a11y_open_channel)

    if (queue.isEmpty()) {
        EmptyHint(stringResource(R.string.queue_empty))
        return
    }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = topPad,
            bottom = 24.dp + LocalGlassBottomPad.current
        )
    ) {
        itemsIndexed(queue, key = { _, ep -> ep.id }) { index, ep ->
            // 封面单独可点 → 这一集所属频道页(判据与列表行同一条,见 Components.kt coverChannelJump)。
            // 待播这一列不做批量勾选:它**就是**队列本身,再"加入待播"是空操作。
            val jump = coverChannelJump(ep)
            Row(
                Modifier
                    .fillMaxWidth()
                    // 整行可点跳播;行内 IconButton 会自行消费点击,不会冒泡到这里
                    .clickable { PlayerController.playFromQueue(ep.id) }
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box {
                    Artwork(ep.artworkUrl, size = 44, corner = 8)
                    if (jump != null) {
                        // ⚠️ 覆盖层写在包住 Artwork 的 Box 里、用 matchParentSize:
                        // 做成 Row 的兄弟节点会多占一格,把 12dp 那道缝的排布顶歪。
                        Box(
                            Modifier
                                .matchParentSize()
                                .clip(RoundedCornerShape(8.dp))
                                .clickable(onClick = jump)
                                .semantics { contentDescription = openChannelLabel }
                        )
                    }
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        ep.title,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onBackground,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                    if (ep.podcastTitle.isNotBlank()) {
                        Text(
                            ep.podcastTitle,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                    IconButton(
                        onClick = { PlayerController.move(index, index - 1) },
                        enabled = index > 0,
                        modifier = Modifier.size(40.dp)
                    ) {
                        Icon(
                            Icons.Rounded.KeyboardArrowUp,
                            contentDescription = stringResource(R.string.a11y_queue_up),
                            tint = if (index > 0) MaterialTheme.colorScheme.onSurfaceVariant
                            else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f)
                        )
                    }
                    IconButton(
                        onClick = { PlayerController.move(index, index + 1) },
                        enabled = index < queue.lastIndex,
                        modifier = Modifier.size(40.dp)
                    ) {
                        Icon(
                            Icons.Rounded.KeyboardArrowDown,
                            contentDescription = stringResource(R.string.a11y_queue_down),
                            tint = if (index < queue.lastIndex) MaterialTheme.colorScheme.onSurfaceVariant
                            else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f)
                        )
                    }
                    IconButton(
                        onClick = { PlayerController.removeFromQueue(ep.id) },
                        modifier = Modifier.size(40.dp)
                    ) {
                        Icon(
                            Icons.Rounded.Close,
                            contentDescription = stringResource(R.string.a11y_queue_remove),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}
