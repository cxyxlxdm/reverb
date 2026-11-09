package com.yuyin.reverb.ui.components

import android.widget.Toast
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.FormatListBulleted
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.SelectAll
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.lerp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import coil.compose.AsyncImage
import com.yuyin.reverb.data.local.InboxStore
import com.yuyin.reverb.data.model.DownloadStatus
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.data.remote.BilibiliSource
import com.yuyin.reverb.playback.PlayMode
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.theme.CeladonDim
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/**
 * 分段/分类用的**药丸 chip**。
 *
 * 与 Material 的 `FilterChip` 默认样式相比,去掉了两样:圆角由 8dp 改为全圆,
 * 以及去掉 1dp 描边。这是**跟鸿蒙端对齐**的结果 —— 鸿蒙那边一直是全圆实底药丸,
 * 两端并排看时 Material 那种「圆角矩形 + 细描边」显得更硬。
 *
 * 未选中是 onSurfaceVariant 的 10% 实底(与鸿蒙 `ChipsRow` 同一配方),选中是强调色实底。
 *
 * 全项目三处 chip 都走这里:音阁分段、发现页分类(受 `BuildConfig.CATALOG` 门控)、搜索结果的节目/单集分段。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PillChip(
    selected: Boolean,
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(text) },
        modifier = modifier,
        shape = RoundedCornerShape(percent = 50),
        border = null,
        colors = FilterChipDefaults.filterChipColors(
            containerColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.10f),
            labelColor = MaterialTheme.colorScheme.onSurfaceVariant,
            selectedContainerColor = MaterialTheme.colorScheme.primary,
            selectedLabelColor = MaterialTheme.colorScheme.onPrimary
        )
    )
}

/** 分类玻璃条的让位总高(条 44dp + 与内容的 8dp 间距):pager 段的列表顶部要滚出这么多。 */
val GLASS_CHIPS_TOP_PAD = 52.dp

/**
 * 分段条右端「还有内容」渐隐带的宽度。**只在内容真的溢出、且还没滚到右端时出现**
 * (判据见 `ChipsEdgeFade`),不是常驻装饰 —— 装得下三段标签的订阅条上它根本不存在,
 * 常驻会让条看起来永远糊了一角。
 *
 * 36 与鸿蒙 `CHIPS_EDGE_FADE_W` **同值同式**:chip 右内边距 14 + 一颗被切的 chip 露出的
 * 半截圆角。再窄还是"硬切"(读不出渐隐),再宽就糊到 chip 的可读文字上。
 * 这条是鸿蒙 2026-09-29 真机定稿后同构过来的(那份判据与画法的验收见 H116 / ROADMAP 三-A)。
 */
val GLASS_CHIPS_EDGE_FADE_W = 36.dp

/**
 * 悬浮玻璃栏占掉的纵向空间:各页列表的底部 contentPadding 要额外加上的量,
 * 由 MainShell 量出注入。玻璃栏是叠层悬浮的,列表视口必须延伸到栏下
 * (内容从玻璃下滚过才有"透"可言),末项又要能滚出栏上方 —— 全靠这个让位。
 */
val LocalGlassBottomPad = staticCompositionLocalOf { 0.dp }

/**
 * 「跳进这一集所属频道页」的入口,由 [com.yuyin.reverb.ui.ReverbRoot] 在 NavHost 外层注入一次。
 *
 * 为什么走 CompositionLocal 而不是逐层传参:消费点有三类(共用行 [EpisodeListItem]、
 * 待播页自写的那一行、[MiniPlayer] 的封面),而它们到外壳之间隔着音阁的六个分段与
 * 队列页的两种宿主(独立页 / 内嵌段)—— 显式传要改十几个签名,而这条信息本来就是**外壳级**的,
 * 与 [LocalGlassBottomPad] 同一类。
 *
 * 用 `compositionLocalOf` 而不是 `static`:static 的语义是"值永不变",而这个是导航回调,
 * 一旦哪天改成按页提供,static 会让**所有读者**整体重建,症状还很难归因。
 */
val LocalOpenPodcastChannel = compositionLocalOf<((String) -> Unit)?> { null }

/**
 * 派生「点封面进频道页」的回调,三条门任一不满足就返回 null —— 返回 null 时封面**不加**
 * clickable,点击照旧落到整行(起播),不会出现"看着能点、点了没反应"。
 *
 * ① 外壳提供了入口(见 [LocalOpenPodcastChannel]);
 * ② `episode.feedUrl` 非空 —— 与播放页频道名那处同一个判据(`PlayerScreen`),
 *    老数据里 feedUrl 可能缺失,不判就是往路由里塞空串;
 * ③ [allow] —— **频道详情页自己传 false**:已经在这档的页面里,再点就是往栈上压一份自己。
 */
@Composable
fun coverChannelJump(episode: Episode, allow: Boolean = true): (() -> Unit)? {
    val open = LocalOpenPodcastChannel.current
    if (!allow || open == null || episode.feedUrl.isBlank()) return null
    return { open(episode.feedUrl) }
}

/**
 * 分类玻璃条:悬浮胶囊条 + 一颗透明胶囊指示器,**随内容 Pager 的拖动 1:1 平移**。
 * 与鸿蒙端 ChipsRow/ChipsCapsule 同一套设计(装机验收基准),但实现简单得多:
 * Compose 的 PagerState 原生给出连续页位置(currentPage + currentPageOffsetFraction),
 * 不需要鸿蒙那种手写回调总线 —— 这也是 H88/H89 两坑存在的根因(Swiper 不暴露进度)。
 *
 * @param progress 连续页位置,如 `{ pagerState.currentPage + pagerState.currentPageOffsetFraction }`。
 *   以 lambda 传入:拖拽期逐帧读它的状态,**只有胶囊这一颗小组件逐帧重建**,
 *   chips 行与调用方(整页)不参与 —— 同鸿蒙 H64 的最小重建面原则。
 * @param selected 高亮项(调用方传 pagerState.currentPage 即可,过半自动预切,
 *   与鸿蒙 dragTarget 语义一致;只在翻页瞬间离散变化,不会拖累整页重建)。
 * @param trailing 跟在最后一枚 chip **后面**、会随 chips 一起横滚的补充项(如「排序」)。
 * @param endAction 钉在**条内右端**、不随 chips 滚的按钮(如「清空」「宫格切换」)。
 *   由条自己摆在末尾 ⇒ 天然垂直居中、且永远贴着条的右缘,调用方不要再补对中偏移。
 *   ⚠️ 传了不等于一定占位:lambda 里若用 `if` 判断显示与否,不显示时它会留 8dp 空档。
 *   鸿蒙 `ChipsRow` 有同名同语义的 `@BuilderParam`,改一处要两端一起改。
 */
@Composable
fun GlassChipsRow(
    labels: List<String>,
    selected: Int,
    progress: () -> Float,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    trailing: (@Composable RowScope.() -> Unit)? = null,
    endAction: (@Composable () -> Unit)? = null
) {
    val colorScheme = MaterialTheme.colorScheme
    val scroll = rememberScrollState()
    val density = LocalDensity.current
    // 各 chip 在滚动内容坐标系里的 x/宽(非 lazy Row:分类 ≤19 个,全量摆的开销可忽略,
    // 换 LazyRow 的话胶囊就得跟着滚动补偿逐项组合,得不偿失)
    val metrics = remember { mutableStateMapOf<Int, Pair<Float, Float>>() }

    // 横滑切到屏幕外的分类时,把选中 chip 滚进可视区(对齐鸿蒙 revealSelected:x - 80)。
    // 两个方向都要滚:向右换页滚进来,向左换页也滚回来 —— 只防「向后滚」的话,
    // 换到屏幕左侧的分类时 chip 永远停在屏幕外(H90 用户反馈)。
    LaunchedEffect(selected, labels.size) {
        val m = metrics[selected] ?: return@LaunchedEffect
        val revealPad = with(density) { 80.dp.toPx() }
        val target = (m.first - revealPad).roundToInt().coerceAtLeast(0)
        if (target != scroll.value) scroll.animateScrollTo(target)
    }

    // 玻璃条原点(窗口坐标):chip 量测要以它为基准,见下
    var boxOriginX by remember { mutableStateOf(0f) }

    Box(modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        // 条**恒为通栏**(占满父容器给的可用宽)。中间一度改成"按内容收口"(见 H106),
        // 装机反馈又改回来了:通栏是**稳定的一条**,收口之后每切一个分段条的右缘就跳一次
        // (订阅段有按钮、收藏段没有 ⇒ 宽 1213 / 1070 两态),读起来像条在抖。
        // 收口本来是治"右半截空白"的,而空白的正解是**把该段真正需要的动作放到右端**
        // (见 LibraryScreen 的 endAction:每段都有按钮之后,通栏不再有死区)。
        //
        // 因此这里也不需要"量内容再 setState 改宽"那条路 —— 那是 H106 记录的首帧闪通栏
        // 的成因,现在连需求都没了。
        Box(
            Modifier
                .onGloballyPositioned { boxOriginX = it.positionInWindow().x }
                .fillMaxWidth()
                .height(44.dp)
                // 阴影外形必须用真胶囊(percent=50),不能用与外观同款的 21dp:
                // 半径小于半高时,RenderNode 高程阴影的上下两条直边投影在形状中央
                // 留下一条未覆盖的接缝,透过 α0.85 玻璃显形为白线(H92;21dp→6px,
                // 19dp→17px,真胶囊→≈1px)。视觉裁剪仍用 21dp,观感不变。
                .shadow(elevation = 6.dp, shape = RoundedCornerShape(percent = 50), clip = false)
                .clip(RoundedCornerShape(21.dp))
                .background(colorScheme.surface.copy(alpha = 0.85f))
                .border(0.8.dp, colorScheme.outline.copy(alpha = 0.45f), RoundedCornerShape(21.dp))
        ) {
            ChipsCapsule(metrics = metrics, count = labels.size, progress = progress, scroll = scroll)
            Row(verticalAlignment = Alignment.CenterVertically) {
                // chips 段的宿主:占位仍由这层的 `weight(1f)` 负责(条宽 − 按钮段),
                // 装得下就不滚、装不下才横滚。为什么多包一层 Box:右端那条渐隐带要贴在
                // **chips 视口**的右缘,而不是玻璃条的右缘 —— 有按钮的那几段两者差着一个按钮段宽。
                // Box 的子项是覆盖层、不占位,所以它不会把按钮推走(鸿蒙同处用一个 Stack 达成同一目的)。
                Box(Modifier.weight(1f)) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .horizontalScroll(scroll)
                            .padding(horizontal = 8.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        labels.forEachIndexed { i, label ->
                            val sel = i == selected
                            // 选中态的底色交给胶囊,chip 自己只换文字色;颜色切换做 200ms 淡入淡出
                            val bg by animateColorAsState(
                                targetValue = if (sel) Color.Transparent else colorScheme.onSurfaceVariant.copy(alpha = 0.10f),
                                animationSpec = tween(200, easing = FastOutSlowInEasing),
                                label = "chipBg$i"
                            )
                            val fg by animateColorAsState(
                                targetValue = if (sel) colorScheme.primary else colorScheme.onSurfaceVariant,
                                animationSpec = tween(200, easing = FastOutSlowInEasing),
                                label = "chipFg$i"
                            )
                            Box(
                                Modifier
                                    .onGloballyPositioned { c ->
                                        // 用窗口坐标差换算成「玻璃条内容坐标」:positionInParent
                                        // 是叶子布局坐标,不含 Row 自己的 padding(h=8dp),直接拿去
                                        // 减 scroll 会让胶囊恒偏左一个 padding。窗口差天然带上
                                        // padding、随滚动实时更新,补回 scroll.value 即成滚动
                                        // 无关的内容坐标(见 ChipsCapsule 的减法)。
                                        metrics[i] = c.positionInWindow().x - boxOriginX + scroll.value to
                                            c.size.width.toFloat()
                                    }
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(bg)
                                    .clickable { onSelect(i) }
                                    .padding(horizontal = 14.dp, vertical = 7.dp)
                            ) {
                                Text(label, style = MaterialTheme.typography.labelLarge, color = fg)
                            }
                            Spacer(Modifier.width(8.dp))
                        }
                        trailing?.invoke(this)
                    }
                    // `align` 要 BoxScope,所以在**这里**(调用点)传进去,组件内部只用普通 Modifier
                    ChipsEdgeFade(
                        scroll = scroll,
                        color = colorScheme.surface,
                        modifier = Modifier.align(Alignment.CenterEnd)
                    )
                }
                // 条内右端的固定按钮。之前它是**父容器**的 CenterEnd 子项 —— 条一旦收口
                // (不再通栏)它就会掉到条外面去,所以连 8dp 端距一起搬进这条 Row 的末尾,
                // 天然贴着条的右缘、垂直居中。
                // ⚠️ 也不要退回调用方那套 `.align(TopEnd) + padding(top=2dp)` 的手工对中 ——
                // 那颗按钮原先浮在条**外面**,和 chips 的基线各算各的,一端改了另一端就漂(H96 同类)。
                if (endAction != null) {
                    Box(Modifier.padding(end = 8.dp)) { endAction() }
                }
            }
        }
    }
}

/**
 * 「右端还有内容」的渐隐带(贴在 chips 视口的右缘)。
 *
 * 为什么要它:装机反馈「最后一颗 chip 被右端按钮盖住了一半」,而它其实是被视口**裁掉**了
 * (条能横滑,滑过去就完整 —— 同 H116)。裁掉和盖住在画面上一模一样,区别只有没人告诉你
 * "这边还能滑",所以修法是补这个提示,不是改布局。
 *
 * 判据两条(与鸿蒙 `refreshOverflow` 同式):① 内容比视口宽 —— Compose 里
 * `scroll.maxValue > 0` 就是它,**不用自己量内容宽**(鸿蒙那两个 `onAreaChange` 回填的
 * `chipsW` / `viewW` 在这里没有对应物,也就没有"首帧量不到"的那一档);② 还没贴右端 ——
 * `value < maxValue - 2`(那 2px 是误差地板,与鸿蒙一致)。
 * 误判方向与鸿蒙也一致:**宁可少画不多画** —— 装得下的条上 maxValue 恒为 0,它压根不出现。
 *
 * `derivedStateOf` 是让这一层**只在布尔翻转时**重组的那一道阀:滚动过程中每个像素都会读
 * `scroll.value`,直接写在组合里会让这条渐隐带逐帧重组(鸿蒙是"只在翻转时 setState",同理由)。
 * 颜色收到玻璃条自己的染色(surface α0.6),渐隐到尽头就是"一条干净的条";
 * 若收到不透明色,条身会凭空亮一块。右端不需要另外加圆角 —— 外层条已经 `.clip(21.dp)` 裁过。
 * 它不该吃掉手势(按在它上面仍要能横滚 chips,等价鸿蒙那层的 `HitTestMode.None`);
 * 这一条**尚未装机确认** —— 真机要顺手验:按住渐隐带那一段左右拖,chips 应该跟着走。
 */
@Composable
private fun ChipsEdgeFade(scroll: ScrollState, color: Color, modifier: Modifier = Modifier) {
    val moreRight by remember(scroll) {
        derivedStateOf { scroll.maxValue > 0 && scroll.value < scroll.maxValue - 2 }
    }
    if (!moreRight) return
    Box(
        modifier
            .fillMaxHeight()
            .width(GLASS_CHIPS_EDGE_FADE_W)
            .background(
                Brush.horizontalGradient(
                    0f to color.copy(alpha = 0f),
                    0.45f to color.copy(alpha = 0.28f),
                    1f to color.copy(alpha = 0.60f)
                )
            )
    )
}

/**
 * 玻璃条里的透明胶囊指示器。两种驱动其实是同一条数据:Pager 的连续页位置
 * progress ∈ [0, n-1],整数部分与分数部分分别决定插值对与进度 —— 拖拽跟手与
 * 点击滑移自然统一,不需要鸿蒙端「live 插值 / spring 收尾」两套绘制态。
 * 胶囊滑到两颗 chip 之间的空档时底下只有玻璃 + 页面底色,染色 0.26/描边 0.30
 * 才读得出"在移动"(鸿蒙端实测调出的值,直接沿用)。
 */
@Composable
private fun ChipsCapsule(
    metrics: Map<Int, Pair<Float, Float>>,
    count: Int,
    progress: () -> Float,
    scroll: ScrollState
) {
    val colorScheme = MaterialTheme.colorScheme
    val density = LocalDensity.current
    val p = progress().coerceIn(0f, (count - 1).coerceAtLeast(0).toFloat())
    val base = p.toInt()
    val frac = p - base
    val next = (base + 1).coerceAtMost((count - 1).coerceAtLeast(0))
    val a = metrics[base]
    val b = metrics[next]
    val x = if (a != null && b != null) lerp(a.first, b.first, frac) - scroll.value else null
    val w = if (a != null && b != null) lerp(a.second, b.second, frac) else null
    Box(
        Modifier
            .offset {
                IntOffset((x ?: 0f).roundToInt(), 5.dp.roundToPx())
            }
            .width(if (w != null && w > 0f) with(density) { w.toDp() } else 0.dp)
            .height(34.dp)
            .background(colorScheme.primary.copy(alpha = 0.26f), RoundedCornerShape(17.dp))
            .border(0.8.dp, colorScheme.primary.copy(alpha = 0.30f), RoundedCornerShape(17.dp))
    )
}

fun formatTime(ms: Long): String {
    if (ms <= 0) return "00:00"
    val totalSec = ms / 1000
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    val s = totalSec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

fun formatDurationSec(sec: Long): String = if (sec <= 0) "" else formatTime(sec * 1000)

/**
 * 单集发布日期的展示形态:`Fri, 21 Aug 2026`。
 *
 * 原先这里是 `episode.pubDate.take(16)` —— 直接把 RSS 里的 pubDate 原始串**截前 16 字符**。
 * 对 RFC-822 的源(`Fri, 21 Aug 2026 10:00:00 +0800`)恰好得到想要的样子,所以一直没露馅,
 * 但换成 ISO-8601 的源就会截出 `2026-08-21T10:00` 这种半截货 —— 而 RSS 里两种都常见。
 * 格式保留(与鸿蒙侧 formatPubDate 逐字一致),取法改成**先解析再格式化**。
 *
 * 定死 `Locale.ENGLISH`,不跟随界面语言:两端定死才能保证同一集在两台机器上显示相同,
 * 对不了版就不好排查。解析失败时仍退回截前 16 字符 —— 至少还能看出个大概。
 */
fun formatPubDate(raw: String): String {
    val ms = InboxStore.parsePubMillis(raw)
    if (ms <= 0L) return raw.trim().take(16)
    return SimpleDateFormat("EEE, dd MMM yyyy", Locale.ENGLISH).format(Date(ms))
}

/** 人类可读的累计时长:"X 小时 Y 分" / "Y 分钟" / "小于 1 分钟"(用于收听时长展示)。 */
@Composable
fun formatListenDuration(sec: Long): String {
    if (sec < 60) return stringResource(R.string.listen_lt1m)
    val m = sec / 60
    return if (m >= 60) stringResource(R.string.listen_hm, m / 60, m % 60)
    else stringResource(R.string.listen_m, m)
}

@Composable
fun Artwork(url: String, size: Int, corner: Int = 12) {
    val shape = RoundedCornerShape(corner.dp)
    if (url.isBlank()) {
        Box(
            modifier = Modifier
                .size(size.dp)
                .clip(shape)
                .background(CeladonDim.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Rounded.GraphicEq,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary
            )
        }
    } else {
        AsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(size.dp)
                .clip(shape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
        )
    }
}

/** 填满单元格宽度的方形封面(宫格用)。无封面时以主色频谱图标占位。 */
@Composable
fun SquareArtwork(url: String, corner: Int = 14) {
    val shape = RoundedCornerShape(corner.dp)
    if (url.isBlank()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(shape)
                .background(CeladonDim.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Rounded.GraphicEq, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        }
    } else {
        AsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(shape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
        )
    }
}

/** 宫格卡片:方形封面 + 标题 + 作者,与 macOS PodcastCard 对齐。 */
@Composable
fun PodcastGridItem(podcast: Podcast, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick)) {
        SquareArtwork(podcast.artworkUrl)
        Spacer(Modifier.height(8.dp))
        Text(
            podcast.title,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        if (podcast.author.isNotBlank()) {
            Text(
                podcast.author,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
fun PodcastListItem(podcast: Podcast, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Artwork(podcast.artworkUrl, size = 60)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                podcast.title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onBackground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (podcast.author.isNotBlank()) {
                Text(
                    podcast.author,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (podcast.isPaid) {
                Text(
                    "付费",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.secondary
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun EpisodeListItem(
    episode: Episode,
    isCurrent: Boolean,
    isPlaying: Boolean,
    onPlay: () -> Unit,
    downloadStatus: DownloadStatus? = null,
    onDownload: (() -> Unit)? = null,
    onDeleteDownload: (() -> Unit)? = null,
    /**
     * 这颗下载键**置灰但留着**(而不是传 null 让整格消失)。
     *
     * 只有一个调用方会传 true:视频源(见 `BilibiliSource`)。那里的音频直链带 2 小时
     * `deadline`,**不能落盘当资产**;而"下载"在别处承诺的正是「长期留在盘上、进备份、
     * 由清除下载打理」。两者语义冲突,所以不给这个动作。自动缓存(network 层那套 300 MB
     * 预算)仍然保留 —— 那是浏览器缓存同性质的东西,且撑着现有播放性能设计。
     *
     * 为什么不传 null:null 会让整格消失,同一列表里各行的键位就错开了(用户 2026-10-28
     * 拍的口径是「置灰」,不是「隐藏」)。
     *
     * 默认值从 `audioUrl` 自己判,而不是让每个调用方传 —— 这条规矩是**集子自己的属性**
     * (地址会不会过期),不是页面的口味;搜索结果/历史/待播/收藏里都可能有视频源的单集,
     * 逐个调用点传就一定会漏一处。
     */
    downloadDisabled: Boolean = BilibiliSource.isPseudo(episode.audioUrl),
    showPodcastTitle: Boolean = false, // 搜索结果里同列多个不同播客的单集，需标出所属频道
    /**
     * 这一条**来自哪个目录**(只有搜索结果传,null = 不画)。
     *
     * 单集搜索是两路结果拼起来的(见 `PodcastRepository.searchEpisodes`:Apple 在前、
     * 视频源在后),列表头部最多只能标一个来源 —— 用户 2026-10-29 反馈"看不出这条是哪来的"
     * 就是这个结构造成的。所以来源落在**行上**,随滚动一直在。
     *
     * 判据由调用方给(它知道这一列拼了哪几路),这里只负责画:
     * 视频源那路的 `feedUrl` 是 `bilibili://…` 伪地址,调用方用 `BilibiliSource.isPseudo` 分。
     */
    sourceTag: String? = null,
    isFavorite: Boolean = false,
    onToggleFavorite: (() -> Unit)? = null,
    played: Boolean = false,            // 已播完:标题变暗 + 打勾
    /**
     * 长按菜单里的「标记为已播完 / 未播完」。**2026-10-17 起两端统一:正向那一向
     * (标记为已播完)不在任何单集列表里给**,只有 `音阁 · 历史` 保留**反向的撤销**
     * (已播完的那些条给「标记为未播完」)。
     *
     * 摘掉正向的两条理由:
     * ① **它多半是个静默空操作**。`HistoryStore.markPlayed` 开头就
     *    `if (_history.value.none { it.episode.id == episodeId }) return` —— 没播过的集
     *    没有历史条目,在发现首屏/追更/收藏/下载/搜索结果/频道页按这一项**什么都不会发生**
     *    (行不会压暗,因为这些列的 `played` 正是从这份历史里读出来的)。
     * ② 少数**真生效**的(播过、有历史条目的)反馈也只剩标题压暗这一处微弱变化,
     *    而**这一列没有回程** —— 想撤必须去 `音阁 · 历史` 那一页找同一条。
     *    一颗"多数时候空转、偶尔生效了还得换页去撤"的动作,留在浏览列里没有意义。
     *
     * `played` 的显示(标题压暗 + 打勾)照旧,那一半是有信息的。
     * 反向那颗必须留在历史列:发现页「继续收听」横条的「标记已播完」改的就是这份 played,
     * 横条按"未播完"过滤,不在历史页给回程就变成单向操作(唯一复原办法是重新播一次,
     * `record()` 会把 played 复位)。
     * 正因为"接了这个回调就只会是反向",下面菜单项的文案是**写死**的 `mark_unplayed`,
     * 不再按 `played` 换向 —— 换向表达式等于给正向留一条"下一个人顺手接上"的通道。
     * (横条那张卡用的是 `DiscoverScreen` 里自己的菜单,不受这条影响。)
     */
    onTogglePlayed: (() -> Unit)? = null,
    onPlayNext: (() -> Unit)? = null,     // 长按菜单:下一个播放
    onEnqueue: (() -> Unit)? = null,      // 长按菜单:加入队列;showQueueAdd 时也是行内键的动作
    /// 行内「加入播放列表」键,只在节目详情页开(对齐鸿蒙):浏览选集为主的场景,
    /// 一步入队比长按菜单顺手。Compose 里子 IconButton 消费点击,行 ripple 不会连带亮起
    /// —— 鸿蒙那边要靠 stopPropagation 手工截断的问题,这边的系统行为本来就是对的。
    showQueueAdd: Boolean = false,
    /// 点封面跳进这一集所属的频道页(判据见 [coverChannelJump])。
    /// **频道详情页传 false**,其余调用方不用管 —— 是否真的可点还要看外壳有没有提供入口。
    coverOpensChannel: Boolean = true,
    /// ---- 多选(批量加入待播)----
    /// 选择模式由**调用方的已选集合**驱动(见各列表页的 `picked`),行自身不存这份状态:
    /// 行会被 LazyColumn 回收,状态留在行里就会随滚动丢失(且无法"全选")。
    /// `selectionMode` 为真时整行的点击语义**从「播这一集」换成「勾选/取消」**,
    /// 长按菜单也不再出现。
    selectionMode: Boolean = false,
    selected: Boolean = false,
    onToggleSelect: (() -> Unit)? = null,
    /// 长按菜单里那颗「多选」:由调用方进入选择模式并带上被长按的这一集。
    /// null = 这一列不做批量(发现首屏、搜索结果 —— 这两处是**预览与跨源结果**,逐条操作才是原意)。
    /// 追更 / 收藏 / 下载 / 历史 / **频道详情页**都给(后者 2026-10-17 补,与鸿蒙同步)。
    onEnterSelection: (() -> Unit)? = null
) {
    var menuOpen by remember { mutableStateOf(false) }
    val context = LocalContext.current
    /**
     * 按下点(相对整行左上角),长按菜单以它为锚点弹出。
     *
     * 原先菜单直接挂在包住整行的 `Box` 上,而那个 Box 是整行宽的 —— Material 的
     * `DropdownMenuPositionProvider` 会把菜单左边缘对齐锚点左边缘,于是无论按在哪儿,
     * 菜单一律贴屏幕最左弹出,跟手指没关系。改成在按下点放一个**零尺寸锚点**,
     * 由 Compose 自己决定往下还是往上、往右还是往左展开(贴边时自动翻转),不用手算。
     */
    var pressPoint by remember { mutableStateOf(Offset.Zero) }
    val hasMenu = onTogglePlayed != null || onPlayNext != null || onEnqueue != null || onEnterSelection != null
    // 封面点击 → 频道页。null 时封面不加点击,整行照旧(起播)。判据见 [coverChannelJump]
    val jumpToChannel = if (selectionMode) null else coverChannelJump(episode, coverOpensChannel)
    val openChannelLabel = stringResource(R.string.a11y_open_channel)
    val rowModifier = Modifier
        .fillMaxWidth()
        .then(
            when {
                // 选择模式:整行只剩「勾选」这一个语义,长按也不弹菜单
                // (菜单那三项在批量面前逐条做没有意义)。
                selectionMode -> Modifier.clickable { onToggleSelect?.invoke() }
                hasMenu -> Modifier
                    // Initial 阶段只「偷看」按下位置,不消费事件 —— 否则会和 combinedClickable
                    // 抢同一个指针,点击/长按都会失效。
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                            pressPoint = down.position
                        }
                    }
                    .combinedClickable(onClick = onPlay, onLongClick = { menuOpen = true })
                else -> Modifier.clickable(onClick = onPlay)
            }
        )
        .padding(horizontal = 16.dp, vertical = 12.dp)
    Box {
    Row(
        modifier = rowModifier,
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 封面缩略图 + 播放/暂停轻蒙层:更有色彩,并保留播放态与播放入口(整行可点)
        Box(
            Modifier
                .size(52.dp)
                .then(
                    if (jumpToChannel != null)
                        Modifier
                            .clip(RoundedCornerShape(10.dp))
                            // ⚠️ 这里必须是 combinedClickable 而不是 clickable:
                            // 子节点的 Main 遍先于父节点且会消费按下,单纯 clickable 会让
                            // **落在封面上的那一下长按什么都得不到**(整行的长按菜单被截走又没人接),
                            // 用户按在头像上长按就变成"没反应"。所以封面自己也要接住长按:
                            // 弹的还是同一个菜单(pressPoint 在整行的 Initial 遍里已经记下了手指位置)。
                            .combinedClickable(
                                onClick = jumpToChannel,
                                onLongClick = { if (hasMenu) menuOpen = true else onToggleSelect?.invoke() }
                            )
                            .semantics { contentDescription = openChannelLabel }
                    else Modifier
                ),
            contentAlignment = Alignment.Center
        ) {
            Artwork(episode.artworkUrl, size = 52, corner = 10)
            Box(
                Modifier
                    .matchParentSize()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Color.Black.copy(alpha = if (isCurrent) 0.42f else 0.28f))
            )
            if (selectionMode) {
                // 勾选态压在封面上:行里再摆一颗 checkbox 会把 52dp 的封面挤变形,
                // 而"选中"本来就是这一行唯一要说的话。
                Icon(
                    if (selected) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
                    contentDescription = stringResource(
                        if (selected) R.string.a11y_selected else R.string.a11y_unselected
                    ),
                    tint = if (selected) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = 0.9f),
                    modifier = Modifier.size(24.dp)
                )
            } else {
                // 封面已经是「进频道页」的入口时,那颗播放/暂停只作状态显示:
                // 读屏不能再念「播放」,否则标签说的和点出来的不是同一件事。
                Icon(
                    if (isCurrent && isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    contentDescription = if (jumpToChannel != null) null
                    else stringResource(if (isPlaying && isCurrent) R.string.a11y_pause else R.string.a11y_play),
                    tint = Color.White,
                    modifier = Modifier.size(24.dp)
                )
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    episode.title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = when {
                        isCurrent -> MaterialTheme.colorScheme.primary
                        played -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                        else -> MaterialTheme.colorScheme.onBackground
                    },
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
                if (played) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        Icons.Rounded.Check,
                        contentDescription = stringResource(R.string.a11y_played),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
            val meta = listOf(formatPubDate(episode.pubDate), formatDurationSec(episode.durationSec))
                .filter { it.isNotBlank() }
                .joinToString("  ·  ")
            val showTitle = showPodcastTitle && episode.podcastTitle.isNotBlank()
            // 搜索结果：同一行内 频道名靠左（最多 10 字符，超出前 9 字 + 省略号）、时间靠右
            // （时间宽度固定，右缘天然整齐）；其它场景保持时间单独左对齐。
            if (showTitle) {
                val name = episode.podcastTitle
                val shown = if (name.length > 10) name.take(9) + "…" else name
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    // 来源标签 + 频道名一起占左侧,meta 仍贴右缘 —— 三者同行时先让频道名收缩,
                    // 不给标签换行(标签很短,换行反而把它和名字拆成两行,行高就变了)
                    Row(
                        Modifier.weight(1f, fill = false),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (sourceTag != null) {
                            Text(
                                sourceTag,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(4.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(horizontal = 4.dp, vertical = 1.dp)
                            )
                            Spacer(Modifier.width(6.dp))
                        }
                        Text(
                            shown,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (meta.isNotBlank()) {
                        Text(
                            meta,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1
                        )
                    }
                }
            } else if (meta.isNotBlank()) {
                Text(
                    meta,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1
                )
            }
        }
        // ⚠️ 选择模式里这三颗一律**不显示**(不是禁灰):它们在行内自己消费点击,
        // 留着就是"点行尾那一下取消收藏、点行中间勾选"—— 同一行两种语义,用户无从预期。
        if (onToggleFavorite != null && !selectionMode) {
            IconButton(onClick = onToggleFavorite) {
                Icon(
                    if (isFavorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                    contentDescription = stringResource(if (isFavorite) R.string.a11y_unfavorite else R.string.a11y_favorite),
                    tint = if (isFavorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        if (showQueueAdd && onEnqueue != null && !selectionMode) {
            // 与鸿蒙同位次(收藏心形之后、下载控件之前)。图标是**手抄鸿蒙那枚** `add_songlist`
            // (列表 + 音符 + 加号)—— Material 没有这一枚,而直接用 QueueMusic 会和
            // 「打开队列页」的入口同形不同义(两端的注释里都记着这条真机反馈)。
            // 见 `res/drawable/ic_queue_add.xml`。
            IconButton(onClick = {
                onEnqueue()
                // 入队结果在别页,界面无任何变化,不提示等于没按上
                Toast.makeText(context, R.string.queue_added, Toast.LENGTH_SHORT).show()
            }) {
                Icon(
                    painterResource(R.drawable.ic_queue_add),
                    contentDescription = stringResource(R.string.queue_add),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        if (!selectionMode && (onDownload != null || onDeleteDownload != null)) {
            DownloadControl(downloadStatus, onDownload, onDeleteDownload, downloadDisabled)
        }
    }
        if (hasMenu) {
            // 零尺寸锚点:自身不占布局(Popup 也不占),只把菜单的原点挪到手指按下处
            Box(Modifier.offset { IntOffset(pressPoint.x.roundToInt(), pressPoint.y.roundToInt()) }) {
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                if (onPlayNext != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.queue_play_next)) },
                        onClick = { menuOpen = false; onPlayNext() }
                    )
                }
                if (onEnqueue != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.queue_add)) },
                        onClick = {
                            menuOpen = false
                            onEnqueue()
                            Toast.makeText(context, R.string.queue_added, Toast.LENGTH_SHORT).show()
                        }
                    )
                }
                // 「多选」排在「加入队列」之后:这两颗是同一件事的两种规模
                // (逐条 / 一批),而「标记已播完」是另一路的读法,放在最后。
                if (onEnterSelection != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.batch_select)) },
                        onClick = { menuOpen = false; onEnterSelection() }
                    )
                }
                if (onTogglePlayed != null) {
                    DropdownMenuItem(
                        // 文案**写死反向**,不再按 `played` 换向:正向那颗自 2026-10-17 起在两端
                        // 任何列表都不给(理由见上面 onTogglePlayed 的 KDoc)。留着换向表达式
                        // 就是留着"下一列顺手接出正向"的通道 —— 换向没了,接错才会在 review 里露出来。
                        text = { Text(stringResource(R.string.mark_unplayed)) },
                        onClick = { menuOpen = false; onTogglePlayed() }
                    )
                }
            }
            }
        }
    }
}

/**
 * 多选状态下浮在列表底部的那条操作条(「已选 N · 全选 · 加入待播 · 退出」)。
 *
 * 为什么浮在**底部**:各列的末项本来就要滚到玻璃栏上方才看得见,底部那条带
 * (`LocalGlassBottomPad` 已经把它自己算进去了)是这段列表唯一"空着"的位置;
 * 放顶部就要跟标题栏/分段玻璃条抢,而分段条右端已经有播放模式与清空那颗
 * (见 `LibraryScreen` 的 endAction)。
 *
 * 「全选」用图标而不是文字:西/法语下「已选 N」+「全选」+「加入待播」三串文字在一行里
 * 会顶出屏幕(es 的"Añadir a la cola"本身就有 16 个字符),图标不受语种长度影响。
 *
 * @param allSelected 已选数 == 总数时「全选」变灰 —— 再按一次没有任何变化,是假按钮
 *        (与各段"没内容就不摆动作"同一条规矩)。
 */
@Composable
fun SelectionBar(
    selectedCount: Int,
    totalCount: Int,
    allSelected: Boolean,
    onSelectAll: () -> Unit,
    onEnqueue: () -> Unit,
    onExit: () -> Unit,
    modifier: Modifier = Modifier
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier
            // 上限挡住西/法语:那条串里「已选 N」+「加入待播」两串文字在同一行,
            // es/fr 的对应串各 15~25 字符,不封顶会把整条推出屏外(图标也一起看不见)。
            // 超出的部分由下面的计数文字省略号收掉,动作两颗始终在行内。
            .widthIn(max = 320.dp)
            .shadow(6.dp, RoundedCornerShape(28.dp))
            .clip(RoundedCornerShape(28.dp))
            .background(scheme.surface)
            .padding(start = 16.dp, end = 2.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            stringResource(R.string.batch_selected, selectedCount),
            style = MaterialTheme.typography.bodyMedium,
            color = scheme.onBackground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false)
        )
        IconButton(onClick = onSelectAll, enabled = !allSelected, modifier = Modifier.size(40.dp)) {
            Icon(
                Icons.Rounded.SelectAll,
                contentDescription = stringResource(R.string.batch_select_all),
                tint = if (allSelected) scheme.onSurfaceVariant.copy(alpha = 0.3f) else scheme.onSurfaceVariant
            )
        }
        TextButton(onClick = onEnqueue) {
            Text(stringResource(R.string.batch_enqueue))
        }
        IconButton(onClick = onExit, modifier = Modifier.size(40.dp)) {
            Icon(
                Icons.Rounded.Close,
                contentDescription = stringResource(R.string.batch_exit),
                tint = scheme.onSurfaceVariant
            )
        }
    }
}

/**
 * 批量加入待播的**新增数**(调用方拿它出提示)。
 *
 * 不能直接报 `picked.size`:[PlayerController.enqueueAll] 对「已在队列里」的那一集是**忽略**的
 * (与单条 [PlayerController.enqueue] 同口径),而队列里的内容在「待播」那一页,
 * 用户在当前列表里看不见 —— 报了 8 实际只进 3 条,提示就成了说谎。
 *
 * ⚠️ 这一层**只做筛选,不许自己循环 `PlayerController.enqueue`**。批量入队必须整体走
 * [PlayerController.enqueueAll]:单条那版每条都同步落一次盘,全选一列(实测 1994 集)
 * 会把主线程占到 ANR(见 H186)。
 */
fun enqueuePicked(episodes: List<Episode>, picked: Set<String>): Int =
    PlayerController.enqueueAll(episodes.filter { it.id in picked })

/**
 * 多选条的**占位高度**:条子实测 44dp(40dp 的图标按钮 + 上下各 2dp 内边距)再加它与玻璃栏
 * 顶沿之间那 4dp 缝。各列表在选择模式里把它加进 `contentPadding` 的下沿,
 * 否则末行正好被这条带压掉半截(平时的下沿只有 24dp,是给单行留的)。
 */
val SELECTION_BAR_SLOT = 48.dp

/**
 * 各列表(追更 / 收藏 / 下载 / 历史 / **频道详情页**)共用的那条批量条:把 [SelectionBar] 的三条动作
 * (全选 / 加入待播 / 退出)连同**结果提示**一起收在一处。
 *
 * 为什么要有这一层而不是四个页面各写一遍:「加入待播」之后该报几条,判据在
 * [enqueuePicked] 那侧而不是页面里;四个页面各抄一遍,漏掉某个页面的提示是必然的。
 *
 * 已选集合由**调用方持有**(一个 `mutableStateOf<Set<String>>`),这里只通过 [onPicked] 整体替换。
 * 状态不放行里:行会被 LazyColumn 回收,而且「全选」要能一次改整列。
 *
 * @param picked 空集 = 不在选择模式,这一层不组合(底部那条带只在多选时出现)
 * @param episodes 这一列当前显示的全部单集(「全选」与新增数都按它算,所以必须是**显示的那一份**)
 */
@Composable
fun EpisodeBatchBar(
    picked: Set<String>,
    episodes: List<Episode>,
    onPicked: (Set<String>) -> Unit,
    modifier: Modifier = Modifier
) {
    if (picked.isEmpty()) return
    val context = LocalContext.current
    SelectionBar(
        selectedCount = picked.size,
        totalCount = episodes.size,
        allSelected = picked.size >= episodes.size,
        onSelectAll = { onPicked(episodes.map { it.id }.toSet()) },
        onEnqueue = {
            val added = enqueuePicked(episodes, picked)
            // 入队结果在「待播」那一页,当前列表看不出任何变化,不提示等于没按上
            Toast.makeText(
                context,
                if (added == 0) context.getString(R.string.batch_added_none)
                else context.getString(R.string.batch_added, added),
                Toast.LENGTH_SHORT
            ).show()
            onPicked(emptySet())
        },
        onExit = { onPicked(emptySet()) },
        modifier = modifier
    )
}

@Composable
private fun DownloadControl(
    status: DownloadStatus?,
    onDownload: (() -> Unit)?,
    onDelete: (() -> Unit)?,
    disabled: Boolean = false
) {
    when (status) {
        is DownloadStatus.Completed -> IconButton(onClick = { onDelete?.invoke() }) {
            Icon(
                Icons.Rounded.DownloadDone,
                contentDescription = stringResource(R.string.a11y_downloaded),
                tint = MaterialTheme.colorScheme.primary
            )
        }
        is DownloadStatus.Downloading -> Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(
                progress = { status.progress },
                modifier = Modifier.size(22.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.primary
            )
        }
        DownloadStatus.Queued -> Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.primary)
        }
        // 禁用态**只落在这一支**:已完成 / 下载中 / 排队中都是真实进度,置灰它们反而像按钮坏了。
        // 也只有视频源会传 true,而它永远不会有那三种状态 —— 这条限制让「禁用」只有一种读法。
        else -> if (disabled) {
            Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Rounded.Download,
                    contentDescription = stringResource(R.string.a11y_download_disabled),
                    // 用 Material 的 disabled 惯例值(38%),不是随便挑的透明度:
                    // 与系统控件置灰的观感一致,将来换主题也不会跑偏。
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                )
            }
        } else IconButton(onClick = { onDownload?.invoke() }) {
            Icon(
                Icons.Rounded.Download,
                contentDescription = stringResource(R.string.a11y_download),
                tint = if (status is DownloadStatus.Failed) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/** 节目列表左侧的圆形播放按钮：外圈轮廓 + 中心三角，播放中显示暂停并高亮。 */
@Composable
private fun PlayCircle(isCurrent: Boolean, isPlaying: Boolean, onClick: () -> Unit) {
    val accent = if (isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(
                if (isCurrent) MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                else Color.Transparent
            )
            .border(1.5.dp, accent.copy(alpha = 0.6f), CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            if (isCurrent && isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
            contentDescription = stringResource(if (isCurrent && isPlaying) R.string.a11y_pause else R.string.a11y_play),
            tint = accent,
            modifier = Modifier.size(22.dp)
        )
    }
}

/**
 * 播放模式按钮:**一颗按钮只管模式**,顺序 → 单曲循环 → 随机 → 顺序。
 * 挂在音阁「最新 / 收藏 / 下载」分段条右端与频道主页「共 N 集」那一行右端两处。
 *
 * **模式是每列各一份**(`tag` 就是列身份,见 `PlayerController.playModes`):
 * 按钮显示并修改**它所在那一列自己的**模式,所以最新设了随机、收藏仍读顺序。
 * 曾做过"全局一份"(2026-09-28 同日撤销,装机反馈「在收藏里切了单曲循环,下载也变了」)。
 *
 * **这里没有播放/暂停**:起播的入口是列表里的行 —— 点某一集就播这一整列,
 * 不需要再摆一颗"从第一行起播"。2026-09-28 之前这颗按钮是一钮两用
 * (点它 = 起播这一列 + 正在播这列时切模式),为了它先后加过 `_listPlayUsed`(H115)
 * 和 `activeListTag` 两个会话状态,还把图标画成过与全 App 相反的口径(H118)。
 * 根因是一个图标槽位同时扛「状态」和「模式」两个语义 —— 拆开之后两个补丁都不需要了。
 *
 * 图标三态就是模式本身,不再表播放状态;无障碍读的是模式名(与显示给眼睛的那一套同源)。
 */
@Composable
fun PlayModeButton(tag: String, modifier: Modifier = Modifier) {
    val modes by PlayerController.playModes.collectAsStateWithLifecycle()
    val mode = modes[tag] ?: modes.getValue("")
    IconButton(onClick = { PlayerController.cyclePlayMode(tag) }, modifier = modifier) {
        Icon(
            imageVector = when (mode) {
                PlayMode.SEQUENTIAL -> Icons.AutoMirrored.Rounded.FormatListBulleted
                PlayMode.REPEAT_ONE -> Icons.Rounded.RepeatOne
                PlayMode.SHUFFLE -> Icons.Rounded.Shuffle
            },
            contentDescription = stringResource(
                when (mode) {
                    PlayMode.SEQUENTIAL -> R.string.play_mode_sequential
                    PlayMode.REPEAT_ONE -> R.string.play_mode_repeat_one
                    PlayMode.SHUFFLE -> R.string.play_mode_shuffle
                }
            )
        )
    }
}

/**
 * 播放条整块高度 = **栏高** [GLASS_BAR_H](与 [MINI_H_COLLAPSED] 同值)。
 *
 * 历史:鸿蒙参照值 48vp → 本端配成展开 44 / 收束 52 → 2026-11-09 两态各 +4(48 / 56)。
 * ⚠️ **同一天用户第二次反馈「频道页的播放条还是矮,需要每个页面的播放条保持一致」** ——
 * 那一轮实测到差异的形态是:tab 页滚动收束时 56dp,而频道详情 / 待播队列这两页
 * **永不收束**、恒停在展开态那一档,于是同一个组件在两类页面上一高一矮(132px vs 154px,
 * Pixel 3 / 440dpi)。修法不是给那两页单独抬,而是**取消"展开比收束矮"这一档**:
 * 展开也取 56(= 8 + 40 封面 + 8),全端所有页面、两个状态都只有这一个块高。
 * 收束 morph 因此只剩三件事:球槽(0 → 56 + 8 外缝)、整块垂直落点([MiniPlayer] 的 `lift`)
 * 与栏的淡出;块高本身不再插值。
 * ⚠️ **纵向 padding 必须由封面反推**(块高 − 封面)/ 2:块高是硬约束(收束 = 栏高),
 * 封面一改 padding 不跟着改整块就会漂。所以 56 这一档配 40 封面,上下各 8dp。
 */
val MINI_H = GLASS_BAR_H

/**
 * 收束态整块高度 = **栏高** [GLASS_BAR_H]。
 *
 * 与鸿蒙同一判据:收束那一行只有一层容器(一颗球 + 一条与栏等高的胶囊),
 * 播放条自己就是那一行的容器,而不是嵌在栏里面。
 * ⚠️ 2026-11-09 第二轮起 [MINI_H] 也等于这一档(全部页面统一 56),这个常量仍单独留着:
 * 它表的是"收束态必须与栏等高"这条约束,不跟着展开态走。
 */
val MINI_H_COLLAPSED = GLASS_BAR_H

/** 展开态播放条与底部栏之间的缝(鸿蒙实测 26px = 8vp,本端取同一档)。 */
val MINI_GAP = 8.dp

/**
 * 播放条距屏幕左右 = **与玻璃栏同一道缝**([GLASS_SIDE_PAD])。
 *
 * 这是这轮改动的核心约束之一(用户原话:「宽度与底部 tab 保持一致」)。
 * 旧版是通栏 `fillMaxWidth()`,压在悬浮胶囊上读起来像两块不相干的板。
 * 宽度只有一个来源,栏改了播放条跟着改,不会各漂各的 —— 鸿蒙那边是同一对常量
 * (`BAR_SIDE_MARGIN` / `MINI_SIDE_MARGIN`)承担同一条约束。
 */
val MINI_SIDE_PAD = GLASS_SIDE_PAD

/**
 * 两态的封面边长。**两态同值 40**(= 块高 56 − 上下各 8),与鸿蒙收束档的 40 同数。
 *
 * 历史:2026-11-09 第一轮随两态块高各 +4(32/36 → 36/40),当时仍保留"展开小一档";
 * 同一天第二轮把展开也抬到 56(见 [MINI_H]),封面随之 36 → 40,**两态相等**。
 * ⚠️ 于是原先那条已知代价("封面在两态间是瞬移,因为 [Artwork] 的边长是它内部 `size: Int`,
 * 父层属性动画管不到")**不再适用**:尺寸不变,只剩圆角在 8dp 与圆之间瞬切。
 *
 * 横向代价是标题区少 4dp(相对 36 那版):411dp 屏、收束态扣掉球槽 60 + 内白 22 +
 * 四枚命中框 136 之后,标题仍有 ≈95dp,「这一条在放什么」还读得出来。
 */
val MINI_COVER_WIDE = 40
val MINI_COVER_NARROW = 40

/** 播放/暂停、下一集、队列三枚按钮的**图标**边长(鸿蒙装机三档改判后定在 16,本端同档)。 */
val MINI_SYMBOL = 16.dp

/**
 * 三枚按钮的**命中框**边长 = 图标 + 四周各 12 = 40(与 [MINI_SYMBOL] 之差的一半是内缩)。
 *
 * 图标只有 16dp,而拇指目标是 40dp(玻璃栏那三格也是按这一档给的);
 * 这三枚挤在标题与胶囊右缘之间,不外扩就会被左右两个大命中目标夹住点不中。
 * ⚠️ 三枚之间**不留横向缝隙**:40 × 3 = 120dp,再各留 8dp 就把标题区挤没了
 * (411dp 屏宽、侧缝 2×24、收束态还要扣掉球槽 52+8 与内白 14/8,留给标题只剩约 100dp)。
 */
val MINI_HIT = 40.dp

/** 胶囊左内边距:封面左缘对齐页面文字(两态同值,含义不同 —— 收束态它只是头部留白)。 */
val MINI_PAD_START = 14.dp

/** 胶囊右内边距,**按态两档**:展开 16 / 收束 8(收束态三枚按钮离胶囊右 8dp 装机读着合适)。 */
val MINI_PAD_END = 16.dp
val MINI_PAD_END_COLLAPSED = 8.dp

/**
 * 收束态的按钮排几何(2026-10-26 加 X 之后补的第四枚按钮把文字挤成了纯省略号):
 * 胶囊收窄 + 球槽占位后,文字区只剩 ~12dp。收束态把按钮间距 10→2、命中框 40→34
 * (图标恒 16 不动),随收束 morph 同一条弹簧插值 —— 展开态几何与加 X 之前完全一致。
 * 省出的 ~60dp 让文字至少放得下四五个字,「这一条在放什么」仍读得出来。
 */
val MINI_BTN_GAP = 10.dp
val MINI_BTN_GAP_COLLAPSED = 2.dp
val MINI_HIT_COLLAPSED = 34.dp

/**
 * 收束态左端那颗球的**槽宽**(与栏等高那一档,参考片是 56×56 的方槽)。
 * 盘比槽小 [MINI_BALL_DIAM] 那点余量是留给"呼吸"的,撑得太满会读成"一个洞"而不是"一颗球"。
 */
val MINI_BALL_SLOT = MINI_H_COLLAPSED

/** 圆盘直径(槽 56 留上下各 4dp)。 */
val MINI_BALL_DIAM = 48.dp

/**
 * 球槽与胶囊之间的**外缝**。
 *
 * ⚠️ 只能挂在槽的右边距上、并且**按收束态插值**,不能写成外层 `Row({ space })` 那种统一间距:
 * 展开态槽宽是 0,统一间距会让整条播放条白右移 8dp,封面左缘就和列表文字对不齐。
 */
val MINI_BALL_GAP = 8.dp

/** 盘上图标:玻璃栏的 tab 图标实测 19dp([GlassNavBar] 里那枚 `size(19.dp)`),同档取 20。 */
val MINI_BALL_SYMBOL = 20.dp

/**
 * 盘面透明度:中性 `onSurface` 半透明,**不跟强调色**。
 *
 * 与鸿蒙第六轮同一个结论:强调色半透明的盘在深色底上泛一层绿,和盘上图标同色之后
 * 读成"一个实心圆点",参考片那种"整条栏收在这里"的透镜感就没了。
 * 也不要改成完全不透明 `surface` —— 那等于自己画一块板,正是这一轮要撤掉的"两层容器"形状。
 */
const val MINI_BALL_TINT = 0.45f

/**
 * 滚动累计多少 dp 翻转收束/展开。**与鸿蒙 [MORPH_SLOPE] 同档**(40vp ≈ 手指 13mm)。
 *
 * 判据用**累计量**而不是单帧量:惯性滑动里一帧只有 1–8px,按单帧判阈值要么一碰就翻、
 * 要么永远不翻。每次翻转后清零。
 */
val MINI_MORPH_SLOPE = 40.dp

/**
 * morph 弹簧参数。鸿蒙给的是 response 0.34s / damping 0.86;
 * Compose 没有 response 这一档,按 `stiffness = (2π / response)²` 换算 ≈ 341
 * (仓库里已有的先例是 response 0.42 ⇒ 224,同一式子)。
 * ⚠️ 播放条的几何动画与栏的淡出动画**必须共用这一档**,否则两条曲线不同步会看出"散架"。
 * ⚠️ **0.86 是欠阻尼:落点会有 ≈0.5% 的过冲,分数会短暂越过 1 和 0。**
 * 这个量一旦乘进 `padding` / `size` 就是负 Dp,Compose 直接抛
 * `Padding must be non-negative`(装机即崩,见 H180)⇒ 几何侧一律先 `coerceIn(0f, 1f)` 再用。
 */
const val MINI_MORPH_DAMP = 0.86f
const val MINI_MORPH_STIFFNESS = 341f

/**
 * 底部迷你播放条 —— **胶囊形态 + 随滚动收进栏那一行**(2026-10-15 向鸿蒙对齐)。
 *
 * ## 与旧版的差别
 *
 * 旧版是 `fillMaxWidth()` 的通栏 `Surface(surfaceVariant)` + 顶部一条占布局的进度线,
 * 实际高 ≈66dp,永远坐在栏下方。这一轮按用户要求改成鸿蒙那套:
 * 椭圆胶囊、左右与栏同一道缝([MINI_SIDE_PAD])、与栏之间 8dp([MINI_GAP])、
 * 上下滑动时整块收进栏那一行并把栏淡掉、左端露出一颗当前格的小圆球作为展开入口。
 * **唯一保留本端特色的是底部玻璃栏的跟手光晕/透镜**(不动 [GlassNavBar] 的几何,
 * 只是给它一个 `collapsed` 去淡出)。
 *
 * ## 为什么所有几何都从一个浮点 `f` 派生
 *
 * 两态之间要同时动:块高、球槽宽、外缝、右内边距、整块落点、栏的透明度、三项的淡出。
 * 逐个属性各挂一条动画就有六条曲线要同步;而 `animateFloatAsState(f)` 一条曲线,
 * 每个量写成 `start + (end - start) * f` 的 Dp 算式,天然同相位。
 * ⚠️ **封面的边长不在这一套里**(见 [MINI_COVER_WIDE] 那条 ⚠️),它是 `if (collapsed)` 瞬变。
 *
 * ## 收束态三个 tab 点不动,是这一形态的必然
 *
 * 那一行只剩胶囊与那颗球(栏淡到 0)。鸿蒙那边同一结论,已按"就是设计"结案 ——
 * 想切格先点球展开。本端的 [GlassNavBar] 即使在 alpha=0 时**仍然消费指针事件**
 * (手势回调里是门控而不是提前 return),所以点击不会漏到底下列表。
 *
 * @param collapsed 是否收束进栏那一行(由外层滚动判据驱动,见 `ReverbRoot.MainShell`)。
 * @param ballIcon  当前那一格的图标(与栏的 `GlassTabSpec.icon` 同源同一枚);传 null 就不画球槽
 *                  —— 频道详情/队列那两处全屏页要传 null,它们的播放条不参与收束。
 * @param onRestore 点球:把播放条展开回栏上方,**不改当前 tab**(盘上是当前那一格,点它不切页)。
 * @param collapseIntoBar 这一份**是否叠在玻璃栏之上**(只有 tab 外壳是)。为 true 时整块要按
 *                  展开态往上抬出栏的那条带([GLASS_BAR_H] + [MINI_GAP]);为 false 的是详情/队列
 *                  那种"播放条自己贴底"的全屏页,抬了就是凭空多出一条 60dp 的空隙。
 *                  ⚠️ 这一道抬升**必须写在组件内部、由同一条 `f` 派生**:若在 `MainShell` 里
 *                  按值取一个动画分数传进来,那个 State 会被外壳解包 ⇒ 动画途中**每一帧重排
 *                  整棵外壳**(三张满屏列表),而外壳里根本没有需要逐帧变的量(硬规矩 6/7)。
 * @param coverOpensChannel 封面点击是否跳频道页。**频道详情页传 false**(判据见 [coverChannelJump]):
 *                  在那里点自己这档的头像等于往栈上再压一份同一个页面。
 */
@Composable
fun MiniPlayer(
    episode: Episode,
    isPlaying: Boolean,
    buffering: Boolean,
    progress: Float,
    hasNext: Boolean,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onExpand: () -> Unit,
    /// 关闭播放条(最右那枚 X):停止播放并清掉「正在播」上下文,整条塌陷消失。
    /// 语义见 [com.yuyin.reverb.playback.PlayerController.close]。
    onClose: () -> Unit = {},
    onOpenQueue: () -> Unit = {},
    collapsed: Boolean = false,
    ballIcon: ImageVector? = null,
    onRestore: () -> Unit = {},
    collapseIntoBar: Boolean = false,
    coverOpensChannel: Boolean = true
) {
    val f by animateFloatAsState(
        targetValue = if (collapsed) 1f else 0f,
        animationSpec = spring(dampingRatio = MINI_MORPH_DAMP, stiffness = MINI_MORPH_STIFFNESS),
        label = "miniMorph"
    )
    val scheme = MaterialTheme.colorScheme
    // ⚠️ **几何一律读钳过的 `fc`,不读 `f`**(2026-10-16 装机即崩,见 H180)。
    // [MINI_MORPH_DAMP]=0.86 是**欠阻尼**,弹簧落到终点会过冲 ≈0.5%(f 短暂 >1 / <0)。
    // 而下面这些量是**喂给 padding 的 Dp**:`lift = 60dp × (1 - f)`,f=1.005 就是 -0.3dp;
    // `padding(end = 8dp × f)`,恢复态 f=-0.005 就是 -0.04dp。Compose 对负 padding 直接抛
    // `IllegalArgumentException: Padding must be non-negative`,而且是**每次收束必崩**
    // (过冲只有 0.3%,眼睛看不出来,所以现场表现是"一划就闪退、屏上什么都没变")。
    // 钳在这里而不是逐个量各写一次 coerce:与硬规矩 10 同一条 —— 不变式在出口一次性保证。
    // 弹簧本身不动:0.5% 的过冲正是那点"呼吸感",看不见但摸得到;要的是别让几何吃下它。
    val fc = f.coerceIn(0f, 1f)
    val blockH = MINI_H + (MINI_H_COLLAPSED - MINI_H) * fc
    // 球槽宽 = (槽 + 外缝) 按收束态插值。展开态归零,但**不能用 if 把球摘掉** ——
    // 摘掉会让整行内容一次性左移,而封面/文字正按弹簧滑过来,两种运动叠在一起就是"抖"。
    val slotW = (MINI_BALL_SLOT + MINI_BALL_GAP) * fc
    val cover = if (collapsed) MINI_COVER_NARROW else MINI_COVER_WIDE
    val coverCorner = if (collapsed) (cover / 2).dp else 8.dp
    // 封面的第二重语义:点它进频道页(整块仍是展开播放页)。判据与列表行同一条,
    // 在频道详情页由调用方关掉(见 [coverChannelJump] 的第三条门)。
    val coverJump = coverChannelJump(episode, coverOpensChannel)
    val openChannelLabel = stringResource(R.string.a11y_open_channel)
    val endPad = MINI_PAD_END + (MINI_PAD_END_COLLAPSED - MINI_PAD_END) * fc
    // 收束态按钮排「收紧」:间距与命中框一起随 fc 插值(理由见 MINI_BTN_GAP_COLLAPSED 注释)。
    val btnGap = MINI_BTN_GAP + (MINI_BTN_GAP_COLLAPSED - MINI_BTN_GAP) * fc
    val btnHit = MINI_HIT + (MINI_HIT_COLLAPSED - MINI_HIT) * fc
    // 落点:展开态抬到栏上方再留一道缝,收束态落进栏那一条带里(与 [blockH] 同源同一条曲线)。
    val lift = if (collapseIntoBar) (GLASS_BAR_H + MINI_GAP) * (1f - fc) else 0.dp

    Box(
        // ⚠️ 这里**没有** `modifier` 形参,是有意的:整块的落点(在叠层里贴哪一边)
        // 必须由调用方的外层容器决定。曾经给它传过 `align(BottomCenter)`,而中间隔着
        // `AnimatedVisibility`(它自己包一层 Box)⇒ align 被那层吃掉、整块退化成顶对齐,
        // `lift` 只是把容器撑高、**播放条从来不落下**(见 H181)。
        Modifier
            .fillMaxWidth()
            .padding(horizontal = MINI_SIDE_PAD)
            .padding(bottom = lift)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (ballIcon != null) {
                Box(
                    Modifier
                        .size(width = slotW, height = blockH)
                        // 宽 0 时盘不会自动被裁掉,必须显式裁到边界(裁的是矩形,不是圆角)
                        .clipToBounds()
                        .padding(end = MINI_BALL_GAP * fc),
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        Modifier
                            .size(MINI_BALL_DIAM)
                            .clip(CircleShape)
                            .background(scheme.onSurface.copy(alpha = MINI_BALL_TINT))
                            .clickable(enabled = collapsed, onClick = onRestore),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            ballIcon,
                            contentDescription = if (collapsed)
                                stringResource(R.string.a11y_expand_player) else null,
                            tint = scheme.primary,
                            modifier = Modifier.size(MINI_BALL_SYMBOL)
                        )
                    }
                }
            }
            Box(
                Modifier
                    .weight(1f)
                    .height(blockH)
                    .clip(CircleShape)
                    // 不透明实底:收束态底下就是列表内容,半透明会让胶囊和文字一起糊掉
                    // (鸿蒙那边靠系统材质做到"随背后内容动",本端没有等价物,先按不透明保底)。
                    .background(scheme.surface),
                // 内容**垂直居中**在胶囊里(与那颗盘同心)。这一层若按默认的 TopStart 摆,
                // 56 高的块里 40 高的内容会顶在上沿、盘却在中间,两者差 8dp 一眼可见。
                contentAlignment = Alignment.Center
            ) {
                // 进度线改成**覆盖层**,压在胶囊上沿,不再占行的高度(显式 align,不吃上面那个居中)。
                // 旧口径 2 + (8 + 44 + 8) 那 2dp 会把封面居中的位置挤掉,两态 padding 只能不等;
                // 去掉之后两态都对称,球槽也才放得进栏高那一档。
                LinearProgressIndicator(
                    progress = { progress.coerceIn(0f, 1f) },
                    modifier = Modifier.align(Alignment.TopStart).fillMaxWidth().height(2.dp),
                    color = scheme.primary,
                    trackColor = scheme.onSurfaceVariant.copy(alpha = 0.18f)
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = MINI_PAD_START, end = endPad),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(btnGap)
                ) {
                    Row(
                        Modifier
                            .weight(1f)
                            .clickable(onClick = onExpand),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        // ⚠️ 覆盖层必须写在**包住 Artwork 的 Box 里并用 matchParentSize**:
                        // 把它做成 Row 的兄弟节点会多占一格 spacedBy(10dp) 的位置(第一版就是这么写的),
                        // 而 matchParentSize 不参与父测量 —— 胶囊里的排布一格都不动。
                        // Main 遍子节点先于父节点并消费按下 ⇒ 点头像只进频道、不展开播放页。
                        Box {
                            Artwork(episode.artworkUrl, size = cover, corner = if (collapsed) cover / 2 else 8)
                            if (coverJump != null) {
                                Box(
                                    Modifier
                                        .matchParentSize()
                                        .clip(RoundedCornerShape(coverCorner))
                                        .clickable(onClick = coverJump)
                                        .semantics { contentDescription = openChannelLabel }
                                )
                            }
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                episode.title,
                                style = MaterialTheme.typography.bodyMedium,
                                color = scheme.onBackground,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                episode.podcastTitle,
                                style = MaterialTheme.typography.labelSmall,
                                color = scheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                    // 三枚相邻不留缝(理由见 [MINI_HIT])
                    Box(
                        Modifier.size(btnHit).clip(CircleShape).clickable(onClick = onToggle),
                        contentAlignment = Alignment.Center
                    ) {
                        if (buffering) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                strokeWidth = 2.dp,
                                color = scheme.primary
                            )
                        } else {
                            Icon(
                                if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                contentDescription = stringResource(
                                    if (isPlaying) R.string.a11y_pause else R.string.a11y_play
                                ),
                                tint = scheme.primary,
                                modifier = Modifier.size(MINI_SYMBOL)
                            )
                        }
                    }
                    Box(
                        Modifier
                            .size(btnHit)
                            .clip(CircleShape)
                            .clickable(enabled = hasNext, onClick = onNext),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Rounded.SkipNext,
                            contentDescription = stringResource(R.string.a11y_next),
                            tint = if (hasNext) scheme.primary else scheme.onSurfaceVariant.copy(alpha = 0.4f),
                            modifier = Modifier.size(MINI_SYMBOL)
                        )
                    }
                    // 队列入口:位次与 macOS 底部条/鸿蒙迷你条一致 —— 都在最右
                    Box(
                        Modifier.size(btnHit).clip(CircleShape).clickable(onClick = onOpenQueue),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.AutoMirrored.Rounded.QueueMusic,
                            contentDescription = stringResource(R.string.queue_title),
                            tint = scheme.onBackground,
                            modifier = Modifier.size(MINI_SYMBOL)
                        )
                    }
                    // 关闭(参考视频的位次:X 在播放条最右端,队列入口之外再一格)。
                    // 色阶用 onSurfaceVariant 而不是 onBackground:它是这一行的次要动作,
                    // 亮度和标题副行同档,不与播放键(主色)争视觉权重。
                    Box(
                        Modifier.size(btnHit).clip(CircleShape).clickable(onClick = onClose),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Rounded.Close,
                            contentDescription = stringResource(R.string.a11y_close_player),
                            tint = scheme.onSurfaceVariant,
                            modifier = Modifier.size(MINI_SYMBOL)
                        )
                    }
                }
            }
        }
    }
}
