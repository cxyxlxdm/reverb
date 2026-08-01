package com.yuyin.reverb.util

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/** 应用内语言覆盖：读取已保存的语言 tag，包一层带该 Locale 的 Context。空=跟随系统。 */
object LocaleUtil {
    fun wrap(base: Context): Context {
        val tag = base.getSharedPreferences("reverb_settings", Context.MODE_PRIVATE)
            .getString("language", "") ?: ""
        if (tag.isBlank()) return base
        val locale = Locale.forLanguageTag(tag)
        Locale.setDefault(locale)
        val config = Configuration(base.resources.configuration)
        config.setLocale(locale)
        return base.createConfigurationContext(config)
    }
}
