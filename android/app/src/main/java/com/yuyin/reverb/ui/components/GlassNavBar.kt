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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
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
 * 底部导航:悬浮玻璃长椭圆 + **镜片胶囊**(与鸿蒙 GlassTabBar 同一套设计)。
 *
 * 两层从下到上:
 * 1. **基础内容**:图标+文字,正常尺寸,任何时候都不变形。
 * 2. **镜片**:一块尺寸随按压长大的胶囊(裁剪窗口),先铺一块表面色玻璃板**盖住**底下的
 *    原尺寸内容,再画一份同尺寸的内容副本。副本静止时与底层**逐像素对齐**,所以按下时
 *    文字图标看不出任何变化;只有胶囊沿**压到**内容的那段时间,副本才被绕内容自身中心
 *    横向拉长 [SMEAR_STRETCH]、并逆着拖动方向后退 [SMEAR_LAG] —— 这就是「拖影」,
 *    离开内容即消失(强度算法见 [edgeOf])。
 *
 * 底板浓度必须是动态的([PLATE_GLASS] → [PLATE_OPAQUE]):静止时副本与底层重合,
 * 玻璃浓度就够;拖影期间两层错开,不盖实会读作重影。
 *
 * 曾经还有第 3 层「折射带」(比胶囊大一圈的裁剪 + 更强的放大副本)。鸿蒙装机实测它
 * **并不折射任何东西,而是整圈提亮成一块浅色光晕** —— 带 clipShape 的子节点会被单独
 * 合成,背景模糊在那一圈被重算了一遍。删掉后光晕消失(H96)。
 *
 * 再之前按「放大镜」做过静态 1.35 倍放大,装机被读作「底部变形」;需求口径是
 * **点击时文字图标不变,只有胶囊和容器放大**,静态放大整条作废(见 H97)。
 *
 * 为什么是"盖"而不是"挖":两端必须同一套做法,而鸿蒙那侧只有
 * `clipShape(shape)` / `maskShape(shape)` 的"只显示形内"语义(SDK 的 CommonMethod 里
 * 已无 MaskType.Exclude,挖不成孔),Android 单独用 `clipPath(Difference)` 挖孔会让
 * 两端观感分叉。代价是胶囊比真玻璃略实。
 *
 * 按下时**整条栏**一起放大到 [BAR_PRESS](不是只有被按的那个图标),胶囊再大一档到
 * [PILL_PRESS]。只要 PILL_PRESS > 栏高/胶囊高,胶囊就会**长出栏外** —— 这是用户明确要的
 * 效果,所以容器**不能有裁剪**(圆角只作为背景与描边的形状参数传给 .background/.border)。
 *
 * **性能口径**:镜片是同一份 tab 内容的重绘副本,每帧两个绘制遍,但都是小尺寸
 * 矢量内容;所有逐帧变化的量(药丸 x、拖拽累计、由它们算出的 smear)只在
 * `offset{}` / `graphicsLayer{}` / `drawBehind{}` 的 lambda 里读,**不进组合** ——
 * 拖动帧只更新图层矩阵,不重建 Row(同鸿蒙端 H64 的最小重建面原则)。
 * 只有 `pillGrowth`(胶囊尺寸)是逐帧进组合的:它只在按下/松手的 ~200ms 弹簧期间变,
 * 拖拽帧里恒为常量。
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
 * 拖影强度 0..1 由「胶囊沿压到内容的程度」算出(见 [edgeOf]),它同时驱动:
 * 副本横向拉长 [SMEAR_STRETCH]、逆着运动方向后退 [SMEAR_LAG]、底板变实
 * ([PLATE_GLASS] → [PLATE_OPAQUE])。静止时 smear=0,副本与底下的内容逐像素同尺寸
 * 同坐标 —— 按下时文字图标**不变**,这是用户指定的口径(曾按"放大镜"做过静态 1.35 倍,
 * 装机读作"底部变形",见 H96/H97)。
 *
 * 后退取**负方向**(副本退、镜片进)才读作被玻璃拽住;只平移不拉长会得到
 * "整块字挪了个位子",不像折射。
 *
 * [SMEAR_LAG] 只有 6dp:副本是**整层**平移,而它要被裁进胶囊里,退得越多镜内剩得越少
 * (鸿蒙取 15 时实测内容整块被推出镜外,镜子里只剩空玻璃)。
 */
private val SMEAR_LAG = 6.dp
private const val SMEAR_STRETCH = 0.55f

/**
 * 内容块的半宽:图标 22、文案两字 ≈26,取宽的那个的一半。只用来判"沿有没有压到内容"。
 */
private val CONTENT_HALF = 13.dp

/** 底板浓度:静止是玻璃,拖影期间随 smear 变实盖住底下的原文(错开两层字会读作渲染坏) */
private const val PLATE_GLASS = 0.62f
private const val PLATE_OPAQUE = 0.92f

/**
 * 按下时整条栏 / 胶囊的放大倍率。两条都是用户指定的口径:
 * ①整条栏一起放大(不是只有被按的图标);②胶囊要**比整条栏大一档,高到超出栏高** ——
 * 所以 PILL_PRESS 必须大于 BAR_H/PILL_H = 56/44 ≈ 1.27,低于这个比值胶囊就永远闷在栏里。
 * 首版取 1.07/1.12,装机截图里完全看不出栏在长大(56 的 7% 只有 4vp)。
 */
private const val BAR_PRESS = 1.10f
private const val PILL_PRESS = 1.42f

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
    val pillWd = 84.dp
    val pillW = with(density) { pillWd.toPx() }
    val pillHpx = with(density) { pillH.toPx() }
    val barHpx = with(density) { barH.toPx() }
    val smearLagPx = with(density) { SMEAR_LAG.toPx() }
    val contentHalfPx = with(density) { CONTENT_HALF.toPx() }
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
    /** 拖影后退的方向 = 胶囊这一帧的运动方向(倒拖时影也要倒回去) */
    var smearDir by remember { mutableFloatStateOf(1f) }

    fun halfW(): Float = barWpx / 2f
    fun pillXFor(idx: Int): Float = idx * halfW() + (halfW() - pillW) / 2f
    /** 第 idx 项内容块的中心(胶囊静止时就落在这儿) */
    fun slotCx(idx: Int): Float = idx * halfW() + halfW() / 2f

    /// 药丸当前左缘 x:拖拽期 1:1 跟手,平时读弹簧值。只在绘制/布局 lambda 里调用。
    fun pillPx(): Float = if (dragging) dragStartX + dragAccum else pillX.value

    /**
     * 胶囊沿"压到"第 idx 项内容的程度 0..1 —— 纯几何:内容与胶囊同轴(整块在镜内)
     * → 0;胶囊走远到内容完全出沿 → 0;内容中心正好骑在沿上 → 1。
     *
     * 于是"触碰有影、离开影消"不需要开关,也不需要读速度:松手回弹途中沿扫过内容
     * 会顺带来一下影,因为 pillX 本身在被弹簧逐帧驱动。
     */
    fun edgeOf(idx: Int): Float {
        val d = kotlin.math.abs(pillPx() + pillW / 2f - slotCx(idx))
        val u = ((d - (pillW / 2f - contentHalfPx)) / (contentHalfPx * 2f)).coerceIn(0f, 1f)
        return 1f - kotlin.math.abs(2f * u - 1f)
    }

    fun smear(): Float = maxOf(edgeOf(0), edgeOf(1))

    /**
     * 拖影该绕谁拉伸:**被压住那份内容自己的中心**,不是胶囊中心。
     * 绕胶囊中心缩放会给远离轴心的内容附加一个大位移 —— 鸿蒙装机实测把「发现」整块
     * 甩出镜外 49vp,镜子里只剩空玻璃(见 H97)。
     */
    fun smearPivotCx(): Float = slotCx(if (edgeOf(0) >= edgeOf(1)) 0 else 1)

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
            smearDir = if (pillXFor(selected) >= pillX.value) 1f else -1f
            pillX.animateTo(pillXFor(selected), settleSpec)
        }
    }

    /**
     * 胶囊的"长大"是**尺寸**而不是图层缩放:`graphicsLayer` 缩放会把里面的内容副本
     * 一起放大,而需求是"按下时文字图标不变,只有胶囊和容器放大"。
     *
     * 这一档是逐帧读进组合的(与 pillX/拖拽量不同) —— 只在按下/松手的 ~200ms 弹簧期间
     * 变,拖拽帧里它是常量,所以拖动帧仍然只更新图层矩阵。
     */
    val pillGrowth by animateFloatAsState(
        targetValue = if (interacting) PILL_PRESS else 1f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 816f),
        label = "pillGrowth"
    )
    val pillWdG = pillWd * pillGrowth
    val pillHG = pillH * pillGrowth
    val barScale by animateFloatAsState(
        targetValue = if (interacting) BAR_PRESS else 1f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 816f),
        label = "barScale"
    )
    /** 染色跟着倍率走:弹簧刚起步就"啪"地深一档,和正在长大的胶囊对不上 */
    val pillAlpha: Float =
        0.15f + ((pillGrowth - 1f) / (PILL_PRESS - 1f)).coerceIn(0f, 1f) * 0.13f

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
                val home = pillXFor(currentSelected)
                smearDir = if (home >= pillX.value) 1f else -1f
                pillX.animateTo(home, settleSpec)
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
                // 玻璃打底:半透明 surface + 发丝描边(透明度取舍见类注释)。
                // **这里不能用 .clip(RoundedCornerShape)**:胶囊长大要溢出到栏高之外
                // (PILL_PRESS > 56/44),容器一裁剪就被切平 —— 圆角只交给背景与描边的形状参数。
                .background(colorScheme.surface.copy(alpha = 0.85f), RoundedCornerShape(28.dp))
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
                                if (amount != 0f) smearDir = if (amount > 0f) 1f else -1f
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
            // 副本要与基础内容**同尺寸同坐标**才能逐像素重合(静止时看不出两层)。栏宽只在
            // 量测/旋屏时变(不是拖动帧),所以在这里读容器约束换一次 dp 无妨。
            val barWdp = with(density) { constraints.maxWidth.toDp() }
            val barHdp = barH
            val lensOn = placed && barWpx > 0f
            val active = if (nearIdx >= 0) nearIdx else currentSelected

            // 1) 基础内容(不挖孔:与鸿蒙端同一套"盖而不是挖"的做法,见类注释)
            TabItemsRow(
                tabs = tabs,
                active = active,
                selected = currentSelected,
                onSelect = onSelect,
                interactive = true,
                modifier = Modifier.fillMaxSize()
            )

            // 2) 镜片:长大的是**尺寸**不是图层 —— 用 graphicsLayer 缩放会把里面的内容副本
            //    一起放大,那就违反"按下时文字图标不变"。裁剪窗口挂在本层,形变挂在副本层,
            //    两者必须分层(同节点时裁剪窗口会跟着形变一起走,副本整块被推出镜外,H97)。
            if (lensOn) {
                Box(
                    Modifier
                        .offset {
                            val gw = pillW * pillGrowth
                            val gh = pillHpx * pillGrowth
                            IntOffset(
                                (pillPx() + pillW / 2f - gw / 2f).roundToInt(),
                                ((barHpx - gh) / 2f).roundToInt()
                            )
                        }
                        .size(width = pillWdG, height = pillHG)
                        .clip(CircleShape)
                        // 底板:盖住胶囊下那一份原尺寸内容(不盖会与副本叠成重影)。
                        // 浓度是 pillX 的函数,必须画在 draw 层 —— 放组合里读会让每个拖拽帧
                        // 整段重组合。上面再叠一层按压染色。
                        .drawBehind {
                            val s = smear()
                            val r = CornerRadius(size.minDimension / 2f)
                            drawRoundRect(
                                color = colorScheme.surface,
                                cornerRadius = r,
                                alpha = PLATE_GLASS + s * (PLATE_OPAQUE - PLATE_GLASS)
                            )
                            drawRoundRect(
                                color = colorScheme.primary,
                                cornerRadius = r,
                                alpha = pillAlpha
                            )
                        }
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
                                // 副本局部坐标数值 == 栏坐标,但本层左上角在栏坐标
                                // (left, top),故平移量取负才与基础内容对齐。
                                // 拖影:横向绕**被压住内容的中心**拉长,同时整层逆着拖动
                                // 方向后退一档 —— 只平移不拉长会读作"整块字挪了位子"。
                                val s = smear()
                                val gw = pillW * pillGrowth
                                val left = pillPx() + pillW / 2f - gw / 2f
                                val top = (barHpx - pillHpx * pillGrowth) / 2f
                                translationX = -left - smearDir * s * smearLagPx
                                translationY = -top
                                scaleX = 1f + s * SMEAR_STRETCH
                                scaleY = 1f
                                // TransformOrigin 只吃 0..1 的比例,故把像素中心换算成比例
                                transformOrigin = TransformOrigin(smearPivotCx() / barWpx, 0.5f)
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
