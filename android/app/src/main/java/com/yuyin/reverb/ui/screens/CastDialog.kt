package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.cast.CastController
import com.yuyin.reverb.cast.CastDevice
import com.yuyin.reverb.data.model.Episode

/**
 * 投播弹层:发现设备 → 点一台开始投 → 正在投放时可停止。
 *
 * 状态全部在 [CastController] 里(应用级),这里只做呈现:
 * 弹层关掉不影响投放,下次打开会看到同一台设备仍在投放。
 */
@Composable
fun CastDialog(cast: CastController, episode: Episode, onDismiss: () -> Unit) {
    val state by cast.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { cast.ensureScan() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.cast_title)) },
        text = {
            when (val s = state) {
                CastController.State.Idle, CastController.State.Scanning -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(stringResource(R.string.cast_scanning))
                    }
                }
                is CastController.State.Connecting -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(stringResource(R.string.cast_connecting, s.device.name))
                    }
                }
                is CastController.State.Casting -> {
                    Text(stringResource(R.string.cast_casting_to, s.device.name))
                }
                is CastController.State.Found -> {
                    if (s.devices.isEmpty()) {
                        Text(stringResource(R.string.cast_none))
                    } else {
                        Column(
                            Modifier
                                .heightIn(max = 280.dp)
                                .verticalScroll(rememberScrollState())
                        ) {
                            s.devices.forEach { d ->
                                DeviceRow(d) { cast.cast(d, episode) }
                            }
                        }
                    }
                }
                CastController.State.Failed -> Text(stringResource(R.string.cast_failed))
            }
        },
        confirmButton = {
            when (state) {
                is CastController.State.Casting -> TextButton(onClick = { cast.stop() }) {
                    Text(stringResource(R.string.cast_stop))
                }
                is CastController.State.Found -> {
                    val none = (state as CastController.State.Found).devices.isEmpty()
                    if (none) TextButton(onClick = { cast.scan() }) {
                        Text(stringResource(R.string.action_retry))
                    }
                }
                CastController.State.Failed -> TextButton(onClick = { cast.scan() }) {
                    Text(stringResource(R.string.action_retry))
                }
                else -> Unit
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        }
    )
}

@Composable
private fun DeviceRow(device: CastDevice, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(device.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (device.model.isNotBlank()) {
                Text(
                    device.model,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}
