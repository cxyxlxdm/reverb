package com.yuyin.reverb.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** tab 项规格:图标与文案。数量由父级决定(当前恒为 2,与鸿蒙 GlassTabBar 一致)。 */
data class GlassTabSpec(val label: String, val icon: ImageVector)

/**
 * 底部导航:悬浮玻璃长椭圆 —— 与鸿蒙端 GlassTabBar 同一套设计(装机验收基准)。
 *
 * 与 Material NavigationBar 的差异:整条玻璃收进左右 12dp 的胶囊(radius 28 = 高度一半)
 * + 投影给出 z 轴高度;84×44 药丸罩住选中项,点击/拖拽/松手都走弹簧(落位有惯性);
 * 按下即预选 —— 药丸先滑到手指所在的 tab,松手页面才切;按下期间整个 tab 内容
 * (图标+文字)放大 1.2,松手弹回。
 *
 * **Android 没有 ArkUI backgroundEffect 那种区域级实时背景模糊**(窗口级
 * setBackgroundBlurRadius 只糊壁纸;三方 blur 库被仓库「不接三方 SDK」约束挡住),
 * 玻璃感靠半透明 surface 打底 + 发丝描边 + 投影近似。透明度取 0.85 而非鸿蒙的 0.6:
 * 没有模糊时太透会让文字压在滚动内容上读不清。
 *
 * 内容能透到栏下的前提:MainShell 已改为叠层布局,各页列表用 [LocalGlassBottomPad]
 * 让出底部余量。
 *
 * 手势全走 Box 层一个 tap 探测 + 一个横拖探测,子项**不放 clickable**:
 * detectTapGestures 会消费 down,若子项也有 clickable,兄弟叠层/祖先层先到者
 * 会把子项的 awaitFirstDown(requireUnconsumed=true) 饿死。无障碍改由 semantics
 * 的 role/selected/onClick 提供,不占指针事件。
 *
 * 弹簧参数对齐鸿蒙 springMotion:response 0.3/0.22 ≈ stiffness 440/816
 * (stiffness = (2π/response)²)。
 */
@Composable
fun GlassNavBar(
    tabs: List<GlassTabSpec>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    // press/drag 回调存活于整个 pointerInput 生命周期,必须读最新值:
    // 捕获旧 selected 会把提交送到上一个 tab 上
    val currentSelected by rememberUpdatedState(selected)
    val currentOnSelect by rememberUpdatedState(onSelect)

    val barH = 56.dp
    val pillH = 44.dp
    val pillW = with(density) { 84.dp.toPx() }
    val settleSpec = spring<Float>(dampingRatio = 0.75f, stiffness = 440f)

    var barWpx by remember { mutableFloatStateOf(0f) }
    /** 非拖拽期的药丸位置(弹簧驱动);拖拽帧改读 dragX,松手先 snapTo 再回弹 */
    val pillX = remember { Animatable(0f) }
    var dragging by remember { mutableStateOf(false) }
    var dragStartX by remember { mutableFloatStateOf(0f) }
    var dragAccum by remember { mutableFloatStateOf(0f) }
    /** 按下预选的 tab;-1 = 无 */
    var previewIdx by remember { mutableIntStateOf(-1) }
    /** 拖拽/按下期间按接近度高亮的项;-1 = 跟 selected 走 */
    var nearIdx by remember { mutableIntStateOf(-1) }
    /** 指尖按在栏上期间为 true:胶囊与命中项放大、染色加深 */
    var interacting by remember { mutableStateOf(false) }
    var placed by remember { mutableStateOf(false) }
    var previewJob by remember { mutableStateOf<Job?>(null) }

    fun halfW(): Float = barWpx / 2f
    fun pillXFor(idx: Int): Float = idx * halfW() + (halfW() - pillW) / 2f
    fun tabAt(x: Float): Int {
        if (halfW() <= 0f) return 0
        // 均分槽位直接 floor:x 落在哪个槽就是哪个 tab。原先的 (x + halfW/2)/halfW
        // 算的是「离 halfW 的整数倍最近」,而槽中心在半个 halfW 处 —— 结果是发现
        // tab 自己的右半边全部被判成音阁:点已选中的发现,药丸预览跳去音阁、松手
        // 连页面也切过去(H90 用户反馈)。
        return (x / halfW()).toInt().coerceIn(0, (tabs.size - 1).coerceAtLeast(0))
    }

    // 选中项变化(含首次量宽)→ 药丸弹簧吸过去。拖拽期间不插手,松手路径自己收。
    LaunchedEffect(barWpx, selected) {
        if (barWpx <= 0f) return@LaunchedEffect
        if (!placed) {
            pillX.snapTo(pillXFor(selected))
            placed = true
        } else if (!dragging) {
            pillX.animateTo(pillXFor(selected), settleSpec)
        }
    }

    val pillScale by animateFloatAsState(
        targetValue = if (interacting) 1.2f else 1f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 816f),
        label = "pillScale"
    )
    val pillAlpha by animateFloatAsState(
        targetValue = if (interacting) 0.28f else 0.15f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 816f),
        label = "pillAlpha"
    )

    /// 松手 / 被系统取消:按药丸当前位置吸附最近项。commit=false(取消)只回弹。
    fun settle(commit: Boolean) {
        if (!dragging) return
        dragging = false
        nearIdx = -1
        previewIdx = -1
        val target = tabAt(dragStartX + dragAccum)
        scope.launch {
            pillX.snapTo(dragStartX + dragAccum)
            if (commit && target != currentSelected) {
                // 药丸不在这里动:selected 一变,LaunchedEffect 会从当前绘制位弹簧过去
                currentOnSelect(target)
            } else {
                pillX.animateTo(pillXFor(currentSelected), settleSpec)
            }
        }
    }

    Box(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(barH)
                // 投影给 z 轴高度:整条栏"浮"在页面之上,而非贴底的一块平面
                .shadow(elevation = 8.dp, shape = RoundedCornerShape(28.dp), clip = false)
                .clip(RoundedCornerShape(28.dp))
                // 玻璃打底:半透明 surface + 发丝描边(透明度取舍见类注释)
                .background(colorScheme.surface.copy(alpha = 0.85f))
                .border(0.8.dp, colorScheme.outline.copy(alpha = 0.45f), RoundedCornerShape(28.dp))
                .onSizeChanged { barWpx = it.width.toFloat() }
                // 横拖:药丸 1:1 跟手,松手按位置吸附(装机社区手感)
                .pointerInput(tabs.size) {
                    detectHorizontalDragGestures(
                        onDragStart = { _ ->
                            if (halfW() > 0f) {
                                // 从胶囊当前位置继续拖(按下预选可能已挪动它),别回到选中位;
                                // 预览动画若还在跑,先掐掉,免得跟 snapTo 抢同一个 Animatable
                                previewJob?.cancel()
                                previewJob = null
                                dragging = true
                                dragAccum = 0f
                                dragStartX = pillX.value
                            }
                        },
                        onDragEnd = { settle(commit = true) },
                        onDragCancel = { settle(commit = false) },
                        onHorizontalDrag = { change, amount ->
                            if (dragging) {
                                change.consume()
                                dragAccum += amount
                                val lo = pillXFor(0)
                                val hi = pillXFor(tabs.size - 1)
                                dragAccum = dragAccum.coerceIn(lo - dragStartX, hi - dragStartX)
                                nearIdx = tabAt(dragStartX + dragAccum)
                            }
                        }
                    )
                }
                // 点按:按下预选 + 松手提交,全在这一个探测里(子项无 clickable,见类注释)
                .pointerInput(tabs.size) {
                    detectTapGestures(
                        onPress = { off ->
                            interacting = true
                            val idx = tabAt(off.x)
                            if (idx != currentSelected) {
                                previewIdx = idx
                                nearIdx = idx
                                previewJob = scope.launch {
                                    pillX.animateTo(pillXFor(idx), settleSpec)
                                }
                            }
                            val released = tryAwaitRelease()
                            interacting = false
                            if (released && !dragging) {
                                val commitIdx = if (previewIdx >= 0) previewIdx else idx
                                previewIdx = -1
                                nearIdx = -1
                                if (commitIdx != currentSelected) currentOnSelect(commitIdx)
                            } else if (!released && !dragging) {
                                // 拖拽/系统取消:预览作废,药丸回选中位
                                previewIdx = -1
                                nearIdx = -1
                                previewJob = scope.launch {
                                    pillX.animateTo(pillXFor(currentSelected), settleSpec)
                                }
                            }
                            // released 且 dragging:提交归拖拽路径的 settle,这里不动
                            previewIdx = -1
                        }
                    )
                }
        ) {
            // 药丸(画在内容之下):位移拖拽期 1:1 跟手、平时弹簧;放大与染色走按压弹簧。
            Box(
                Modifier
                    .offset {
                        val x = if (dragging) dragStartX + dragAccum else pillX.value
                        IntOffset(x.roundToInt(), (barH - pillH).roundToPx() / 2)
                    }
                    .size(width = 84.dp, height = pillH)
                    .graphicsLayer {
                        scaleX = pillScale
                        scaleY = pillScale
                    }
                    .background(colorScheme.primary.copy(alpha = pillAlpha), RoundedCornerShape(22.dp))
                    .border(0.8.dp, colorScheme.primary.copy(alpha = 0.18f), RoundedCornerShape(22.dp))
            )

            Row(modifier = Modifier.fillMaxSize()) {
                tabs.forEachIndexed { idx, tab ->
                    val active = if (nearIdx >= 0) nearIdx else currentSelected
                    val itemScale by animateFloatAsState(
                        targetValue = if (interacting && active == idx) 1.2f else 1f,
                        animationSpec = spring(dampingRatio = 0.8f, stiffness = 816f),
                        label = "tabScale$idx"
                    )
                    // 图标与文字间距收得很紧(space 2):间距一大,胶囊要罩住整块内容
                    // 就得跟着变高,观感发"胖"(对齐鸿蒙同款注释)
                    Column(
                        Modifier
                            .weight(1f)
                            .fillMaxSize()
                            .semantics {
                                role = Role.Tab
                                // `selected` 在外层是函数参数(Int),这里必须显式 this.
                                // 指到 SemanticsPropertyReceiver 的扩展属性,否则变成给参数赋值
                                this.selected = currentSelected == idx
                                onClick(label = tab.label) {
                                    currentOnSelect(idx)
                                    true
                                }
                            }
                            .graphicsLayer {
                                scaleX = itemScale
                                scaleY = itemScale
                            },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Icon(
                            tab.icon,
                            contentDescription = null,
                            tint = if (active == idx) colorScheme.primary else colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(22.dp)
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tab.label,
                            style = MaterialTheme.typography.labelSmall,
                            color = if (active == idx) colorScheme.primary else colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}
