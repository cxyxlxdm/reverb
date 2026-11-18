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
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/**
 * 播放条点 X 的**粒子消散**层(2026-10-25,参考用户视频的第二版形态;第一版做成了
 * 高度塌陷,被用户否掉 —— 视频里是整条同时化成小方块碎片,以向上抛射为主四散,
 * 无重力、先快后慢,0.6~1.0s 内淡出散尽,**散完之后**下方内容才上移补位)。
 *
 * 物理全部用**解析式**而不是逐帧积分:`p(t) = p0 + v0·(1−e^(−kt))/k`。
 * 好处是三端(Android/鸿蒙/macOS)可以用同一套公式各自绘制,免掉积分误差与
 * 状态同步;参数(k=2.4/s,寿命 600~1000ms,速度分布)三端对齐,观感一致。
 *
 * 颜色不采样真实位图(三端拿快照的时序与成本都不值),按**位置分区近似**:
 * 左端约 28%(收束球槽+封面)用深色簇,中段(文字)用灰,右端(按钮)浅底混少量
 * primary,顶部 2dp(进度线)整条 primary。装机读的是"整条碎成它自己颜色的渣",
 * 分区粒度足够。
 *
 * ⚠️ 这一层只画粒子,不管布局:条子本体在 X 点击时被置成透明但**占位保留**,
 * 由调用方在约 430ms 后才 `PlayerController.close()` 收布局(对应视频"散完才补位")。
 *
 * ⚠️ 调用方给的矩形必须是**胶囊本体**(`MiniPlayer` 里那个圆角 Box 的 `boundsInRoot()`),
 * 不能是外面那层带 `padding(bottom = lift)` 的盒子 —— 2026-11-16 装机反馈"变成小方块、
 * 数量很少"就是这个错:tab 外壳那份量到的是 56dp 胶囊 + 64dp 让位 ≈ 330px,
 * 8.5 行网格摊在 330px 上,单块 14~39px、总数只剩 ~230(见 H285)。
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

/** 一粒碎片。速度单位 px/s;[delayMs] 起算,[maxLifeMs] 内按解析式飞,寿命外不画。 */
private class Shard(
    val x0: Float, val y0: Float,
    val vx: Float, val vy: Float,
    val sizePx: Float,
    /** 宽高比 0.8~1.2:全是等边方块会读成"对齐的棋盘格",这一点随机就散了。 */
    val aspect: Float,
    val color: Color,
    val maxLifeMs: Int,
    val delayMs: Int,
)

private const val DAMP_K = 2.4f          // 指数阻尼 1/s:先快后慢(2026-10-26 调慢,原 3.2)
private const val LIFE_MIN = 600   // 2026-10-26 调慢一档(原 380~620):装机反馈散得太快
private const val LIFE_MAX = 1000
private const val TOTAL_MS = LIFE_MAX + 90 // 层的最长存活,超了清场
/**
 * 条高切成几行。**这一档与鸿蒙 `DissolveParticles.ets` 逐字对齐(8.5)**,
 * 换算到 Pixel 3 是 step = 154px / 8.5 ≈ 18px、约 440 粒。
 *
 * 2026-11-16 由 11 退回 8.5 的经过:那天先按"11 行 + 出生接近满格"调过一版,
 * 修掉了数量问题(rect 量错,见 [DissolveLayer]),但装机录屏第一帧仍是**铺满的马赛克墙**,
 * 与鸿蒙的"碎屑云"不是一回事。对照鸿蒙源码才看清差在哪:那边碎片只有格子的 0.35~0.7,
 * 出生就带 0~60ms 延迟 —— **粒子小于格距**,所以第一帧读成"条子散成一把渣",
 * 而不是"条子换了个质地"。密度靠行数给,不是靠把碎片画满格子。
 * 再往上调要按 800~1000 粒/帧估绘制成本(硬规矩 6)。
 */
private const val ROWS = 8.5f

@Composable
fun DissolveLayer(request: DissolveRequest, primary: Color, modifier: Modifier = Modifier) {
    /**
     * ⚠️ 调用方给的是**根坐标**里的矩形(`boundsInRoot()`),而本层挂在一个带
     * `statusBarsPadding()` 的容器里 —— DrawScope 的原点在那个容器的左上角,
     * 两者差一个状态栏高(Pixel 3 实测 ≈66px)。不换算的话整群碎片会被整体画低一截,
     * 看起来像"从条子下面的栏里冒出来"。这里量一次自己的根坐标,画的时候减掉。
     */
    var origin by remember { mutableStateOf(Offset.Zero) }
    // 粒子调色板从当前主题取一次:背景系/主色/深色簇(封面区)。
    // 深色簇写死三阶而不是从 surface 派生 —— 视频里封面碎片的"深"远深于背景的浅,
    // 派生会在深色主题里融成一片。
    val palette = remember {
        arrayOf(
            0xFF3A3F4A.toInt(), 0xFF2E333D.toInt(), 0xFF4A4E57.toInt()
        ).map { Color(it) }
    }
    val tick = request.tick
    // ⚠️ 撒粒子必须在**组合期**(remember)完成,不能放进 LaunchedEffect:
    // 点 X 那一下同时置 ghost(条子 alpha=0)与 tick++,LaunchedEffect 要等这一帧组合+布局
    // 之后才跑,粒子再等下一帧才画出 —— 中间会闪一帧"条子没了、什么都没有"
    // (2026-11-16 录屏逐帧读到过这一帧)。放在 remember 里,两者同一帧生效。
    val shards = remember(tick, primary) {
        if (tick == 0) emptyList()
        else request.rect.takeIf { it.width > 0f && it.height > 0f }
            ?.let { spawn(it, palette, primary) } ?: emptyList()
    }
    var elapsedMs by remember(tick) { mutableLongStateOf(0L) }

    LaunchedEffect(tick, primary) {
        if (shards.isEmpty()) return@LaunchedEffect
        val t0 = System.nanoTime()
        while (true) {
            withFrameNanos { }
            elapsedMs = (System.nanoTime() - t0) / 1_000_000L
            // 超过最长寿命就不必再逐帧唤醒了;碎片本身按 [Shard.maxLifeMs] 自然画空
            if (elapsedMs > TOTAL_MS) break
        }
    }

    // modifier 必须让这一层**铺满宿主容器**:粒子飞散范围远大于条子本身,
    // 只盖条子会把向上飞的碎片裁掉。
    Canvas(modifier.onGloballyPositioned { origin = it.positionInRoot() }) {
        val t = elapsedMs
        for (s in shards) {
            drawShard(s, t, origin)
        }
    }
}

/** 速度阻尼解析式的位移:∫v0·e^(−kt) = v0·(1−e^(−kt))/k。 */
private fun dampShift(v0: Float, tSec: Float): Float = v0 * (1f - exp(-DAMP_K * tSec)) / DAMP_K

private fun DrawScope.drawShard(s: Shard, elapsedMs: Long, origin: Offset) {
    val lifeMs = elapsedMs - s.delayMs
    if (lifeMs < 0 || lifeMs > s.maxLifeMs) return
    val tSec = lifeMs / 1000f
    val prog = lifeMs.toFloat() / s.maxLifeMs
    // 末段加速消失(幂次>1 前段稳后段垮),碎片还随寿命缩到 65%
    val alpha = (1f - prog).let { it * it * kotlin.math.sqrt(it) } // ≈ (1-p)^2.5
    if (alpha <= 0.02f) return
    val side = s.sizePx * (1f - 0.35f * prog)
    val halfW = side * s.aspect / 2f
    val halfH = side / 2f
    drawRect(
        color = s.color.copy(alpha = alpha),
        topLeft = Offset(
            s.x0 + dampShift(s.vx, tSec) - halfW - origin.x,
            s.y0 + dampShift(s.vy, tSec) - halfH - origin.y
        ),
        size = androidx.compose.ui.geometry.Size(halfW * 2, halfH * 2),
    )
}

/**
 * 胶囊矩形按 8.5 行网格撒碎片。分区比例对应 [MiniPlayer] 的内部布局
 * (左端封面 / 中段两行字 / 右端三枚按钮+X)。
 *
 * 尺寸与配色**照抄鸿蒙那边**(`DissolveParticles.ets` spawn):中段 0.35~0.70 × 步长、
 * 封面 0.55~1.0,出生带 0~60ms 延迟。关键在"碎片小于格距" —— 第一帧读成一把碎屑,
 * 而不是铺满格子的马赛克;早先按"接近满格 (0.85~1.1)"试过,正是用户看到的"小方块"。
 *
 * 配色同理:鸿蒙中段一律 #8A8D93(文字与图标的颜色)。这里曾经把大部分格子调成胶囊底色
 * #232B2D 压亮度 —— 那是为"满格铺满"打的补丁;碎片变小后灰云的视觉亮度自己就降下来了,
 * 于是退回鸿蒙的原配色,免得两边灰度不一致。
 */
private fun spawn(rect: Rect, darks: List<Color>, primary: Color): List<Shard> {
    val rnd = Random.Default
    val step = rect.height / ROWS
    val out = ArrayList<Shard>(700)
    var y = rect.top
    while (y < rect.bottom) {
        var x = rect.left
        while (x < rect.right) {
            // 每粒在格心附近抖 ±1/4 格:规则网格即便尺寸随机,横向也会读出"对齐的列"
            val px = (x + step * 0.5f + (rnd.nextFloat() - 0.5f) * step * 0.5f)
                .coerceIn(rect.left, rect.right)
            val py = (y + step * 0.5f + (rnd.nextFloat() - 0.5f) * step * 0.3f)
                .coerceIn(rect.top, rect.bottom)
            val relX = (px - rect.left) / rect.width
            val relY = (py - rect.top) / rect.height
            // 胶囊两端是半圆(半径 = 高/2):角上这几格的中心落在圆外,留着会在第一帧
            // 露出"直角矩形"的四角 —— 那正是本层要替掉的那条条子的形状。
            val rad = rect.height / 2f
            val edge = when {
                px < rect.left + rad -> rect.left + rad - px
                px > rect.right - rad -> px - (rect.right - rad)
                else -> 0f
            }
            val dy = py - (rect.top + rad)
            val inCapsule = edge <= 0f || edge * edge + dy * dy <= rad * rad
            val tone = rnd.nextFloat()
            val color = when {
                relY < 0.06f -> primary                       // 进度线那一条
                relX < 0.30f -> darks[rnd.nextInt(darks.size)] // 封面:深色簇
                relX > 0.76f && tone < 0.3f -> primary        // 按钮区少量主色碎片
                else -> Color(0xFF8A8D93)                     // 文字/图标:浅灰
            }
            val up = rnd.nextFloat() < 0.7f              // 70% 向上抛,30% 全向
            val ang = if (up)
                Math.toRadians((-(120 - rnd.nextDouble() * 60)).toDouble()) // -120°~-60°
            else
                Math.toRadians(rnd.nextDouble() * 360.0)
            val speed = if (up) 200f + rnd.nextFloat() * 360f else 100f + rnd.nextFloat() * 220f
            if (inCapsule) {
                out += Shard(
                    x0 = px, y0 = py,
                    vx = speed * cos(ang).toFloat(),
                    vy = speed * sin(ang).toFloat(),
                    sizePx = step * (if (relX < 0.30f) 0.55f + rnd.nextFloat() * 0.45f // 封面碎片稍大
                                     else 0.35f + rnd.nextFloat() * 0.35f),
                    aspect = 0.8f + rnd.nextFloat() * 0.4f,
                    color = color,
                    maxLifeMs = LIFE_MIN + rnd.nextInt(LIFE_MAX - LIFE_MIN),
                    delayMs = rnd.nextInt(60),
                )
            }
            x += step
        }
        y += step
    }
    android.util.Log.i("Dissolve", "spawn ${out.size} shards rect=$rect step=$step")
    return out
}
