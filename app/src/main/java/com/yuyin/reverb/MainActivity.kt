package com.yuyin.reverb

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.yuyin.reverb.util.LocaleUtil
import androidx.compose.runtime.getValue
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.ReverbRoot
import com.yuyin.reverb.ui.theme.ReverbTheme

class MainActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocaleUtil.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        PlayerController.init(applicationContext)

        val settings = (application as ReverbApp).container.settingsStore
        setContent {
            val mode by settings.themeMode.collectAsStateWithLifecycle()
            val fontScale by settings.fontScale.collectAsStateWithLifecycle()
            val accent by settings.accentIndex.collectAsStateWithLifecycle()
            ReverbTheme(mode = mode, fontScale = fontScale, accentIndex = accent) {
                ReverbRoot()
            }
        }
    }
}
