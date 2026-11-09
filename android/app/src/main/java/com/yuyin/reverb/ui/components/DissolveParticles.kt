package com.yuyin.reverb.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/**
 * 播放条点 X 的**粒子消散**层(2026-10-25,参考用户视频的第二版形态;第一版做成了
 * 高度塌陷,被用户否掉 —— 视频里是整条同时化成小方块碎片,以向上抛射为主四散,
 * 无重力、先快后慢,0.4~0.6s 内淡出散尽,**散完之后**下方内容才上移补位)。
 *
 * 物理全部用**解析式**而不是逐帧积分:`p(t) = p0 + v0·(1−e^(−kt))/k`。
 * 好处是三端(Android/鸿蒙/macOS)可以用同一套公式各自绘制,免掉积分误差与
 * 状态同步;参数(k=3.2/s,寿命 380~620ms,速度分布)三端对齐,观感一致。
 *
 * 颜色不采样真实位图(三端拿快照的时序与成本都不值),按**位置分区近似**:
 * 左端约 28%(收束球槽+封面)用深色簇,中段(文字)用灰,右端(按钮)浅底混少量
 * primary,顶部 2dp(进度线)整条 primary。装机读的是"整条碎成它自己颜色的渣",
 * 分区粒度足够。
 *
 * ⚠️ 这一层只画粒子,不管布局:条子本体在 X 点击时被置成透明但**占位保留**,
 * 由调用方在约 430ms 后才 `PlayerController.close()` 收布局(对应视频"散完才补位")。
 */
class DissolveRequest {
    var tick by mutableStateOf(0)
        private set
    var rect: Rect = Rect.Zero
        private set

    fun burst(r: Rect) {
        rect = r
        tick++
    }
}

/** 一粒碎片。速度单位 px/s;[maxLifeMs] 内按解析式飞,寿命外不画。 */
private class Shard(
    val x0: Float, val y0: Float,
    val vx: Float, val vy: Float,
    val sizePx: Float,
    val color: Color,
    val maxLifeMs: Int,
    /** 出生即延迟一点入场,让散开有先后(纯观感)。 */
    val delayMs: Int = 0,
)

private const val DAMP_K = 2.4f          // 指数阻尼 1/s:先快后慢(2026-10-26 调慢,原 3.2)
private const val LIFE_MIN = 600   // 2026-10-26 调慢一档(原 380~620):装机反馈散得太快
private const val LIFE_MAX = 1000
private const val TOTAL_MS = LIFE_MAX + 90 // 层的最长存活,超了清场

@Composable
fun DissolveLayer(request: DissolveRequest, primary: Color, modifier: Modifier = Modifier) {
    var shards by remember { mutableStateOf(emptyList<Shard>()) }
    var elapsedMs by remember { mutableLongStateOf(0L) }
    // 粒子调色板从当前主题取一次:背景系/主色/深色簇(封面区)。
    // 深色簇写死两阶而不是从 surface 派生 —— 视频里封面碎片的"深"远深于背景的浅,
    // 派生会在深色主题里融成一片。
    val palette = remember {
        arrayOf(
            0xFF3A3F4A.toInt(), 0xFF2E333D.toInt(), 0xFF4A4E57.toInt()
        ).map { Color(it) }
    }

    LaunchedEffect(request.tick, primary) {
        if (request.tick == 0) return@LaunchedEffect
        val r = request.rect
        if (r.width <= 0f || r.height <= 0f) return@LaunchedEffect
        shards = spawn(r, palette, primary)
        val t0 = System.nanoTime()
        while (true) {
            withFrameNanos { }
            elapsedMs = (System.nanoTime() - t0) / 1_000_000L
            if (elapsedMs > TOTAL_MS) {
                shards = emptyList()
                break
            }
        }
    }

    // modifier 必须让这一层**铺满宿主容器**:粒子飞散范围远大于条子本身,
    // 只盖条子会把向上飞的碎片裁掉。
    Canvas(modifier) {
        val t = elapsedMs
        for (s in shards) {
            val lt = t - s.delayMs
            if (lt < 0 || lt > s.maxLifeMs) continue
            drawShard(s, lt)
        }
    }
}

/** 速度阻尼解析式的位移:∫v0·e^(−kt) = v0·(1−e^(−kt))/k。 */
private fun dampShift(v0: Float, tSec: Float): Float = v0 * (1f - exp(-DAMP_K * tSec)) / DAMP_K

private fun DrawScope.drawShard(s: Shard, lifeMs: Long) {
    val tSec = lifeMs / 1000f
    val prog = lifeMs.toFloat() / s.maxLifeMs
    // 末段加速消失(幂次>1 前段稳后段垮),碎片还随寿命缩到 65%
    val alpha = (1f - prog).let { it * it * kotlin.math.sqrt(it) } // ≈ (1-p)^2.5
    if (alpha <= 0.02f) return
    val half = s.sizePx * (1f - 0.35f * prog) / 2f
    drawRect(
        color = s.color.copy(alpha = alpha),
        topLeft = Offset(s.x0 + dampShift(s.vx, tSec) - half, s.y0 + dampShift(s.vy, tSec) - half),
        size = androidx.compose.ui.geometry.Size(half * 2, half * 2),
    )
}

/**
 * 播条矩形按 ~6dp 网格撒碎片。分区比例对应 [MiniPlayer] 的内部布局
 * (左端球槽+封面 / 中段两行字 / 右端三枚按钮+X)。
 */
private fun spawn(rect: Rect, darks: List<Color>, primary: Color): List<Shard> {
    val rnd = Random.Default
    val step = rect.height / 8.5f // 条高 56dp(2026-11-09 起两态同高)⇒ 步长约 6.6dp;别的几何按条高比例
    val out = ArrayList<Shard>(1400)
    var y = rect.top
    while (y < rect.bottom) {
        var x = rect.left
        while (x < rect.right) {
            val px = x + step * 0.5f
            val py = y + step * 0.5f
            val relX = (px - rect.left) / rect.width
            val relY = (py - rect.top) / rect.height
            val color = when {
                relY < 0.06f -> primary                     // 进度线那一条
                relX < 0.30f -> darks[rnd.nextInt(darks.size)] // 封面/球槽:深色簇
                relX > 0.76f && rnd.nextFloat() < 0.3f -> primary   // 按钮区少量主色碎片
                else -> Color(0xFF8A8D93)                // 文字/背景:灰系
            }
            val up = rnd.nextFloat() < 0.7f              // 70% 向上抛,30% 全向
            val ang = if (up)
                Math.toRadians((-(120 - rnd.nextDouble() * 60)).toDouble()) // -120°~-60°
            else
                Math.toRadians(rnd.nextDouble() * 360.0)
            val speed = if (up) 200f + rnd.nextFloat() * 360f else 100f + rnd.nextFloat() * 220f
            out += Shard(
                x0 = px, y0 = py,
                vx = speed * cos(ang).toFloat(),
                vy = speed * sin(ang).toFloat(),
                sizePx = step * (if (relX < 0.30f) 0.55f + rnd.nextFloat() * 0.45f // 封面碎片稍大
                                 else 0.35f + rnd.nextFloat() * 0.35f),
                color = color,
                maxLifeMs = LIFE_MIN + rnd.nextInt(LIFE_MAX - LIFE_MIN),
                delayMs = rnd.nextInt(60),
            )
            x += step
        }
        y += step
    }
    return out
}
