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
import androidx.compose.foundation.layout.systemBarsPadding
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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
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
                // **必须自己避让系统栏**:本页渲染在 ReverbRoot 之外(未同意时不进主界面树),
                // 吃不到 ReverbRoot 根节点那个 systemBarsPadding()。漏了的表现是
                // 标题紧贴状态栏、和时间/信号挤在一起。
                .systemBarsPadding()
                .padding(horizontal = 28.dp, vertical = 28.dp)
        ) {
            // 左标题 + 下方一道 40×3 的「梁金」细线,与 app 里 ScreenHeader 同一形态。
            //
            // 试过居中,但底部两个按钮是靠右的 —— 那样一页里就有三种对齐
            // (标题居中 / 正文居左 / 按钮居右),反而散。居左只剩两种:
            // 内容左、操作右,也是对话框类界面的常规排法。
            Text(
                stringResource(R.string.privacy_consent_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold
            )
            Spacer(Modifier.height(12.dp))
            Box(
                Modifier
                    .width(40.dp)
                    .height(3.dp)
                    .background(MaterialTheme.colorScheme.secondary, RoundedCornerShape(2.dp))
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
            Spacer(Modifier.height(8.dp))
            // 两个按钮都靠右,之间留 12dp。
            //
            // 这个数值试过三档:原先 Arrangement.End 配 `Spacer(Modifier.height(0.dp))` ——
            // 横向布局里 height 什么也不做,于是文字与药丸只隔 6dp,挤在一起;
            // 换 SpaceBetween 撑满整行又太散(文字到药丸约 131dp)。
            // spacedBy(12dp) 落在中间:TextButton 自带 12dp 内边距,叠起来视觉间隙约 24dp。
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = onDecline) {
                    Text(
                        stringResource(R.string.privacy_decline),
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Button(onClick = onAccept) {
                    Text(stringResource(R.string.privacy_accept))
                }
            }
        }
    }
}
