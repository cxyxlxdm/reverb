package com.yuyin.reverb.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.yuyin.reverb.R

/**
 * 私有订阅源(HTTP Basic)的用户名/密码输入框。
 *
 * 只在服务端回 401 时弹(见 `PodcastRepository.authRequired`),平时不出现 ——
 * 绝大多数源不需要凭据,把它做成常驻设置项等于让所有人多填一格。
 *
 * 凭据由调用方落进 `FeedAuthStore`(本机文件、不进备份、退订即删),这里只管收集。
 * `failed = true` 是"刚提交过一对、又被打回",此时把错误提示显示出来,
 * 而不是静默再弹一次同样的空框(那样看起来像按钮没反应)。
 */
@Composable
fun FeedAuthDialog(
    feedUrl: String,
    failed: Boolean = false,
    onDismiss: () -> Unit,
    onSubmit: (username: String, password: String) -> Unit
) {
    val host = remember(feedUrl) {
        runCatching { java.net.URI(feedUrl).host }.getOrNull() ?: feedUrl
    }
    var username by remember(feedUrl) { mutableStateOf("") }
    var password by remember(feedUrl) { mutableStateOf("") }
    val canSubmit = username.isNotBlank()

    fun submit() {
        if (canSubmit) onSubmit(username.trim(), password)
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feed_auth_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    stringResource(R.string.feed_auth_message, host),
                    style = MaterialTheme.typography.bodyMedium
                )
                if (failed) {
                    Text(
                        stringResource(R.string.feed_auth_wrong),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.feed_auth_user)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next)
                )
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.feed_auth_pass)) },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Password,
                        imeAction = ImeAction.Done
                    ),
                    keyboardActions = KeyboardActions(onDone = { submit() })
                )
            }
        },
        confirmButton = {
            TextButton(enabled = canSubmit, onClick = { submit() }) {
                Text(stringResource(R.string.feed_auth_save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.feed_auth_cancel))
            }
        }
    )
}
