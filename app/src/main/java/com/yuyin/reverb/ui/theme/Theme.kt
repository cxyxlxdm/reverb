package com.yuyin.reverb.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Density
import androidx.core.view.WindowCompat

// 深色（水墨）底色
val InkBackground = Color(0xFF0E1416)
val InkSurface = Color(0xFF161D20)
val InkSurfaceHi = Color(0xFF1F2A2E)
// 浅色（宣纸）底色
val PaperBackground = Color(0xFFF6F2E9)
val PaperSurface = Color(0xFFFCFAF4)
val PaperSurfaceHi = Color(0xFFECE6D8)

val Celadon = Color(0xFF7FD1C0)
val CeladonDim = Color(0xFF4E9C8D)
val Gold = Color(0xFFE9C879)

/** 配色方案：primaryDark 用于深色、primaryLight 用于浅色；secondary 为「梁金」强调色。 */
data class AccentPalette(
    val label: String,
    val primaryDark: Color,
    val primaryLight: Color,
    val secondary: Color
)

val ACCENTS = listOf(
    AccentPalette("青瓷", Color(0xFF7FD1C0), Color(0xFF3E8E7E), Gold),
    AccentPalette("黛蓝", Color(0xFF86B9E0), Color(0xFF2E6E99), Gold),
    AccentPalette("绯红", Color(0xFFE3A0A0), Color(0xFFB0524F), Gold),
    AccentPalette("竹青", Color(0xFF9FD08A), Color(0xFF4E8E43), Gold)
)

private fun darkScheme(a: AccentPalette) = darkColorScheme(
    primary = a.primaryDark,
    onPrimary = Color(0xFF06201B),
    secondary = a.secondary,
    onSecondary = Color(0xFF2A2100),
    // 用强调色对水墨底做低比例混色，使背景随配色微妙变化
    background = lerp(InkBackground, a.primaryDark, 0.05f),
    onBackground = Color(0xFFEAF0EF),
    surface = lerp(InkSurface, a.primaryDark, 0.06f),
    onSurface = Color(0xFFEAF0EF),
    surfaceVariant = lerp(InkSurfaceHi, a.primaryDark, 0.12f),
    onSurfaceVariant = Color(0xFF95A3A0),
    outline = lerp(Color(0xFF33413F), a.primaryDark, 0.15f)
)

// 纯白主题:白底 + 冷灰中性色,区别于暖调「宣纸」浅色
private fun whiteScheme(a: AccentPalette) = lightColorScheme(
    primary = a.primaryLight,
    onPrimary = Color(0xFFFFFFFF),
    secondary = Color(0xFF9A7A2E),
    onSecondary = Color(0xFFFFFFFF),
    background = Color(0xFFFFFFFF),
    onBackground = Color(0xFF1A1C1E),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1A1C1E),
    surfaceVariant = Color(0xFFEEF1F3),
    onSurfaceVariant = Color(0xFF5A6169),
    outline = Color(0xFFD5DADE)
)

private fun lightScheme(a: AccentPalette) = lightColorScheme(
    primary = a.primaryLight,
    onPrimary = Color(0xFFFFFFFF),
    secondary = Color(0xFF9A7A2E),
    onSecondary = Color(0xFFFFFFFF),
    background = lerp(PaperBackground, a.primaryLight, 0.05f),
    onBackground = Color(0xFF221C12),
    surface = lerp(PaperSurface, a.primaryLight, 0.04f),
    onSurface = Color(0xFF221C12),
    surfaceVariant = lerp(PaperSurfaceHi, a.primaryLight, 0.12f),
    onSurfaceVariant = Color(0xFF6B6255),
    outline = lerp(Color(0xFFCFC6B4), a.primaryLight, 0.2f)
)

/**
 * @param mode 0 跟随系统 / 1 浅色（宣纸）/ 2 深色（水墨）/ 3 纯白
 * @param fontScale 字号倍率（作用于全局 sp 文本）
 * @param accentIndex [ACCENTS] 索引
 */
@Composable
fun ReverbTheme(
    mode: Int,
    fontScale: Float,
    accentIndex: Int,
    content: @Composable () -> Unit
) {
    val dark = when (mode) {
        1 -> false
        2 -> true
        3 -> false
        else -> isSystemInDarkTheme()
    }
    val accent = ACCENTS.getOrElse(accentIndex) { ACCENTS[0] }
    val scheme = when {
        mode == 3 -> whiteScheme(accent)
        dark -> darkScheme(accent)
        else -> lightScheme(accent)
    }

    // 状态栏/导航栏图标随主题反色：浅色主题用深色图标，深色主题用浅色图标
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            val controller = WindowCompat.getInsetsController(window, view)
            controller.isAppearanceLightStatusBars = !dark
            controller.isAppearanceLightNavigationBars = !dark
        }
    }

    val base = LocalDensity.current
    CompositionLocalProvider(
        LocalDensity provides Density(density = base.density, fontScale = base.fontScale * fontScale)
    ) {
        MaterialTheme(
            colorScheme = scheme,
            typography = Typography(),
            content = content
        )
    }
}
