package com.yuyin.reverb.ui.components

import android.media.audiofx.Visualizer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import kotlin.math.hypot

private const val BANDS = 28

/**
 * 真实频谱采集:附着到全局输出混音 [Visualizer](session 0),把 FFT 转成一组 0..1 的频段能量。
 *
 * 需 RECORD_AUDIO 权限(调用方须已确保授权)。返回的 [State] 值在关闭/无权限/采集失败时为 null,
 * 此时可视化回退到程序化墨纹。随 [active] 变化自动创建与释放,不泄漏系统资源。
 */
@Composable
fun rememberSpectrumState(active: Boolean): State<FloatArray?> {
    val state = remember { mutableStateOf<FloatArray?>(null) }
    DisposableEffect(active) {
        if (!active) {
            state.value = null
            onDispose { }
        } else {
            var vis: Visualizer? = null
            try {
                vis = Visualizer(0).apply {
                    enabled = false // 配置期间必须先禁用
                    captureSize = Visualizer.getCaptureSizeRange()[1] // 取最大精度
                    setDataCaptureListener(
                        object : Visualizer.OnDataCaptureListener {
                            override fun onWaveFormDataCapture(v: Visualizer?, wave: ByteArray?, rate: Int) {}
                            override fun onFftDataCapture(v: Visualizer?, fft: ByteArray?, rate: Int) {
                                if (fft != null) state.value = toBands(fft)
                            }
                        },
                        Visualizer.getMaxCaptureRate() / 2, // 采样率
                        false, // 不要波形
                        true   // 要 FFT
                    )
                    enabled = true
                }
            } catch (e: Exception) {
                runCatching { vis?.release() }
                vis = null
                state.value = null
            }
            val captured = vis
            onDispose {
                runCatching {
                    captured?.enabled = false
                    captured?.release()
                }
                state.value = null
            }
        }
    }
    return state
}

/**
 * FFT 字节流 → [BANDS] 个频段能量(0..1)。
 * fft 布局:fft[0]=直流实部, fft[1]=奈奎斯特, 其后为 (实,虚) 对;幅值取模后按对数分桶并归一化。
 */
private fun toBands(fft: ByteArray): FloatArray {
    val n = fft.size / 2
    if (n <= 1) return FloatArray(BANDS)
    val mags = FloatArray(n)
    var max = 1f
    for (k in 1 until n) {
        val re = fft[2 * k].toFloat()
        val im = fft[2 * k + 1].toFloat()
        val m = hypot(re, im)
        mags[k] = m
        if (m > max) max = m
    }
    val out = FloatArray(BANDS)
    for (b in 0 until BANDS) {
        // 低频段窄、高频段宽(近似对数),更贴合听感
        val lo = (Math.pow(n.toDouble(), b.toDouble() / BANDS)).toInt().coerceIn(1, n - 1)
        val hi = (Math.pow(n.toDouble(), (b + 1.0) / BANDS)).toInt().coerceIn(lo + 1, n)
        var sum = 0f
        for (k in lo until hi) sum += mags[k]
        val avg = sum / (hi - lo)
        out[b] = (avg / max).coerceIn(0f, 1f)
    }
    return out
}
