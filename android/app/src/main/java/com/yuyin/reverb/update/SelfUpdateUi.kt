package com.yuyin.reverb.update

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import kotlin.math.roundToInt

/**
 * 自更新的唯一一处界面。与 [SelfUpdate] 同在 `src/main`(两 flavor 合并前它在
 * `src/default`,商店那份空壳的包里连这几串文案都不存在 —— 资源不跟随 `BuildConfig` 常量,
 * 见 H70;合并之后只有一份包、一套文案,见 H205)。
 *
 * 形态选 `AlertDialog`(与设置页那几条二次确认同款),因为它是**一次决定**:
 * 下 / 不下、装 / 不装,不需要页面、也不需要常驻入口。
 */
@Composable
fun SelfUpdateHost() {
    val state by SelfUpdate.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    when (val s = state) {
        // 这三条不是弹窗:它们是设置页「检查更新」那一行的读数(检查中 / 已最新 / 没问到)。
        // 主动查的反馈写在行下面比弹一个只有「知道了」的窗更省事,而且不打断正在做的事。
        SelfUpdate.UpdateState.Idle,
        SelfUpdate.UpdateState.Checking,
        is SelfUpdate.UpdateState.UpToDate,
        SelfUpdate.UpdateState.CheckFailed -> Unit

        is SelfUpdate.UpdateState.AskCellular -> AlertDialog(
            onDismissRequest = { SelfUpdate.dismiss(s.rel) },
            title = { Text(updateTitle(s.rel)) },
            text = { Text(stringResource(R.string.update_ask_cellular, sizeText(s.rel.size))) },
            confirmButton = {
                TextButton(onClick = { SelfUpdate.beginDownload(s.rel) }) {
                    Text(stringResource(R.string.update_action_cellular))
                }
            },
            dismissButton = {
                TextButton(onClick = { SelfUpdate.dismiss(s.rel) }) {
                    Text(stringResource(R.string.update_action_later))
                }
            }
        )

        is SelfUpdate.UpdateState.Downloading -> AlertDialog(
            // 下载中不给"点外部就取消":误触一次就白下几十 MB,只有明确按「以后再说」才停
            onDismissRequest = { },
            title = { Text(updateTitle(s.rel)) },
            text = {
                Text(stringResource(R.string.update_downloading, s.percent))
                LinearProgressIndicator(progress = { s.percent / 100f })
            },
            confirmButton = {
                TextButton(onClick = { SelfUpdate.dismiss(s.rel) }) {
                    Text(stringResource(R.string.update_action_later))
                }
            }
        )

        is SelfUpdate.UpdateState.Ready -> AlertDialog(
            onDismissRequest = { SelfUpdate.dismiss(s.rel) },
            title = { Text(updateTitle(s.rel)) },
            text = { Text(stringResource(R.string.update_ready, sizeText(s.file.length()))) },
            confirmButton = {
                TextButton(onClick = {
                    when (SelfUpdate.install(context, s.rel)) {
                        // 没授权:先把用户送到那一页,回来再点一次「立即安装」就行
                        SelfUpdate.InstallHandoff.NeedPermission ->
                            SelfUpdate.openInstallPermissionPage(context)

                        // 文件没了 / 本机没有能装包的组件:弹窗留着说同一句话没有意义
                        SelfUpdate.InstallHandoff.Lost, SelfUpdate.InstallHandoff.NotFound ->
                            SelfUpdate.reset()

                        SelfUpdate.InstallHandoff.Started -> Unit
                    }
                }) { Text(stringResource(R.string.update_action_install)) }
            },
            dismissButton = {
                TextButton(onClick = { SelfUpdate.dismiss(s.rel) }) {
                    Text(stringResource(R.string.update_action_later))
                }
            }
        )

        is SelfUpdate.UpdateState.Failed -> AlertDialog(
            onDismissRequest = { SelfUpdate.reset() },
            title = { Text(stringResource(R.string.update_failed_title)) },
            text = { Text(stringResource(R.string.update_failed_text)) },
            confirmButton = {
                TextButton(onClick = { SelfUpdate.beginDownload(s.rel) }) {
                    Text(stringResource(R.string.update_action_retry))
                }
            },
            dismissButton = {
                TextButton(onClick = { SelfUpdate.dismiss(s.rel) }) {
                    Text(stringResource(R.string.update_action_later))
                }
            }
        )
    }
}

/**
 * 标题按「是不是同版本重出包」分两句话。
 *
 * 原来只有「发现新版本 %1$s」一句,而 digest 那条判据引进来之后会出现**版本名与本机相同**的更新,
 * 那时照原句念出来就是「发现新版本 1.0.6」而用户手里正是 1.0.6 —— 一句看起来自相矛盾的话。
 * 这句改成「这一版有新的安装包」,把"字节换过"这件事说清楚,而不是假装版本号动了。
 */
@Composable
private fun updateTitle(rel: SelfUpdate.Release): String = stringResource(
    if (rel.republished) R.string.update_title_repack else R.string.update_title,
    rel.tag
)


/// 只在自更新弹窗里用,所以不共用设置页那个 `private human`。
private fun sizeText(bytes: Long): String {
    if (bytes <= 0L) return "?"
    val mb = bytes / 1024.0 / 1024.0
    return if (mb >= 1f) "${mb.roundToInt()} MB" else "${(bytes / 1024.0).roundToInt()} KB"
}
