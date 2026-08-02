package com.yuyin.reverb.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.PI
import kotlin.math.sin

/**
 * 水墨声波:程序化的正弦墨纹 + 中心墨晕,随播放状态「呼吸流动」,呼应「余音绕梁」。
 *
 * 纯本地绘制、零权限——不采集真实音频(那需要 Visualizer + RECORD_AUDIO,与本应用
 * 「零配置、不要吓人权限」的取向冲突),而是以播放/暂停驱动振幅与相位的流动。
 */
private data class Ribbon(val ampFactor: Float, val freq: Float, val phase: Float, val dir: Float, val alpha: Float)

private val ribbons = listOf(
    Ribbon(ampFactor = 1.0f, freq = 1.6f, phase = 0.0f, dir = 1f, alpha = 0.22f),
    Ribbon(ampFactor = 0.7f, freq = 2.3f, phase = 1.1f, dir = -1f, alpha = 0.16f),
    Ribbon(ampFactor = 0.45f, freq = 3.1f, phase = 2.4f, dir = 1f, alpha = 0.11f)
)

@Composable
fun InkWave(playing: Boolean, color: Color, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "ink")
    val twoPi = (2 * PI).toFloat()
    // 两条不同速度的相位,叠加出更自然的流动感
    val phaseA by transition.animateFloat(
        initialValue = 0f, targetValue = twoPi,
        animationSpec = infiniteRepeatable(tween(6200, easing = LinearEasing)), label = "phaseA"
    )
    val phaseB by transition.animateFloat(
        initialValue = 0f, targetValue = twoPi,
        animationSpec = infiniteRepeatable(tween(9700, easing = LinearEasing)), label = "phaseB"
    )
    // 播放时振幅饱满,暂停时缓缓收束成近乎静止的细线
    val amp by animateFloatAsState(
        targetValue = if (playing) 1f else 0.12f,
        animationSpec = tween(1200), label = "amp"
    )

    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val midY = h / 2f

        // 中心墨晕:随振幅微弱明灭
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(color.copy(alpha = 0.10f * amp), Color.Transparent),
                center = Offset(w / 2f, midY),
                radius = w * 0.55f
            ),
            radius = w * 0.55f,
            center = Offset(w / 2f, midY)
        )

        val steps = 56
        for ((idx, r) in ribbons.withIndex()) {
            val phase = if (idx % 2 == 0) phaseA else phaseB
            val amplitude = h * 0.13f * amp * r.ampFactor
            val path = Path()
            for (i in 0..steps) {
                val fx = i / steps.toFloat()
                val x = w * fx
                val y = midY + amplitude * sin(r.freq * fx * twoPi + r.dir * phase + r.phase)
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(
                path = path,
                color = color.copy(alpha = r.alpha),
                style = Stroke(width = 2.2f)
            )
        }
    }
}
