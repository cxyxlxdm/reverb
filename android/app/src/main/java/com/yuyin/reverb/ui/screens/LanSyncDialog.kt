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
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    when (state) {
                        is LanSyncState.Confirm -> {
                            TextButton(onClick = { controller.confirm(false) }) {
                                Text(stringResource(R.string.lan_cancel))
                            }
                            TextButton(onClick = { controller.confirm(true) }) {
                                Text(stringResource(R.string.lan_confirm_accept))
                            }
                        }

                        is LanSyncState.Done -> {
                            TextButton(onClick = { onDismiss() }) {
                                Text(stringResource(R.string.lan_close))
                            }
                            TextButton(onClick = { controller.stop(); controller.start() }) {
                                Text(stringResource(R.string.lan_again))
                            }
                        }

                        is LanSyncState.Failed -> {
                            TextButton(onClick = { onDismiss() }) {
                                Text(stringResource(R.string.lan_close))
                            }
                            TextButton(onClick = { controller.stop(); controller.start() }) {
                                Text(stringResource(R.string.lan_retry))
                            }
                        }

                        else -> TextButton(onClick = { onDismiss() }) {
                            Text(stringResource(R.string.lan_close))
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
            TextButton(onClick = onConnect) { Text(stringResource(R.string.lan_connect)) }
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
