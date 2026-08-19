package com.yuyin.reverb

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
