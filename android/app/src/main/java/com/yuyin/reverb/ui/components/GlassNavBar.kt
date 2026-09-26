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
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.graphics.TransformOrigin
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
 * 底部导航:悬浮玻璃长椭圆 + **放大镜式镜片胶囊**(与鸿蒙 GlassTabBar 同一套设计)。
 *
 * 两层从下到上,把「玻璃罩住内容」画成光学现象而不是一个色块:
 * 1. **基础内容**:图标+文字,正常尺寸。
 * 2. **镜片**:胶囊本体裁剪,先铺一块 [LENS_PLATE_ALPHA] 的表面色玻璃板**盖住**底下的
 *    原尺寸内容(不盖会与副本叠成重影),再画按 [LENS_MAG] 绕胶囊中心放大的内容。
 *    碰到/离开图标文字时内容明显变大,像放大镜;拖动时副本再往运动的反方向退一档
 *    ([SMEAR_LAG])、横向再拉长一档([LENS_STRETCH]),就是「拖影」。
 *
 * 曾经还有第 3 层「折射带」(比胶囊大一圈的裁剪 + 更强的放大副本)。鸿蒙装机实测它
 * **并不折射任何东西,而是整圈提亮成一块浅色光晕** —— 带 clipShape 的子节点会被单独
 * 合成,背景模糊在那一圈被重算了一遍。删掉后光晕消失,拖影改由镜片层的「滞后 + 横向
 * 拉伸」表达。Android 这侧没有同一个 bug,但两端同一套观感是本组件的前提,故一并去掉
 * (同「盖而不是挖」那次统一)。
 *
 * 为什么是"盖"而不是"挖":两端必须同一套做法,而鸿蒙那侧只有
 * `clipShape(shape)` / `maskShape(shape)` 的"只显示形内"语义(SDK 的 CommonMethod 里
 * 已无 MaskType.Exclude,挖不成孔),Android 单独用 `clipPath(Difference)` 挖孔会让
 * 两端观感分叉。代价是胶囊比真玻璃略实。
 *
 * 按下时**整条栏**一起放大到 [BAR_PRESS](不是只有被按的那个图标),胶囊自己再放大一档
 * 到 [PILL_PRESS];单个 tab 内容**不再**各自缩放 —— 放大这件事交给镜片层,两处同时做会过冲。
 *
 * **性能口径**:镜片是同一份 tab 内容的重绘副本,每帧两个绘制遍,但都是小尺寸
 * 矢量内容;所有逐帧变化的量(药丸 x、动画值、拖拽累计)只在 `offset{}` /
 * `graphicsLayer{}` 的 lambda 里读,**不进组合** —— 拖动帧只更新图层矩阵,
 * 不重建 Row(同鸿蒙端 H64 的最小重建面原则)。
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
/**
 * 镜片倍率。上限由**内容块高度**卡死:图标 22 + 间距 2 + 文案 ≈13 = 37dp,绕栏中心
 * 放大后是 37×倍率,超过胶囊高就被胶囊沿切掉半个字 —— 鸿蒙装机实测 1.45 配 44 高的
 * 胶囊时「发现」下沿被削掉 5vp,读起来像渲染坏了。37 × 1.35 ≈ 50 = 现在的胶囊高。
 *
 * 下面这组光学参数(倍率 / 胶囊高 / 底板 α / 拖影三件套 / 按压倍率)全部取自鸿蒙真机
 * 实测,理由与踩过的坑见 H96。Android 侧本轮**没有装机校色**,两端观感一致的前提是
 * 数值与结构同源 —— 装机若偏,以实机为准调这一组,别调结构。
 */
private const val LENS_MAG = 1.35f

/**
 * 拖拽时镜片副本的"拽动"三件套:满程 [SMEAR_FULL] 拖到顶,副本相对镜片反向退最多
 * [SMEAR_LAG],同时横向额外放大 [LENS_STRETCH]。
 *
 * 位移必须是**负方向**(副本退、镜片进)才读作被玻璃拽住的拖影;鸿蒙首版取正号,
 * 副本跑在镜片前面,观感是"字先走、圈后到",像掉帧而不是折射。
 */
private val SMEAR_FULL = 34.dp
private val SMEAR_LAG = 15.dp
private const val LENS_STRETCH = 0.55f

/**
 * 镜片底板的表面色不透明度。鸿蒙首版取 0.82,装机实测**残留重影明显**:放大副本绕中心
 * 外扩,原尺寸的图标/文案仍留在内侧,18% 透出来正好叠在副本的空档上,读作"两层字"。
 */
private const val LENS_PLATE_ALPHA = 0.93f

/**
 * 按下时整条栏 / 胶囊的放大倍率。首版取 1.07 / 1.12,鸿蒙装机截图里**完全看不出栏在
 * 长大**(56 高的 7% 只有 4vp),而需求要的正是"长按时整个底部 tab 都放大"。
 */
private const val BAR_PRESS = 1.10f
private const val PILL_PRESS = 1.15f

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
    val pillH = 50.dp
    val pillWd = 84.dp
    val pillW = with(density) { pillWd.toPx() }
    val smearFullPx = with(density) { SMEAR_FULL.toPx() }
    val smearLagPx = with(density) { SMEAR_LAG.toPx() }
    /** 胶囊在栏内的顶边 y(栏 56 / 胶囊 50,居中) */
    val pillTopPx = with(density) { (barH - pillH).toPx() / 2f }
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
    /** 指尖按在栏上期间为 true:整条栏与胶囊放大、染色加深 */
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

    /// 药丸当前左缘 x:拖拽期 1:1 跟手,平时读弹簧值。只在绘制/布局 lambda 里调用。
    fun pillPx(): Float = if (dragging) dragStartX + dragAccum else pillX.value

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
        targetValue = if (interacting) PILL_PRESS else 1f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 816f),
        label = "pillScale"
    )
    val barScale by animateFloatAsState(
        targetValue = if (interacting) BAR_PRESS else 1f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 816f),
        label = "barScale"
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
        // 拖拽路径接管了 interacting 的生命周期(见 onDragStart),这里负责熄灭:
        // 横拖接管手势后 tap 探测的 tryAwaitRelease 会以取消收场,但那条路径
        // 不清 interacting(见 onPress),否则拖拽全程放大效果被中途掐灭
        interacting = false
        // 槽位判定必须用胶囊**中心**:pillX 系列都是左缘坐标,直接拿去查槽,
        // 左缘到中心差半个胶囊宽 —— 发现→音阁要拖满行程的 69% 才判过半、
        // 音阁→发现 31% 就判过半,两个方向松手阈值不对称(H94:向右拖过半
        // 松手不切、向左拖过半却切)。中心过中线 = 恰好行程过半,两向对称。
        val target = tabAt(dragStartX + dragAccum + pillW / 2)
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
        BoxWithConstraints(
            Modifier
                .fillMaxWidth()
                .height(barH)
                // 按下整条栏放大:写在 clip 之前,投影/描边/内容一起进同一个图层跟着缩放;
                // 缩放只改图层矩阵,不触发布局(列表不会重排,底部留白仍是原高度)。
                .graphicsLayer {
                    scaleX = barScale
                    scaleY = barScale
                }
                // 投影给 z 轴高度:整条栏"浮"在页面之上,而非贴底的一块平面
                // 阴影外形用真胶囊,理由见 Components.kt GlassChipsRow(H92):
                // 半径小于半高的高程阴影在形状中央留接缝,透过半透明玻璃显形。
                .shadow(elevation = 8.dp, shape = RoundedCornerShape(percent = 50), clip = false)
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
                                // 拖拽期间途经 tab 也要有按压态(鸿蒙 onTouch Down/Up 的语义):
                                // interacting 由这里点亮、settle 里熄灭,tap 路径取消时不再代管
                                interacting = true
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
                                // 用胶囊中心查槽(理由见 settle),途经 tab 的高亮才与
                                // 松手提交的判定一致
                                nearIdx = tabAt(dragStartX + dragAccum + pillW / 2)
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
                            // 只在非拖拽态熄灭:横拖接管时 dragging=true,interacting
                            // 归拖拽路径(settle)管,这里清了会把拖拽全程的放大掐灭
                            if (!dragging) interacting = false
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
            // 副本要与基础内容**同尺寸同坐标**,绕胶囊中心缩放后才对得齐。栏宽只在
            // 量测/旋屏时变(不是拖动帧),所以在这里读容器约束换一次 dp 无妨。
            val barWdp = with(density) { constraints.maxWidth.toDp() }
            val barHdp = with(density) { constraints.maxHeight.toDp() }
            val lensOn = placed && constraints.maxWidth > 0
            val active = if (nearIdx >= 0) nearIdx else currentSelected
            // 镜片光轴 = 胶囊中心(栏坐标 = 副本自身局部坐标)。
            // Compose 1.6 的 TransformOrigin 只吃 0..1 的比例,故把像素中心换算成比例。
            fun pivotFx(): Float = (pillPx() + pillW / 2f) / maxOf(constraints.maxWidth, 1)
            fun pivotFy(): Float = 0.5f

            /** 拽动量 -1..1:拖了多少(满程 SMEAR_FULL)。只在绘制 lambda 里读。 */
            fun smearAmt(): Float =
                if (!dragging) 0f else (dragAccum / smearFullPx).coerceIn(-1f, 1f)

            // 1) 基础内容(不挖孔:与鸿蒙端同一套"盖而不是挖"的做法,见类注释)
            TabItemsRow(
                tabs = tabs,
                active = active,
                selected = currentSelected,
                onSelect = onSelect,
                interactive = true,
                modifier = Modifier.fillMaxSize()
            )

            // 2) 镜片:胶囊本体裁剪 + 玻璃底色,内容按较小倍率放大(放大镜本体)
            if (lensOn) {
                Box(
                    Modifier
                        .offset {
                            IntOffset(pillPx().roundToInt(), pillTopPx.roundToInt())
                        }
                        .size(width = pillWd, height = pillH)
                        .clip(CircleShape)
                        .graphicsLayer {
                            scaleX = pillScale
                            scaleY = pillScale
                        }
                        // 底板:盖住胶囊下那一份原尺寸内容(不盖会与副本叠成重影),
                        // 再加一层按压染色 —— 与鸿蒙 LensLayer 同一套"盖而不是挖"
                        .background(colorScheme.surface.copy(alpha = LENS_PLATE_ALPHA))
                        .background(colorScheme.primary.copy(alpha = pillAlpha))
                        .border(0.8.dp, colorScheme.primary.copy(alpha = 0.18f), CircleShape)
                ) {
                    TabItemsRow(
                        tabs = tabs,
                        active = active,
                        selected = currentSelected,
                        onSelect = onSelect,
                        interactive = false,
                        modifier = Modifier
                            .requiredSize(width = barWdp, height = barHdp)
                            .graphicsLayer {
                                // 副本与栏内容同尺寸同坐标:先按胶囊中心放大,再平移回
                                // 本层原点(层左上角 = 栏坐标 (left, top),故平移量取其负值)。
                                // 拖影:副本相对镜片往运动的**反方向**退,同时横向多拉一档
                                val s = smearAmt()
                                translationX = -pillPx() - s * smearLagPx
                                translationY = -(pillTopPx)
                                scaleX = LENS_MAG + kotlin.math.abs(s) * LENS_STRETCH
                                scaleY = LENS_MAG
                                transformOrigin = TransformOrigin(pivotFx(), pivotFy())
                            }
                    )
                }
            }
        }
    }
}

/**
 * tab 内容行:图标 + 文案,均分槽位。
 *
 * 同一个 composable 被调用两份(基础层 / 镜片),所以**只有基础层**挂 semantics:
 * 副本是装饰性的,挂一份就够,否则无障碍树里出现三个同名 tab。
 */
@Composable
private fun TabItemsRow(
    tabs: List<GlassTabSpec>,
    active: Int,
    selected: Int,
    onSelect: (Int) -> Unit,
    interactive: Boolean,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(modifier) {
        tabs.forEachIndexed { idx, tab ->
            // 图标与文字的间距收得很紧(space 2):间距一大,胶囊要罩住整块内容
            // 就得跟着变高,观感发"胖"(对齐鸿蒙同款注释)
            Column(
                modifier = if (interactive) {
                    Modifier
                        .weight(1f)
                        .fillMaxSize()
                        .semantics {
                            role = Role.Tab
                            // `selected` 在外层是函数参数(Int),这里必须显式 this.
                            // 指到 SemanticsPropertyReceiver 的扩展属性,否则变成给参数赋值
                            this.selected = selected == idx
                            onClick(label = tab.label) {
                                onSelect(idx)
                                true
                            }
                        }
                } else {
                    Modifier
                        .weight(1f)
                        .fillMaxSize()
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
