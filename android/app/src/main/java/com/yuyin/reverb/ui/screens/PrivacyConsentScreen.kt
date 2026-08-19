package com.yuyin.reverb.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.yuyin.reverb.R

/**
 * 首次启动的隐私政策告知与同意页。
 *
 * 为什么必须有:《平台合规指引》7.5 要求首次启动即以显著方式提示用户阅读隐私政策，且
 * **在用户同意之前不得申请任何个人信息或权限**。此前本应用在 MainActivity.onCreate
 * 里就连了 PlaybackService（→ 创建 ExoPlayer → media3 内部读系统网络信息），
 * 又在 ReverbApp.onCreate 里排了 WorkManager 周期任务（同样会读网络状态），
 * 两处都发生在同意之前 —— 应用市场据此不通过（"应用获取用户信息：SSID"）。
 *
 * 因此这一页是**硬门**:未同意时整个界面树只有这一页，被门控的组件一个都不启动。
 * 「不同意」直接退出应用 —— 本应用没有任何可以脱离网络使用的核心功能可退让，
 * 与其给一个残缺状态，不如说清楚。
 */
@Composable
fun PrivacyConsentScreen(onAccept: () -> Unit, onDecline: () -> Unit) {
    val context = LocalContext.current
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 28.dp, vertical = 36.dp)
        ) {
            Text(
                stringResource(R.string.privacy_consent_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold
            )
            Spacer(Modifier.height(18.dp))
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
            ) {
                Text(
                    stringResource(R.string.privacy_consent_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(Modifier.height(12.dp))
            TextButton(onClick = {
                // 完整政策挂在官网。此处用系统浏览器打开，不内置 WebView。
                runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(context.getString(R.string.privacy_url)))
                    )
                }
            }) {
                Text(stringResource(R.string.privacy_read_full))
            }
            Spacer(Modifier.height(4.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = onDecline) {
                    Text(
                        stringResource(R.string.privacy_decline),
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(Modifier.height(0.dp))
                Button(onClick = onAccept) {
                    Text(stringResource(R.string.privacy_accept))
                }
            }
        }
    }
}
