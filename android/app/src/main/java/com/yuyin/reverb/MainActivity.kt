package com.yuyin.reverb

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.yuyin.reverb.data.local.JsonWriter
import com.yuyin.reverb.util.LocaleUtil
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.ReverbRoot
import com.yuyin.reverb.ui.screens.PrivacyConsentScreen
import com.yuyin.reverb.ui.theme.ReverbTheme
import com.yuyin.reverb.update.SelfUpdate

class MainActivity : ComponentActivity() {
    // 每次收到「打开播放页」意图就自增，ReverbRoot 监听此信号并导航
    private var openPlayerSignal by mutableIntStateOf(0)

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocaleUtil.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (intent?.getBooleanExtra(EXTRA_OPEN_PLAYER, false) == true) openPlayerSignal++

        val app = application as ReverbApp
        val settings = app.container.settingsStore
        // 已同意过就照常启动被门控的组件;未同意则**一个都不启动**(理由见 PrivacyConsentScreen)
        if (settings.privacyAccepted.value) startGatedComponents()

        setContent {
            val mode by settings.themeMode.collectAsStateWithLifecycle()
            val fontScale by settings.fontScale.collectAsStateWithLifecycle()
            val accent by settings.accentIndex.collectAsStateWithLifecycle()
            val accepted by settings.privacyAccepted.collectAsStateWithLifecycle()
            ReverbTheme(mode = mode, fontScale = fontScale, accentIndex = accent) {
                if (accepted) {
                    ReverbRoot(openPlayerSignal = openPlayerSignal)
                } else {
                    PrivacyConsentScreen(
                        onAccept = {
                            settings.acceptPrivacy()
                            startGatedComponents()
                        },
                        onDecline = { finishAndRemoveTask() }
                    )
                }
            }
        }
    }

    /**
     * 退到后台时把去抖中的持久化补完。
     *
     * `JsonWriter` 把「整份写回」类的落盘改成了 400ms 去抖 + IO 线程(否则播放中每 5 秒
     * 就在主线程上构造并写掉几百 KB,见 TROUBLESHOOTING H65)。代价是进程被杀时可能丢
     * 窗口内的最后一次写 —— 所以这里必须同步落一次。
     * 放在 `onStop` 而不是 `onPause`:切后台一定经过 onStop,而 onPause 会被弹窗之类频繁触发。
     * 三端同一处理:鸿蒙在 `EntryAbility.onBackground`、macOS 在 `willTerminate`。
     */
    override fun onStop() {
        super.onStop()
        JsonWriter.flush()
    }

    /**
     * 启动那些会读取系统网络信息的组件。**只能在用户同意隐私政策之后调用。**
     *
     * - PlayerController.init 会连上 PlaybackService → 创建 ExoPlayer,
     *   media3 内部的 NetworkTypeObserver 会调 ConnectivityManager.getActiveNetworkInfo();
     * - 订阅更新的 WorkManager 周期任务带网络约束,其约束追踪器同样会读网络状态。
     * 应用市场把这类调用判定为「获取 SSID」,要求必须在同意之后才发生。
     */
    private fun startGatedComponents() {
        PlayerController.init(applicationContext)
        val container = (application as ReverbApp).container
        if (container.settingsStore.updatesEnabled.value) {
            ReverbApp.scheduleFeedUpdates(this)
        }
        // 应用内更新:每次进程只检测一次([SelfUpdate.start] 内部挡重)。放在这里而不是
        // Application.onCreate —— 它要读网络状态判「是不是 Wi-Fi」,与上面两条同一个门。
        // 合并前商店那份是空实现,现在只有一份包、这一条对所有分发都生效(见 SelfUpdate.kt 与 H205)。
        SelfUpdate.start(applicationContext, container.httpClient)
    }

    // 服务已在运行、Activity 处于 SINGLE_TOP 复用时，新意图走这里
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(EXTRA_OPEN_PLAYER, false)) openPlayerSignal++
    }

    companion object {
        const val EXTRA_OPEN_PLAYER = "open_player"
    }
}
