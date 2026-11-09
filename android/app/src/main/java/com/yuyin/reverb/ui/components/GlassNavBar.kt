package com.yuyin.reverb.ui.components

import android.os.SystemClock
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** tab 项规格:图标与文案。**数量由父级决定**(2026-10-08 起 3 项,鸿蒙 GlassTabBar 同步)。
 * 栏内所有几何都按 `tabs.size` 通式算,加/减一格不需要改这里。 */
data class GlassTabSpec(val label: String, val icon: ImageVector)

// ———————————————————————————————— 玻璃参数 ————————————————————————————————
// 与鸿蒙 `view/GlassTabBar.ets` **同值同义**。改任何一档要两端一起改,
// 并且先在一端真机验收再同构移植(两端漂掉的代价见 H96/H97/H98)。

/** 按下时整条栏的放大倍率。 */
private const val BAR_PRESS = 1.06f

/**
 * 按下时弹簧的**目标倍率**。透镜只在按住时存在,所以这个值只用来产生 0..1 的
 * "存在感"(见 `lensAlphaOf`),真实尺寸由 [LENS_SCALE] 决定 —— 两者相乘才是看得见的那一档。
 */
private const val LENS_PRESS = 1.16f

/**
 * 透镜这一档的玻璃浓度(surface 的 alpha)。
 *
 * 玻璃**不是白贴纸** —— 参考片里透镜内部是**看得见彩色内容**的,它靠的是
 * 「比周围更亮、更饱和」而不是「更白」。
 */
private const val LENS_TINT = 0.14f

/** 边缘高光的浓度。参考片那圈亮边占了"玻璃感"读感的一半,不能省。 */
private const val LENS_RIM = 0.8f

/**
 * 栏底 surface 的 alpha。鸿蒙同一处只有 0.34,因为它底下还压着一层实时背景模糊;
 * 这一端没有模糊可压,只能靠实底保住文字可读性(取舍见 [GlassNavBar] 的类注释)。
 */
private const val BASE_TINT = 0.85f

/** 栏底发丝描边的浓度。 */
private const val BASE_RIM = 0.45f

/**
 * **唯一的宽高比**。静止底和透镜共用这一个数 —— 这就是"等比例放大"的实现方式。
 *
 * ⚠️ 之前宽和高是两个独立常量(底 58×44 = 1.3,镜 95×53 = 1.8),于是从静止到拖动
 * 读起来是"一颗短椭圆被拉成长椭圆",被否:"静止状态也是个长椭圆,从静止到拖动是
 * 等比例放大,而不是由短变长"。现在 `lensH = lensW / ASPECT`,形变只发生在
 * **按下那一下**、且只改宽度,所以形状**恒为长椭圆**。
 */
private const val ASPECT = 1.9f

/**
 * **常驻的选中底**:静止时唯一可见的标记 —— 扁的浅灰长椭圆,不鼓出栏外、不变形。
 *
 * 高度由**内容高度**倒推:内容块 = 图标 19 + 间距 2 + 文字行高 ≈ 36dp,44 给出上下各 4 的
 * 呼吸量。宽度不单独定,由 [ASPECT] 算出(≈83.6)。
 */
private val REST_H = 44.dp
private val REST_W = REST_H * ASPECT

/** 静止底的颜色浓度(onSurfaceVariant 的 alpha)。再深就开始和玻璃抢戏。 */
private const val REST_TINT = 0.10f

/**
 * 透镜相对静止底的整体放大倍数(宽和高**同一个数**,所以形状不变)。
 * 按住期间恒为 ≈102×53.7,比 48 的栏上下各出约 3dp —— 这正是需求说的
 * "拖动时透镜放大,高度可以超出 tab"。
 *
 * ⚠️ 它是**按住期间的恒定倍率**,不是"拖得越远越大"。上一版宽度还乘了一段拖影强度,
 * 于是滑动中持续变大,被否:"很丑很不协调"。
 */
private const val LENS_SCALE = 1.22f

/**
 * 栏高。**2026-10-15 从 48 抬到 52** —— 播放条要跟成鸿蒙那一形态,而收束态的判据是
 * **整块与栏等高**(`Components.MINI_H_COLLAPSED = GLASS_BAR_H`):栏不抬,收进来的胶囊就
 * 装不下那一档的封面 40 + 上下各 6。
 *
 * ⚠️ **为什么是 52 而不是照抄鸿蒙的 56**,两条都写在案:
 * ① 本端有一条**同方向的否例**(见 [GlassNavBar] 类注释走过的弯路那串第 6 条):为了容纳放大后的
 *   透镜把栏从 44 抬到 56,被否「**高度增加太多了,只需要增加一点点**」,最后停在 48。
 *   这次的要求是「底部 tab 的高度增大」,没给数,所以按那条否例只抬 **4**;
 * ② 抬到 56 会顺手毁掉明确要求保留的那件事 —— 按住时透镜高 ≈53.7dp,现在上下各鼓出
 *   2.85dp(这就是"玻璃浮在栏外面"的读感来源);栏一旦到 56,53.7 < 56,**镜被装进板子里**,
 *   鼓出量归零。52 这一档还剩上下各 0.85dp,已经很薄。
 * 所以这两条**都要装机读**:觉得栏还是矮 → 抬到 56,但同时要把 [REST_H] 抬一档把鼓出量找回来
 * (那是另一次改判);觉得玻璃不鼓了 → 先动 [REST_H](44→47 就把 52 这一档的鼓出量还原),
 * 栏高不动。**两个数各调各的,一次一个。**
 * ⚠️ 本轮 [REST_H] / [ASPECT] / [ITEM_INSET] / [LENS_SCALE] **一个没动** —— 它们是 Pixel 3
 * 逐帧量过、被否八遍定下来的,和栏高一起改就读不出哪一处起的作用。
 *
 * 页面让出的底部余量必须跟着栏的落点走 —— MainShell 直接量叠层的实测高度(本值 + 那道缝 +
 * 播放条展开态那一档 + 手势区),这等价于鸿蒙那边 `barFootprint()` 的"同一个式子算两处",
 * 不要再在别处写第二个栏高。
 */
val GLASS_BAR_H = 52.dp

/**
 * 整条栏距屏幕左右:胶囊放大后不能顶出屏幕(12 那一档被反馈"栏太长、顶到边")。
 * **播放条胶囊读同一个数**(见 `Components.MINI_SIDE_PAD`)—— 宽度只有一个来源,
 * 栏改了播放条跟着改,不会各漂各的;鸿蒙那边是同一对常量
 * (`BAR_SIDE_MARGIN` / `MINI_SIDE_MARGIN`)承担同一条约束。
 */
val GLASS_SIDE_PAD = 24.dp

/**
 * tab 内容的中心从栏边缘内收这么多 —— 按钮间距就是这么收小的。
 * ⚠️ 这层 padding **只影响内容行与 [slotCx]**,不影响 [tabAt] 的命中带(那条按整栏宽度均分)。
 * 两项时两者唯一分界都在 barW/2,对称到看不出差别;三项起分界与内容中心差 2·内收量/3
 * (本机量:363dp 栏宽 ⇒ 约 15dp),而每格内容离最近分界还有 40dp 以上,所以点不偏 ——
 * 但**别把它当"命中带与内容带对齐"**,槽数再往上加要重算这个余量。
 */
private val ITEM_INSET = 22.dp

/**
 * 玻璃"受光量"系数:浅色 1,深色 0.42。
 *
 * 高光边和上缘那条白渐变是按浅色底校的。深色模式下同一档白边压在墨底上不是玻璃而是
 * **一圈硬白线** —— 深色玻璃本身不透光,边缘能接住的光少得多。所以把"受光"整体收一档,
 * 而不是给深色另起一组常量(两组值一定会漂)。
 */
private const val GLASS_K_DARK = 0.42f

/**
 * 两组弹簧的阻尼。⚠️ 单位换算沿用本仓库口径:鸿蒙 `curves.springMotion(response,
 * dampingFraction)` 里 response 是**一次完整振荡的秒数**,换到 Compose 是
 * `stiffness = (2π/response)²`(见 [SPRING_STIFFNESS])。
 *
 * damping < 1 才会过冲 —— 落位那一下甩过头再回来才是"粘滞",临界阻尼是急刹。
 * 生长与位移同档(response 都是 0.42)才对得上"同一个物体"。
 */
private const val DAMP_GROWTH = 0.68f
private const val DAMP_PILL = 0.70f

/** response 0.42s ⇒ (2π/0.42)² ≈ 224。 */
private const val SPRING_STIFFNESS = 224f

/**
 * 双击 tab 的时间窗(毫秒)。取 380ms:比系统的双击判定(约 300–500ms)
 * 中间偏紧一点 —— 太宽会把"点一下没反应、再补一下"读成双击,太窄又要求手速。
 */
private const val DOUBLE_TAP_MS = 380L

// ———————————————————————————— 折射(鸿蒙第 0.5 层):尚未落地 ————————————————————————————
/**
 * 鸿蒙那一层把栏背后的内容按径向位移场搬进透镜里。Android **还没做**,卡在**取源**
 * 而不是卡能力:
 *
 * - 鸿蒙截的是栏的**兄弟节点**(页面内容那一块),快照里压根没有栏自己;
 * - Android 能截的只有整个 window(`PixelCopy`),而按下去那一刻栏已经画上去了 ——
 *   拿到的"背景"里带着栏底板、静止底和图标,搬进透镜就是重影图标,
 *   正是被真机否掉三遍的那件事。
 *
 * 干净的做法是给**页面那一层**挂位移场(`android.graphics.RuntimeShader` + AGSL,API 33+),
 * 让折射发生在"被盖住的那一侧"而不是玻璃这一侧;顺带还能补上 Android 缺的区域级背景模糊,
 * 让 [BASE_TINT] 从 0.85 的实底降到鸿蒙那一档。这条路的两个代价都要真机量:
 * 整页图层离屏合成的性能(见 H64 那类教训),以及 API 33 以下怎么回落。
 *
 * ⚠️ 原先记在这里的「要先升 Compose 到 1.7 才拿得到图层捕获」是**错的**,已撤:
 * 本项目锁的 Compose 1.6.8 里 `GraphicsLayerScope.renderEffect` 就存在,而
 * `androidx.compose.ui.graphics.RenderEffect` 正是包平台 `android.graphics.RenderEffect`
 * 的抽象类(`asAndroidRenderEffect()` 反向可取),AGSL 效果直接喂进去就行。
 * 为一个不存在的门槛去升 Kotlin 2.0 + 换 Compose 编译器插件,不值。
 */

/**
 * 底部导航:悬浮玻璃长椭圆 —— **软体透镜模型**,与鸿蒙 `view/GlassTabBar.ets` 同一套设计。
 *
 * **三层结构**(z 序自下而上;鸿蒙在 0 和 1 之间还有一层折射,见上面「折射:尚未落地」):
 * 0. 静止底([REST_W]/[REST_H]):**唯一常驻**的选中标记 —— 扁的浅灰长椭圆。静止时不变形、
 *    不鼓出栏外;按住时它**跟着透镜一起等比长大**(共用 [lensScaleOf]),否则半透明的玻璃
 *    会把"小一号的灰底"透出来,读成镜内另画了一颗椭圆(见 H107)。
 * 1. 透镜:一颗玻璃,**透明度直接读 lensAlphaOf** ⇒ 静止时是 0(等于不存在),
 *    按下才从灰底"长"出来,松手缩没。带自己的厚度渐变、染色与高光边。
 * 2. 内容([TabItemsRow]):图标 + 文字,**画在玻璃之上,永远静止,只画一份**。
 *
 * **手感口径(对着参考录屏逐帧量出来的,别再改回去)**:
 * ① 内容(文字/图标)**零形变、零位移**。参考片实测:被玻璃压住的绿块右缘逐帧恒定
 *    在 258/259(同屏不动的加号按钮 326..399 作对照),只有靠左那 19px 被冲淡 ——
 *    所以"图标边缘被扯动"是玻璃洗白造成的错觉,不是图标在动;
 * ② 按下时整条栏放大([BAR_PRESS]),透镜再大一档([LENS_SCALE],高到鼓出栏外),
 *    但整条栏不能长到顶出屏幕;
 * ③ 形变只属于透镜,且**只由按下那一下决定**(`lensScaleOf`):前缘 1:1 跟手 = 位置跟手,
 *    宽度**不**随拖动幅度变化;粘滞感由落位时的位移过冲表达。
 *    高度永远 = 宽 / [ASPECT],所以按下放大是等比例放大;
 * ④ 动画要 iOS 那种带轻微过冲的弹簧,不要急刹(见 [DAMP_GROWTH] / [DAMP_PILL]);
 * ⑤ **玻璃只在触碰期间存在**。常驻一颗大玻璃 = 静止画面被一颗药丸占掉,
 *    与参考片"平时安静、按住才鼓出来"完全相反;
 * ⑥ 静止底与透镜**同一个宽高比**([ASPECT]),而且按下时读**同一条放大曲线** ——
 *    两者尺寸恒等、任何时候都同心同形,不会错开成两颗(见 H107)。
 *
 * 走过的八条弯路,不要再回去(完整过程见鸿蒙侧与 H96/H97/H98):
 * - 静态"放大镜"(镜内一份 1.35 倍放大副本)→ 被读作"底部变形";
 * - 副本横向 scaleX 拉长 + 后退位移表达"拖影"→ 被否:"不是左右拉伸放大,是粘滞";
 * - 整块内容跟着胶囊方向 translate → 被否:"图标不应该动,现在图标在晃动";
 * - 一端钉住、另一端把内容边缘扯出去 → 被否:图标压根不该有任何形变;
 * - 透镜常驻挂在选中项上 → 被否:"透镜不是常驻的啊";
 * - 为了"透镜太大"把透镜收成正圆档、又把栏从 44 抬到 56 → 被否:"圆滚滚的,跟视频里差很多"
 *   "高度增加太多了,只需要增加一点点"。教训:**长椭圆的比例不是靠压宽度保住的,
 *   是靠别把高度加上去**;栏只抬到 48 给内容留 padding,鼓出栏外那部分交给透镜自己;
 * - 宽、高各写各的常量 → 被否:"静止状态也该是长椭圆,从静止到拖动是等比例放大"。
 *   **形状是一种不变量,就该只有一个常量**;
 * - 用「前缘 + 后缘两条弹簧之差」表达拖动粘滞,结果透镜**越拖越大** →
 *   被否:"点击透镜变大是对的,滑动的时候就不能再变了;现在滑动时还在继续变大,
 *   很丑很不协调"。教训:**一个观感只由一个状态量驱动** —— 尺寸归按下,位置归手指;
 *   要表达粘滞就动位置(落位过冲),不要动尺寸。
 *   本文件上一版正是这一条:`edgeOf / smear / smearPivotCx` 三个函数加一份内容副本,
 *   本轮整块删除。副本层之所以存在,只是为了给"拖影"当被拉的对象 —— 口径改成
 *   "内容零形变"之后,它连存在的理由都没了;同理"底板浓度随拖拽变实"那一档也一起作废
 *   (它防的是错开的两层字读成重影,现在压根只有一层)。
 *
 * **为什么透镜不用图层缩放而是直接改尺寸**:`graphicsLayer` 缩放会把高光边和厚度渐变
 * 一起放大,读起来是"一张图放大"而不是"一颗玻璃长大";鸿蒙那一版同样直接改 width/height。
 *
 * **Android 真机取证(2026-09-27,`android/tools/glass-shot.sh` 出静止/按住/拖动三帧;
 * 机子 Android 16 / 1272×2800 / 密度 476 → 2.975 px/dp)**:上面 ①③⑤ 三条口径是量出来的,
 * 不是看出来的 ——
 * - 按住帧与拖动帧的透镜**同为 321 px 宽**(同一裁剪窗内底边被截到同一处),只有中心
 *   x 从 371 走到 597 ⇒ 尺寸不含拖动量 ✓;含整栏 1.06 缩放后 322×169 px,宽高比 1.90 ≡ [ASPECT],
 *   上沿高出栏顶 13 px 且**没被裁** ⇒ 鼓出栏外是活的 ✓;
 *   **顺带这条 13 px 也说明纵向是居中的**((169−143)/2 = 13,上下等量) —— 所以下一轮装机
 *   报「透镜置底」时,几何推导判不出偏心,嫌疑落在"下缘那截鼓出被栏自己的方向光投影糊掉、
 *   于是看不见"。后来在 Pixel 3 上用**上下鼓出量差分框**量实了:上 4 px / 下 3 px、
 *   与栏中线偏离 −1 px(±2 px 地板内)⇒ **几何排除,病在对比度**,spot 归零那行就是修复;
 *   两条候选与判读路径见 H109。
 * - 静止帧整栏找不到 >38 px 的中性高亮连通块(那块是未选中图标的白描边)⇒ 没有常驻玻璃 ✓;
 * - 发现图标:静止 61×96 px 中心 (386,2671),按住与拖动两帧**都是** 65×102 px 中心 (371,2670),
 *   差值恰好等于整栏 1.06 缩放(636+(386−636)×1.06=371)⇒ 内容零形变、也不跟药丸走 ✓。
 * 同一批帧也量出「镜内是暗面」确实存在(折射未做的代价),以及栏底留白**不该**照抄鸿蒙的
 * `INSET_KEEP 0.62` —— 那条的数与结论记在 `docs/ROADMAP.md` §A 与 H104。
 *
 * **为什么这里没有鸿蒙的 `backgroundEffect`**:Android 没有区域级实时背景模糊
 * (窗口级 `setBackgroundBlurRadius` 只糊壁纸;三方 blur 库被仓库「不接三方 SDK」约束挡住),
 * 玻璃感靠半透明 surface 打底 + 发丝描边 + 投影近似。透明度取 [BASE_TINT] 而非鸿蒙的 0.34:
 * 没有模糊时太透会让文字压在滚动内容上读不清。这一档差异就是折射那条待做的账。
 *
 * **容器为什么不能裁剪**:透镜按住时 ≈53.7dp 高,超出 [GLASS_BAR_H](48 时鼓出上下各 2.85dp,
 * 2026-10-15 抬到 52 后只剩 0.85dp —— 这一档还剩多少要装机读,见 [GLASS_BAR_H] 那条)—— 一 clip
 * 就被栏的圆角齐着切平,玻璃就"贴"在栏里而不是"浮"在外面(需求明确要"超出 tab")。
 * 所以圆角只作为背景与描边的形状参数传进去。
 *
 * 内容能透到栏下的前提:MainShell 已改为叠层布局,各页列表用 [LocalGlassBottomPad]
 * 让出底部余量。
 *
 * 手势全走 Box 层一个 tap 探测 + 一个横拖探测,子项**不放 clickable**:
 * detectTapGestures 会消费 down,若子项也有 clickable,兄弟叠层/祖先层先到者
 * 会把子项的 awaitFirstDown(requireUnconsumed=true) 饿死。无障碍改由 semantics
 * 的 role/selected/onClick 提供,不占指针事件。
 *
 * **性能口径**:逐帧变化的量(药丸 x、透镜透明度、整条栏缩放)只在 `offset{}` /
 * `graphicsLayer{}` 的 lambda 里读,**不进组合**;只有透镜的**尺寸**读进组合,
 * 而它只在按下/松手的 ~200ms 弹簧期间变,拖拽帧里恒为常量
 * (同鸿蒙端 H64 的最小重建面原则)。
 */
@Composable
fun GlassNavBar(
    tabs: List<GlassTabSpec>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    /**
     * 播放条是否已经收进这一行。为 true 时**整条栏淡到 0**(底板材质 + 静止底 + 透镜 + 三格内容
     * 一起没),那一行交给播放条自己 —— 对应鸿蒙 `barFloating` 里那条 `barOpacity: collapsed ? 0 : 1`。
     *
     * 为什么必须淡掉:收束态胶囊的高就是栏高,两条胶囊叠在同一条带上读起来就是
     * "播放条装在 tab 容器里面"(两层底),而参考片那一态只有一层容器。
     * ⚠️ 随之而来的一条**是设计不是 bug**:这一态那一行只有播放条与那颗球,**三个 tab 点不动**;
     * 想切格先点那颗球展开。所以这里连按下预选与横拖提交一起关掉(见 [currentCollapsed] 两处判断),
     * 只留指针事件被消费掉 —— 放进下层会让那一行的空白处漏到页面上去。
     *
     * ⚠️ 淡入淡出走**弹簧**而不是鸿蒙那条瞬变:鸿蒙的 `barOpacity` 藏在样式对象里、不是节点的
     * 属性动画对象,所以翻转那一瞬栏底立刻没了,那台的注释里备着"改成逐帧驱动"的解法;
     * Android 这边天然能做,就用与播放条形变同一条曲线(同 [MINI_MORPH_DAMP]),
     * 否则栏自己缩、播放条滑过来,两条曲线不同步会看出散架。
     */
    collapsed: Boolean = false,
    /**
     * **双击当前 tab**。普通点按在 [selected] 那一格上本来无事可做(页面已经在那一格),
     * 所以那一下只用来攒双击:两次点在同一格、间隔 ≤ [DOUBLE_TAP_MS] 才回调。
     *
     * 为什么不在 MainShell 的 `select()` 里判:栏里**只有切格**才调 `onSelect`
     * (`commitIdx != currentSelected` 那一条),点当前格根本不上报 —— 双击的第一下
     * 到不了外壳。判定必须贴着 tap 探测器,那里才知道这一次点的是哪一格。
     */
    onDoubleTap: (Int) -> Unit = {}
) {
    val colorScheme = MaterialTheme.colorScheme
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    // press/drag 回调存活于整个 pointerInput 生命周期,必须读最新值:
    // 捕获旧 selected 会把提交送到上一个 tab 上
    val currentSelected by rememberUpdatedState(selected)
    val currentOnSelect by rememberUpdatedState(onSelect)
    val currentOnDoubleTap by rememberUpdatedState(onDoubleTap)
    /**
     * 双击判据:[0] 上一次点中当前 tab 的时刻,[1] 那一格。
     * 用 `LongArray` 而不是 state —— 它只在手势回调里读写,不该触发重组(同 [previewTarget])。
     */
    val lastTabTap = remember { LongArray(2) { -1L } }
    // 同一条理由:收束态的判据活在整个手势回调里,不能读按下那一刻的旧值
    val currentCollapsed by rememberUpdatedState(collapsed)

    // 整条栏的不透明度。⚠️ 留成 State 不解包成 `by`:委托读值会把当前组合作用域订阅上,
    // 于是弹簧途中整条栏(含内容层)跟着重建 —— 和 [growth] 同一条口径,失效范围要落到最小。
    val barFade = animateFloatAsState(
        targetValue = if (collapsed) 0f else 1f,
        animationSpec = spring(dampingRatio = MINI_MORPH_DAMP, stiffness = MINI_MORPH_STIFFNESS),
        label = "barFade"
    )

    val restWpx = with(density) { REST_W.toPx() }
    val itemInsetPx = with(density) { ITEM_INSET.toPx() }
    val settleSpec = spring<Float>(dampingRatio = DAMP_PILL, stiffness = SPRING_STIFFNESS)

    var barWpx by remember { mutableFloatStateOf(0f) }
    /**
     * 非拖拽期的药丸位置(弹簧驱动);拖拽帧改读 dragX,松手先 snapTo 再回弹。
     *
     * ⚠️ 单位是**静止底(宽 [REST_W])的左上角 x**,不是透镜的:灰底和透镜共用同一个
     * 位置源,按下时透镜从灰底**原地**长大,不会先跳一下(锚点选择见 [pillXFor])。
     */
    val pillX = remember { Animatable(0f) }
    /**
     * 只当两个用途:① 拖拽期间挡住 [LaunchedEffect] 的吸附;② 决定 `interacting` 归谁熄灭。
     *
     * ⚠️ **不再是绘制路径的输入**。上一版 `pillPx()` 写成 `if (dragging) dragStartX + dragAccum
     * else pillX.value`,于是拖拽期间 `pillX` 一直停在按下时的旧槽位;而 [settle] 第一件事就是
     * `dragging = false`,把绘制源瞬间切回那个旧值 —— 松手那一帧药丸**先跳回出发的那个 tab**,
     * 下一帧才被 `snapTo(拖拽终点)` + 弹簧拉回去。用户看到的"松手又自动滑回去"就是这一帧
     * (H105)。鸿蒙那一版没有这个坑,因为它每帧 `pillTo(x)` 直接把位置写进同一个状态量。
     */
    var dragging by remember { mutableStateOf(false) }
    /**
     * 拖拽期间**手指命令**的静止底左缘 x,只当作下一帧增量的基准用。
     *
     * ⚠️ 绘制路径**不许读它** —— 一读就又变成"两个位置源",松手切回弹簧值就会回跳(H105,
     * 上一版的 `dragAccum` 正是栽在这条上)。它之所以还要存在:`onHorizontalDrag` 在
     * Compose 1.6.8 里不是 suspend,写进弹簧要经 `scope.launch`,万一晚一帧,以弹簧值为基准
     * 会吞掉那一帧的位移(拖动手感变半速)。用 `FloatArray` 而不是 state:它不该触发重组。
     */
    val dragCmdX = remember { FloatArray(1) }
    /** 按下预选的 tab;-1 = 无 */
    var previewIdx by remember { mutableIntStateOf(-1) }
    /** 拖拽/按下期间按接近度高亮的项;-1 = 跟 selected 走 */
    var nearIdx by remember { mutableIntStateOf(-1) }
    /** 指尖按在栏上期间为 true:整条栏与透镜放大,松手回落。只由触摸点亮(硬规矩 9)。 */
    var interacting by remember { mutableStateOf(false) }
    var placed by remember { mutableStateOf(false) }
    var previewJob by remember { mutableStateOf<Job?>(null) }
    /**
     * 预览弹簧**当前正飞向**哪一项;`previewIdx` 不行,它在 onPress 收尾时被同步清成 -1,
     * 而 `selected` 要等下一次重组才变 —— 那时 [LaunchedEffect] 已经读不到它了。
     *
     * 用 `IntArray` 而不是 state:只有 sync 那一处读,写它不该触发重组。
     */
    val previewTarget = remember { IntArray(1) { -1 } }

    /**
     * 一格槽宽。两项时它与旧的 `halfW()`(barW/2)逐值相同,所以两格时代的观感不动;
     * 但槽数必须由 `tabs.size` 来 —— 写死 2 的话第三格压根点不到(命中判定只会返回 0/1)。
     */
    fun slotW(): Float = barWpx / tabs.size.coerceAtLeast(1)

    /**
     * 第 idx 项内容块的中心。两项不再"半栏均分",而是对称地放进
     * [itemInsetPx, barW - itemInsetPx] 这条带里。
     *
     * ⚠️ 必须与 [TabItemsRow] 上那层 padding 读同一个常量:两列是 weight 均分的,
     * 少挂那层 padding,内容中心就永远落在 barW/4 与 3·barW/4,而药丸按 slotCx 走 ——
     * 鸿蒙装机实测两者差半个内收量,药丸压在字的一半上。
     */
    fun slotCx(idx: Int): Float {
        val band = barWpx - itemInsetPx * 2f
        return itemInsetPx + band * (idx + 0.5f) / tabs.size
    }

    /** 药丸停在第 idx 项时**静止底左缘**的 x(锚在 [REST_W] 而不是透镜宽,理由见 [pillX])。 */
    fun pillXFor(idx: Int): Float = slotCx(idx) - restWpx / 2f

    /**
     * 药丸当前静止底左缘 x。**唯一来源是 [pillX]**:拖拽帧由 `snapTo` 逐帧写进来,其余时候由
     * 弹簧写进来 —— 两条路径写同一个量,所以任何时刻切换都不会出现"回跳"(见 [dragging])。
     * 只在绘制/布局 lambda 里调用。
     */
    fun pillPx(): Float = pillX.value

    /** 静止底中心 = 槽位判定用的那个点(见 [settle] 里的 H94 说明) */
    fun pillCx(): Float = pillPx() + restWpx / 2f

    fun tabAt(x: Float): Int {
        if (slotW() <= 0f) return 0
        // 均分槽位直接 floor:x 落在哪个槽就是哪个 tab。原先的 (x + halfW/2)/halfW
        // 算的是「离 halfW 的整数倍最近」,而槽中心在半个槽宽处 —— 结果是发现
        // tab 自己的右半边全部被判成音阁:点已选中的发现,药丸预览跳去音阁、松手
        // 连页面也切过去(H90 用户反馈)。
        return (x / slotW()).toInt().coerceIn(0, (tabs.size - 1).coerceAtLeast(0))
    }

    // 选中项变化(含首次量宽)→ 药丸弹簧吸过去。拖拽期间不插手,松手路径自己收。
    LaunchedEffect(barWpx, selected) {
        if (barWpx <= 0f) return@LaunchedEffect
        if (!placed) {
            pillX.snapTo(pillXFor(selected))
            placed = true
        } else if (!dragging) {
            // **预览弹簧还在飞向这一项就别重启它。** `animateTo` 经 MutatorMutex 掐掉上一段,
            // 新那段以初速 0 重新起步:真机实测药丸已爬到 19px/帧时被打断,重启后单帧跳
            // +57px、过冲到 713(静止位 690)再花 300ms 爬回来 —— 用户报的"点击切换发涩"
            // 主要是这一条,不是掉帧。见 H105。
            val flying = previewJob
            if (previewTarget[0] != selected || flying?.isActive != true) {
                previewTarget[0] = -1
                pillX.animateTo(pillXFor(selected), settleSpec)
            }
            // 否则让按下预览那一段自己跑完,这里不接手
        }
    }

    /**
     * 按下那一下的"存在感"弹簧:1 = 静止,[LENS_PRESS] = 按到底。
     *
     * ⚠️ 这是**唯一**的按下状态量:透镜尺寸、玻璃透明度、整条栏缩放三处都从它派生。
     * 上一版这里并列了一条独立的 `barScale` 动画(独立目标值 + 独立弹簧),两条曲线各自
     * 过冲,栏和玻璃对不齐;鸿蒙改成派生之后观感才对上。
     *
     * ⚠️ 这里**故意不解包成 `by`**:委托读值会把当前组合作用域订阅上,于是每一帧整条栏
     * (含内容层)跟着重建。留成 `State<Float>` 往下传 —— 栏的缩放和玻璃的尺寸各自在
     * 图层 lambda / 子组件里读,失效范围才落到最小(同鸿蒙端 H64 的最小重建面原则)。
     *
     * 鸿蒙那一版还要在 JS 里逐帧积分(`GlassSpring`)而不用 `animateTo`,是因为折射画布
     * 每帧要读**当前值**;Android 这边折射还没做,`animateFloatAsState` 的中间值在组合里
     * 读得到,不需要自己积分。
     */
    val growth = animateFloatAsState(
        targetValue = if (interacting) LENS_PRESS else 1f,
        animationSpec = spring(dampingRatio = DAMP_GROWTH, stiffness = SPRING_STIFFNESS),
        label = "pillGrowth"
    )

    val isDark = isSystemInDarkTheme()

    /**
     * 松手 / 被系统取消:按药丸当前位置吸附最近项。commit=false(取消)只回弹。
     *
     * 这里**不再写位置**:药丸此刻已经停在手指放开的那个点上(拖拽帧每帧 `snapTo` 写进
     * [pillX] 的)。上一版在这里补一句 `snapTo(dragStartX + dragAccum)`,正是为了纠正
     * `dragging=false` 那一瞬间的回跳 —— 补在原地方,回跳的那一帧照样已经画出去了(H105)。
     */
    fun settle(commit: Boolean) {
        if (!dragging) return
        dragging = false
        nearIdx = -1
        previewIdx = -1
        // 拖拽路径接管了 interacting 的生命周期(见 onDragStart),这里负责熄灭:
        // 横拖接管手势后 tap 探测的 tryAwaitRelease 会以取消收场,但那条路径
        // 不清 interacting(见 onPress),否则拖拽全程放大效果被中途掐灭
        interacting = false
        // 槽位判定必须用药丸**中心**:pillPx 是静止底左缘坐标,直接拿去查槽,
        // 左缘到中心差半个底宽 —— 发现→音阁要拖满行程的 69% 才判过半、
        // 音阁→发现 31% 就判过半,两个方向松手阈值不对称(H94:向右拖过半
        // 松手不切、向左拖过半却切)。中心过中线 = 恰好行程过半,两向对称。
        val target = tabAt(pillCx())
        if (commit && target != currentSelected) {
            // 药丸不在这里动:selected 一变,LaunchedEffect 会从当前绘制位弹簧过去
            currentOnSelect(target)
        } else {
            scope.launch { pillX.animateTo(pillXFor(currentSelected), settleSpec) }
        }
    }

    Box(
        modifier
            .fillMaxWidth()
            .padding(horizontal = GLASS_SIDE_PAD)
            // 收束态淡掉**整条栏**:挂在最外层的图层上,于是底板、投影、静止底、透镜、内容
            // 一起没 —— 少挂一处就会看到"板子没了但影子还在"(和透镜那一层同一个理由)。
            .graphicsLayer { alpha = barFade.value }
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(GLASS_BAR_H)
                // 按下整条栏放大(需求:长按时**整个底部 tab**都放大,不是只有被按的图标)。
                // 缩放值从按下弹簧派生,写在 lambda 里 ⇒ 逐帧只更新图层矩阵,不触发布局
                // (列表不会重排,底部留白仍是原高度)。
                .graphicsLayer {
                    val a = lensAlphaOf(growth.value)
                    scaleX = 1f + (BAR_PRESS - 1f) * a
                    scaleY = scaleX
                }
                // 投影给 z 轴高度:整条栏"浮"在页面之上,而非贴底的一块平面。
                // 阴影外形用真胶囊,理由见 Components.kt GlassChipsRow(H92):
                // 半径小于半高的高程阴影在形状中央留接缝,透过半透明玻璃显形。
                //
                // **spot(方向光)那一档归零,和透镜同一口径**(透镜那圈为什么归零见 H107):
                // spot 按「光源在上方」整层**往下偏**,于是在栏的底边下面压出一条比栏本身更暗的
                // 带 —— 而透镜往下鼓出只有 ≈3dp(8~9 px),正好整条落进这条暗带里,下缘的对比
                // 被吃掉;往上鼓出那 3dp 贴在干净的页面背景上,清清楚楚。于是"上下对称地鼓出"
                // 在真机上读成"只往下淌",这就是装机反馈「透镜相对栏置底」的候选成因。
                // ambient 那一档保留:它与形状同心,给的是"浮着"的柔光边,不带方向。
                // ⚠️ 这一条**尚未在真机上对照验证**(本轮设备不在):如果装机看到下缘仍然糊,
                // 说明成因不在投影而在别处,先把这行退回(它只影响栏的投影,不动几何)。
                .shadow(
                    elevation = 8.dp,
                    shape = RoundedCornerShape(percent = 50),
                    clip = false,
                    spotColor = Color.Transparent
                )
                // 玻璃打底:半透明 surface + 发丝描边(透明度取舍见类注释)。
                .background(
                    color = colorScheme.surface.copy(alpha = BASE_TINT),
                    shape = RoundedCornerShape(percent = 50)
                )
                .border(
                    width = 0.8.dp,
                    color = colorScheme.outline.copy(alpha = BASE_RIM),
                    shape = RoundedCornerShape(percent = 50)
                )
                .onSizeChanged { barWpx = it.width.toFloat() }
                // 横拖:药丸 1:1 跟手,松手按位置吸附(装机社区手感)
                .pointerInput(tabs.size) {
                    detectHorizontalDragGestures(
                        onDragStart = { _ ->
                            // `&& !currentCollapsed`:收束态这一行归播放条与那颗球,横拖不接管。
                            // 不进这个分支 = dragging 恒 false = 松手时 settle 直接 return,
                            // 于是「淡掉的栏不会被拖到别的格」,而指针事件照常被这层消费掉。
                            if (slotW() > 0f && !currentCollapsed) {
                                // 预览动画若还在跑,先掐掉:下面的 snapTo 与它抢同一个 Animatable
                                previewJob?.cancel()
                                previewJob = null
                                dragging = true
                                // 拖拽期间途经 tab 也要有按压态(鸿蒙 onTouch Down/Up 的语义):
                                // interacting 由这里点亮、settle 里熄灭,tap 路径取消时不再代管
                                interacting = true
                                // 从药丸**当前**位置起步(按下预选可能已把它挪走一截)
                                dragCmdX[0] = pillX.value
                            }
                        },
                        onDragEnd = { settle(commit = true) },
                        onDragCancel = { settle(commit = false) },
                        onHorizontalDrag = { change, amount ->
                            if (dragging) {
                                change.consume()
                                val lo = pillXFor(0)
                                val hi = pillXFor(tabs.size - 1)
                                // 1:1 跟手 = **每帧把位置写进弹簧本身**,而不是记在旁边。
                                // 同鸿蒙 `pillTo()`。上一版记在 dragAccum 里,松手切回弹簧值
                                // 就出现回跳那一帧(见 [dragging] / H105)。
                                //
                                // ⚠️ 增量累在 `dragCmdX` 上、而不是读 `pillX.value` 再加:
                                // 本回调在 Compose 1.6.8 里不是 suspend,`snapTo` 只能靠
                                // `scope.launch`(Main.immediate)递进去。若那一递晚于下一帧,
                                // 从 pillX.value 取基准就会**吞掉一帧位移**(手感变成半速)。
                                // 以命令值做基准,弹簧只负责被绘制,慢半拍也只是慢半拍,不丢量。
                                //
                                // 这里**只改位置**:透镜宽度不读拖动量(见 lensScaleOf),
                                // 所以滑动中它保持按住时那一档,不再越拖越大。
                                dragCmdX[0] = (dragCmdX[0] + amount).coerceIn(lo, hi)
                                val cmd = dragCmdX[0]
                                scope.launch { pillX.snapTo(cmd) }
                                // 用药丸中心查槽(理由见 settle),途经 tab 的高亮才与
                                // 松手提交的判定一致
                                nearIdx = tabAt(pillCx())
                            }
                        }
                    )
                }
                // 点按:按下预选 + 松手提交,全在这一个探测里(子项无 clickable,见类注释)
                .pointerInput(tabs.size) {
                    detectTapGestures(
                        onPress = { off ->
                            // 收束态三处一起关掉(按下点亮 / 预选 / 松手提交),见 [collapsed] 那条
                            // 「三个 tab 点不动是这一形态的必然」。这里**不提前 return**:
                            // 下面那句 tryAwaitRelease 仍要走完,这一下才算被本层消费掉 ——
                            // 放过去会漏到内容层,变成"淡掉的栏把点击让给了底下的列表"。
                            if (!currentCollapsed) interacting = true
                            val idx = tabAt(off.x)
                            if (idx != currentSelected && !currentCollapsed) {
                                // 按下即预选:药丸先滑到手指所在的 tab,页面等松手再切
                                previewIdx = idx
                                nearIdx = idx
                                previewTarget[0] = idx
                                previewJob = scope.launch {
                                    pillX.animateTo(pillXFor(idx), settleSpec)
                                }
                            }
                            val released = tryAwaitRelease()
                            // 只在非拖拽态熄灭:横拖接管时 dragging=true,interacting
                            // 归拖拽路径(settle)管,这里清了会把拖拽全程的放大掐灭
                            if (!dragging) interacting = false
                            if (released && !dragging && !currentCollapsed) {
                                val commitIdx = if (previewIdx >= 0) previewIdx else idx
                                previewIdx = -1
                                nearIdx = -1
                                if (commitIdx != currentSelected) {
                                    // 切格这一下可能是双击的第一下;下一格上的时间窗不该继承它
                                    lastTabTap[0] = -1L
                                    lastTabTap[1] = -1L
                                    currentOnSelect(commitIdx)
                                } else {
                                    val now = SystemClock.uptimeMillis()
                                    if (lastTabTap[1] == commitIdx.toLong() &&
                                        now - lastTabTap[0] in 0..DOUBLE_TAP_MS) {
                                        // 一次双击只触发一次:清掉时间窗,第三下重新算
                                        lastTabTap[0] = -1L
                                        lastTabTap[1] = -1L
                                        currentOnDoubleTap(commitIdx)
                                    } else {
                                        lastTabTap[0] = now
                                        lastTabTap[1] = commitIdx.toLong()
                                    }
                                }
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
            val ready = placed && barWpx > 0f
            val active = if (nearIdx >= 0) nearIdx else currentSelected

            // 0) 静止底:唯一常驻的选中标记。位置钉在 pillPx(那条 1:1 跟手的边)上,
            //    所以拖动中它跟着手指走;松手后玻璃缩没,灰底停在新的选中项 —— 交接是连续的。
            //    **尺寸和透镜共用同一条 [lensScaleOf] 曲线**:两者同中心、同 [ASPECT]
            //    (REST_W = REST_H × ASPECT,透镜宽 = REST_W × s、高 = 宽 ÷ ASPECT = REST_H × s),
            //    所以按住时两颗椭圆**逐帧完全重合**。之前灰底恒为 REST_W、玻璃 1.22 倍盖上去,
            //    半透明的玻璃就把"小一号的灰底"透出来,读成透镜里另画了一颗椭圆(见 H107)。
            if (ready) {
                val restScale = lensScaleOf(lensAlphaOf(growth.value))
                Box(
                    Modifier
                        // **纵向交给布局居中,不再自己算**:之前是 `offset { y = (barHpx - h)/2 }`,
                        // 而 `barHpx` 是 GLASS_BAR_H 这个**常量**换算出来的数 —— 栏高一旦和这个
                        // 常量脱钩(改栏高、给栏加纵向 padding),两颗椭圆就会静悄悄地偏出去。
                        // align(CenterStart) 让"在栏内纵向居中"成为结构事实(装机反馈"透镜置底")。
                        .align(Alignment.CenterStart)
                        .offset {
                            val w = with(density) { (REST_W * restScale).toPx() }
                            IntOffset((pillPx() + (restWpx - w) / 2f).roundToInt(), 0)
                        }
                        .size(width = REST_W * restScale, height = REST_H * restScale)
                        .background(
                            color = colorScheme.onSurfaceVariant.copy(alpha = REST_TINT),
                            shape = CircleShape
                        )
                )
            }

            // 1) 透镜:**一颗节点搞定染色 + 厚度渐变 + 高光边**,里面不再放内容副本。
            //    透明度挂在 graphicsLayer 上,所以背景、渐变、描边、投影一起缩没 ——
            //    少挂任何一处都会看到"玻璃没了但影子还在"。
            //    静止时 alpha=0,等于这一层不存在(参考片:没有手指时栏上只有一块扁灰底)。
            //    抽成子组件的唯一理由是**失效范围**:它的尺寸每帧都变,留在本层会把
            //    内容层一起拖进重组(见 [growth] 的注释)。
            if (ready) {
                GlassLens(
                    growth = growth,
                    pillCx = { pillCx() },
                    isDark = isDark,
                    // 纵向居中交给布局(见 GlassLens 内注释);align 是 BoxScope 的扩展,
                    // 只能在调用处拿到,所以从这一层传进去。
                    modifier = Modifier.align(Alignment.CenterStart)
                )
            }

            // 2) 内容层:图标 + 文字,**只画一份,压在玻璃之上,永远静止**。
            //    这一层不允许任何形变(口径与逐帧取证见类注释)。上一版它被调用两份,
            //    镜内那份副本负责表达"拖影";现在只剩一份。
            TabItemsRow(
                tabs = tabs,
                active = active,
                selected = currentSelected,
                onSelect = onSelect,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = ITEM_INSET)
            )
        }
    }
}

/**
 * 玻璃的存在感:**0 = 静止时压根没有这颗透镜**,1 = 按到底。
 * 不新开状态量,直接从按下弹簧派生 —— 透明度、尺寸、栏缩放跟的是同一条曲线,天然同步。
 */
private fun lensAlphaOf(growth: Float): Float =
    ((growth - 1f) / (LENS_PRESS - 1f)).coerceIn(0f, 1f)

/**
 * 按下那一下的整体放大。
 *
 * ⚠️ 拖动幅度**不在这个式子里** —— 这一行就是"滑动时不再继续变大"的实现点。
 * 上一版这里乘了一段拖影强度(前后缘之差),于是粘滞拽长直接表现为越拖越大。
 */
private fun lensScaleOf(alpha: Float): Float = 1f + (LENS_SCALE - 1f) * alpha

/**
 * 第 1 层:透镜本体。染色 + 厚度渐变 + 高光边 + 投影,一颗节点,**里面什么都不画**。
 *
 * 尺寸是**直接改 width/height**,不是图层缩放:缩放会把高光边和渐变一起放大,读起来是
 * "一张图放大"而不是"一颗玻璃长大"。宽度只有一个来源 —— 按下放大([lensScaleOf])×
 * 静止底宽([REST_W]),**式子里没有任何拖动量**;高度由 [ASPECT] 从宽度倒推,
 * 所以静止/按住两态比例一致(形状不变量)。
 *
 * 抽成独立 composable 是为了**失效范围**:它的尺寸在按下/松手的 ~200ms 里逐帧变,
 * 挂在 [GlassNavBar] 那一层会把内容层一起拖进重组。静止时 `alpha = 0`,
 * 整颗玻璃等于不存在。
 *
 * @param pillCx 静止底中心的 x 栏内坐标 —— 透镜绕它等比放大,所以始终"套"在灰底正中,
 *   而不是往右长。逐帧变化,只画在 offset 的 lambda 里读。
 */
@Composable
private fun GlassLens(
    growth: State<Float>,
    pillCx: () -> Float,
    isDark: Boolean,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val density = LocalDensity.current
    val lensA = lensAlphaOf(growth.value)
    val glassK = if (isDark) GLASS_K_DARK else 1f
    val lw = REST_W * lensScaleOf(lensA)
    /** 高度**永远由宽度除以 [ASPECT] 得出** —— 这一行就是"等比例放大"的全部实现 */
    val lh = lw / ASPECT

    Box(
        modifier
            // 纵向居中由**调用处传进来的 `align`** 负责(它是 BoxScope 的扩展,这一层拿不到),
            // offset 只表达"跟手的那一维"。这样"透镜在栏里纵向居中"不再依赖 GLASS_BAR_H
            // 这个常量有没有跟着栏的实际高度改(装机反馈"透镜置底")。
            .offset {
                val w = with(density) { lw.toPx() }
                IntOffset((pillCx() - w / 2f).roundToInt(), 0)
            }
            .size(width = lw, height = lh)
            .graphicsLayer {
                alpha = lensAlphaOf(growth.value)
                // 圆角**恒等于半高**(CircleShape)⇒ 永远是一颗标准长椭圆。
                // 之前在拽长时把圆角收成 0.42 倍高,想读成"软玻璃被拽扁",
                // 结果整颗看起来是圆的 —— 形变量全交给宽度
                shape = CircleShape
                clip = false
            }
            // 染色垫底,厚度渐变压在它上面(渐变中间全透,否则又把内容洗白)
            .background(
                // 跟着弹簧走而不是跟着 interacting 跳变 —— 否则刚起步颜色就"啪"地深一档
                color = colorScheme.surface.copy(alpha = LENS_TINT + lensA * 0.10f),
                shape = CircleShape
            )
            // 厚度感:参考片那颗玻璃**上缘进光、下缘压暗**,不是均匀一块白。
            // 深色下压暗那一段没有意义(底下本来就是墨),换成下缘也接一点光。
            .background(
                brush = Brush.verticalGradient(
                    0f to Color.White.copy(alpha = 0.20f * glassK),
                    0.42f to Color.Transparent,
                    1f to if (isDark) Color.White.copy(alpha = 0.07f)
                    else Color.Black.copy(alpha = 0.10f)
                ),
                shape = CircleShape
            )
            // 投影**只要环境光那一份,不要方向光那一份**(spotColor 置透)。
            // 默认的 shadow() 是 ambient + spot 两层:ambient 与形状同心,spot 按
            // 「光源在上方」往下偏移 —— 偏移的那层在长椭圆上会露出一道贴着下缘的暗弧,
            // 读起来像透镜里另画了一个小椭圆(见 H107)。spot 归零后暗边回到同心。
            // 深色主题实测这一层只有 1/255(栏本身就是暗底),留着它主要是给浅色主题
            // 那圈厚边;它不是"镜内椭圆"的成因,别指望调它能修好那颗椭圆。
            .shadow(
                elevation = 6.dp,
                shape = CircleShape,
                clip = false,
                spotColor = Color.Transparent
            )
            // 高光边:参考片那圈亮边占"玻璃感"读感的一半;深色受光量另收一档
            .border(1.dp, Color.White.copy(alpha = LENS_RIM * glassK), CircleShape)
    )
}

/**
 * tab 内容行:图标 + 文案,对称地放进 [ITEM_INSET] 内收带里
 * (padding 挂在外层调用处,因为槽位几何 `slotCx` 在那一层算,两处必须读同一个常量)。
 *
 * **这一层不允许任何形变**:图标/文案零位移、零缩放(口径与逐帧取证见 [GlassNavBar])。
 * 上一版它被调用两份(基础层 + 镜内副本),副本负责表达"拖影";现在只剩一份,
 * 所以 `interactive` 那个给副本关命中的开关也一起删了。
 *
 * 命中走外层 Box 的两个 pointerInput,子项只挂 semantics —— 理由见 [GlassNavBar]。
 */
@Composable
private fun TabItemsRow(
    tabs: List<GlassTabSpec>,
    active: Int,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(modifier) {
        tabs.forEachIndexed { idx, tab ->
            // 图标与文字的间距收得很紧(space 2):间距一大,透镜要罩住整块内容就得
            // 跟着变高,观感发"胖"(对齐鸿蒙同款注释)
            Column(
                modifier = Modifier
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
                    },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Icon(
                    tab.icon,
                    contentDescription = null,
                    tint = if (active == idx) colorScheme.primary else colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(19.dp)
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    tab.label,
                    // 11sp / 0.5sp 字距 == 鸿蒙 TypeScale.caption + Tracking.caption。
                    // 曾经为了收小整条栏压到 9,理由是"两字的文案比图标还宽,透镜就得跟着变宽" ——
                    // 那条链已经不成立了(透镜远大于内容块),而 9 号字真机上读起来太小。
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontSize = 11.sp,
                        letterSpacing = 0.5.sp
                    ),
                    color = if (active == idx) colorScheme.primary else colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
