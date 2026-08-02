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
        PlayerController.init(applicationContext)
        if (intent?.getBooleanExtra(EXTRA_OPEN_PLAYER, false) == true) openPlayerSignal++

        val settings = (application as ReverbApp).container.settingsStore
        setContent {
            val mode by settings.themeMode.collectAsStateWithLifecycle()
            val fontScale by settings.fontScale.collectAsStateWithLifecycle()
            val accent by settings.accentIndex.collectAsStateWithLifecycle()
            ReverbTheme(mode = mode, fontScale = fontScale, accentIndex = accent) {
                ReverbRoot(openPlayerSignal = openPlayerSignal)
            }
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
