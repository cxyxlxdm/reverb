package com.yuyin.reverb.ui.components

import android.widget.Toast
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.FormatListBulleted
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RepeatOne
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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
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
 * 全项目三处 chip 都走这里:音阁分段、发现页分类(仅完整版渠道)、搜索结果的节目/单集分段。
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
    showPodcastTitle: Boolean = false, // 搜索结果里同列多个不同播客的单集，需标出所属频道
    isFavorite: Boolean = false,
    onToggleFavorite: (() -> Unit)? = null,
    played: Boolean = false,            // 已播完:标题变暗 + 打勾
    onTogglePlayed: (() -> Unit)? = null, // 长按菜单:标记已播完/未播完
    onPlayNext: (() -> Unit)? = null,     // 长按菜单:下一个播放
    onEnqueue: (() -> Unit)? = null,      // 长按菜单:加入队列;showQueueAdd 时也是行内键的动作
    /// 行内「加入播放列表」键,只在节目详情页开(对齐鸿蒙):浏览选集为主的场景,
    /// 一步入队比长按菜单顺手。Compose 里子 IconButton 消费点击,行 ripple 不会连带亮起
    /// —— 鸿蒙那边要靠 stopPropagation 手工截断的问题,这边的系统行为本来就是对的。
    showQueueAdd: Boolean = false
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
    val hasMenu = onTogglePlayed != null || onPlayNext != null || onEnqueue != null
    val rowModifier = Modifier
        .fillMaxWidth()
        .then(
            if (hasMenu) Modifier
                // Initial 阶段只「偷看」按下位置,不消费事件 —— 否则会和 combinedClickable
                // 抢同一个指针,点击/长按都会失效。
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        pressPoint = down.position
                    }
                }
                .combinedClickable(onClick = onPlay, onLongClick = { menuOpen = true })
            else Modifier.clickable(onClick = onPlay)
        )
        .padding(horizontal = 16.dp, vertical = 12.dp)
    Box {
    Row(
        modifier = rowModifier,
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 封面缩略图 + 播放/暂停轻蒙层:更有色彩,并保留播放态与播放入口(整行可点)
        Box(Modifier.size(52.dp), contentAlignment = Alignment.Center) {
            Artwork(episode.artworkUrl, size = 52, corner = 10)
            Box(
                Modifier
                    .matchParentSize()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Color.Black.copy(alpha = if (isCurrent) 0.42f else 0.28f))
            )
            Icon(
                if (isCurrent && isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = stringResource(if (isPlaying && isCurrent) R.string.a11y_pause else R.string.a11y_play),
                tint = Color.White,
                modifier = Modifier.size(24.dp)
            )
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
                    Text(
                        shown,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1
                    )
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
        if (onToggleFavorite != null) {
            IconButton(onClick = onToggleFavorite) {
                Icon(
                    if (isFavorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                    contentDescription = stringResource(if (isFavorite) R.string.a11y_unfavorite else R.string.a11y_favorite),
                    tint = if (isFavorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        if (showQueueAdd && onEnqueue != null) {
            // 与鸿蒙同位次(收藏心形之后、下载控件之前);图标用 PlaylistAdd(列表+加号),
            // 不用 QueueMusic —— 那是「打开队列页」的入口,同形不同义会误导(鸿蒙真机反馈)。
            IconButton(onClick = {
                onEnqueue()
                // 入队结果在别页,界面无任何变化,不提示等于没按上
                Toast.makeText(context, R.string.queue_added, Toast.LENGTH_SHORT).show()
            }) {
                Icon(
                    Icons.AutoMirrored.Rounded.PlaylistAdd,
                    contentDescription = stringResource(R.string.queue_add),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        if (onDownload != null || onDeleteDownload != null) {
            DownloadControl(downloadStatus, onDownload, onDeleteDownload)
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
                if (onTogglePlayed != null) {
                    DropdownMenuItem(
                        text = { Text(stringResource(if (played) R.string.mark_unplayed else R.string.mark_played)) },
                        onClick = { menuOpen = false; onTogglePlayed() }
                    )
                }
            }
            }
        }
    }
}

@Composable
private fun DownloadControl(
    status: DownloadStatus?,
    onDownload: (() -> Unit)?,
    onDelete: (() -> Unit)?
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
        else -> IconButton(onClick = { onDownload?.invoke() }) {
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
    onOpenQueue: () -> Unit = {}
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column {
            LinearProgressIndicator(
                progress = { progress.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(2.dp),
                color = MaterialTheme.colorScheme.primary,
                trackColor = Color.Transparent
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onExpand)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Artwork(episode.artworkUrl, size = 44, corner = 8)
                Column(Modifier.weight(1f)) {
                    Text(
                        episode.title,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onBackground,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        episode.podcastTitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                if (buffering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.primary
                    )
                } else {
                    IconButton(onClick = onToggle) {
                        Icon(
                            if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary
                        )
                    }
                }
                IconButton(onClick = onNext, enabled = hasNext) {
                    Icon(
                        Icons.Rounded.SkipNext,
                        contentDescription = stringResource(R.string.a11y_next),
                        tint = if (hasNext) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                    )
                }
                // 队列入口:位次与 macOS 底部条/鸿蒙迷你条一致 —— 都在最右
                IconButton(onClick = onOpenQueue) {
                    Icon(
                        Icons.AutoMirrored.Rounded.QueueMusic,
                        contentDescription = stringResource(R.string.queue_title),
                        tint = MaterialTheme.colorScheme.onBackground
                    )
                }
            }
        }
    }
}
