package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.sync.LanHandoffState
import com.yuyin.reverb.sync.LanSyncController
import com.yuyin.reverb.sync.LanSyncFail
import com.yuyin.reverb.sync.LanSyncStage
import com.yuyin.reverb.sync.LanSyncState
import androidx.compose.foundation.clickable
import androidx.compose.ui.res.stringResource

/**
 * 「局域网同步」面板。
 *
 * 三个界面决定叠在一起:
 * 1. **发现**:自动列出同一 Wi-Fi 下的设备;**同时**永远给出手动地址输入 ——
 *    AP 隔离 / 访客网络 / 企业 Wi-Fi 会让组播根本到不了对端,发现失败不是功能坏了。
 * 2. **配对**:六位数字要人眼比对。这一层加密没有证书体系,配对码就是唯一的中间人判据。
 * 3. **结果**:只报**新增条数**(合并前后之差),不把远端条数当新增混报。
 *
 * 对话框打开即开始监听、关闭即停止 —— P0 不在后台常驻。
 */
@Composable
fun LanSyncDialog(controller: LanSyncController, onDismiss: () -> Unit) {
    val state by controller.state.collectAsStateWithLifecycle()
    val handoff by controller.handoff.collectAsStateWithLifecycle()
    var manual by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(Unit) { controller.start() }
    DisposableEffect(Unit) { onDispose { controller.stop() } }

    // 配对与传输中不允许点外面关掉:那会把 socket 抽走,另一端看到的是"网络中断"。
    val locked = state is LanSyncState.Confirm || state is LanSyncState.Syncing
    Dialog(
        onDismissRequest = { if (!locked) onDismiss() },
        properties = DialogProperties(
            dismissOnBackPress = !locked,
            dismissOnClickOutside = !locked
        )
    ) {
        Surface(
            shape = MaterialTheme.shapes.extraLarge,
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 6.dp
        ) {
            Column(
                Modifier
                    .padding(20.dp)
                    .heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
            ) {
                Text(stringResource(R.string.lan_title), style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(12.dp))

                when (val s = state) {
                    is LanSyncState.Idle -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.height(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(stringResource(R.string.lan_waiting), style = MaterialTheme.typography.bodyMedium)
                    }

                    is LanSyncState.Listening -> ListeningBody(
                        state = s,
                        manual = manual,
                        onManual = { manual = it },
                        onConnect = { controller.connectTo(manual) },
                        onPeer = { controller.connectTo(it) }
                    )

                    is LanSyncState.Connecting -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.height(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(
                            stringResource(R.string.lan_connecting, s.target),
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }

                    is LanSyncState.Confirm -> ConfirmBody(s)

                    is LanSyncState.Syncing -> Column {
                        Text(
                            stringResource(R.string.lan_syncing, s.peerName),
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            when (s.stage) {
                                LanSyncStage.SENDING -> stringResource(R.string.lan_stage_sending)
                                LanSyncStage.RECEIVING -> stringResource(R.string.lan_stage_receiving)
                                LanSyncStage.MERGING -> stringResource(R.string.lan_stage_merging)
                            },
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(Modifier.height(8.dp))
                        LinearProgressIndicator(
                            progress = { s.percent / 100f },
                            modifier = Modifier.fillMaxWidth()
                        )
                    }

                    is LanSyncState.Done -> Column {
                        Text(stringResource(R.string.lan_done_title), style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            stringResource(R.string.lan_done_with, s.result.peerName),
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Spacer(Modifier.height(6.dp))
                        if (s.result.total > 0) {
                            Text(
                                stringResource(
                                    R.string.lan_done_added,
                                    s.result.subscriptions,
                                    s.result.favorites,
                                    s.result.stamps,
                                    s.result.notes,
                                    s.result.history,
                                    s.result.stats
                                ),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.primary
                            )
                        } else {
                            Text(
                                stringResource(R.string.lan_done_nothing),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        // 同步之后的加时赛:同一台对端、同一条连接,不重新配对。
                        if (handoff.available || handoff.note != null) {
                            Spacer(Modifier.height(14.dp))
                            HandoffBody(handoff, onTake = { controller.takePlayback() })
                        }
                    }

                    is LanSyncState.Failed -> Column {
                        Text(stringResource(R.string.lan_failed_title), style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(4.dp))
                        Text(failText(s.fail), style = MaterialTheme.typography.bodyMedium)
                        if (s.detail.isNotBlank()) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                s.detail,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                Spacer(Modifier.height(12.dp))
                Text(
                    stringResource(R.string.lan_scope),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Spacer(Modifier.height(8.dp))
                // 「关闭 / 取消」是次要动作:鸿蒙那侧一直用 onSurfaceVariant(灰),
                // 而 TextButton 默认取主色,于是 Android 的「关闭」是蓝的、鸿蒙是灰的。
                // 2026-11-13 用户装机对比后要求统一成灰;主要动作(一致/再同步一次)仍用主色。
                val secondary = MaterialTheme.colorScheme.onSurfaceVariant
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    when (state) {
                        is LanSyncState.Confirm -> {
                            TextButton(onClick = { controller.confirm(false) }) {
                                Text(stringResource(R.string.lan_cancel), color = secondary)
                            }
                            TextButton(onClick = { controller.confirm(true) }) {
                                Text(stringResource(R.string.lan_confirm_accept))
                            }
                        }

                        is LanSyncState.Done -> {
                            TextButton(onClick = { onDismiss() }) {
                                Text(stringResource(R.string.lan_close), color = secondary)
                            }
                            TextButton(onClick = { controller.stop(); controller.start() }) {
                                Text(stringResource(R.string.lan_again))
                            }
                        }

                        is LanSyncState.Failed -> {
                            TextButton(onClick = { onDismiss() }) {
                                Text(stringResource(R.string.lan_close), color = secondary)
                            }
                            TextButton(onClick = { controller.stop(); controller.start() }) {
                                Text(stringResource(R.string.lan_retry))
                            }
                        }

                        else -> TextButton(onClick = { onDismiss() }) {
                            Text(stringResource(R.string.lan_close), color = secondary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ListeningBody(
    state: LanSyncState.Listening,
    manual: String,
    onManual: (String) -> Unit,
    onConnect: () -> Unit,
    onPeer: (String) -> Unit
) {
    Column {
        Text(
            stringResource(R.string.lan_own_name, state.deviceName),
            style = MaterialTheme.typography.bodyMedium
        )
        if (state.addresses.isEmpty()) {
            Text(
                stringResource(R.string.lan_no_wifi),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error
            )
        } else {
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.lan_own_address),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            for (address in state.addresses) {
                Text(
                    address,
                    style = MaterialTheme.typography.bodyLarge,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        Spacer(Modifier.height(14.dp))
        Text(
            stringResource(R.string.lan_peers),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary
        )
        if (state.peers.isEmpty()) {
            Text(
                stringResource(R.string.lan_no_peers),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            // 光列名字没人知道可以点 —— 与鸿蒙同一句提示(lan_peers_hint)。
            Text(
                stringResource(R.string.lan_peers_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            for (peer in state.peers) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onPeer(peer.address) }
                        .padding(vertical = 8.dp)
                ) {
                    Column(Modifier.fillMaxWidth()) {
                        Text(peer.name, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            peer.address,
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = manual,
            onValueChange = onManual,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            label = { Text(stringResource(R.string.lan_manual_hint)) }
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            // 空串时置灰不可点:先前点下去只会得到「地址格式不对:」,一句没有信息量的失败
            // (鸿蒙那边干脆静默 return,看起来像按钮坏了)。两端统一成"没地址就不可点"。
            TextButton(onClick = onConnect, enabled = manual.isNotBlank()) {
                Text(stringResource(R.string.lan_connect))
            }
        }
        Text(
            stringResource(R.string.lan_tip),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun ConfirmBody(state: LanSyncState.Confirm) {
    Column {
        Text(stringResource(R.string.lan_confirm_title), style = MaterialTheme.typography.titleMedium)
        Text(
            stringResource(R.string.lan_confirm_peer, state.peerName),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(12.dp))
        Text(
            state.code.chunked(3).joinToString(" "),
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
            letterSpacing = 6.sp,
            color = MaterialTheme.colorScheme.primary
        )
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.lan_confirm_body), style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun HandoffBody(state: LanHandoffState, onTake: () -> Unit) {
    Column {
        val hint = state.peerHint
        if (hint != null) {
            Text(
                stringResource(
                    if (hint.playing) R.string.lan_handoff_playing else R.string.lan_handoff_paused
                ),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary
            )
            Spacer(Modifier.height(2.dp))
            val clock = clockText(hint.positionMs)
            Text(
                "《${hint.episode.title}》 · " +
                    if (hint.approximate) stringResource(R.string.lan_handoff_approx, clock) else clock,
                style = MaterialTheme.typography.bodyMedium
            )
        } else {
            Text(
                stringResource(R.string.lan_handoff_none),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        state.note?.let {
            Spacer(Modifier.height(4.dp))
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        // 本机已经在放这一集(刚接手成功)时不再摆按钮 —— 按下去只会从当前位置重开一遍。
        val alreadyHere = state.localPlayingNow && state.localEpisodeId == hint?.episode?.id
        if (hint != null && !alreadyHere) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onTake, enabled = !state.takingOver) {
                    Text(
                        stringResource(
                            if (state.takingOver) R.string.lan_handoff_taking
                            else R.string.lan_handoff_take
                        )
                    )
                }
            }
        }

        Text(
            stringResource(R.string.lan_handoff_boundary),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun clockText(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    val h = total / 3600
    val m = total % 3600 / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

@Composable
private fun failText(fail: LanSyncFail): String = stringResource(
    when (fail) {
        LanSyncFail.CONNECT -> R.string.lan_fail_connect
        LanSyncFail.VERSION -> R.string.lan_fail_version
        LanSyncFail.PROTOCOL -> R.string.lan_fail_protocol
        LanSyncFail.DECRYPT -> R.string.lan_fail_decrypt
        LanSyncFail.IO -> R.string.lan_fail_io
        LanSyncFail.CANCELLED -> R.string.lan_fail_cancelled
        LanSyncFail.PEER_CANCELLED -> R.string.lan_fail_peer_cancelled
    }
)
