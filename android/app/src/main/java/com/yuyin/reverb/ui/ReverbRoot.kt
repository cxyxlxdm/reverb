package com.yuyin.reverb.ui

import android.Manifest
import android.net.Uri
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.RssFeed
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.yuyin.reverb.R
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.GLASS_BAR_H
import com.yuyin.reverb.ui.components.GlassNavBar
import com.yuyin.reverb.ui.components.GlassTabSpec
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.LocalOpenPodcastChannel
import com.yuyin.reverb.ui.components.MINI_GAP
import com.yuyin.reverb.ui.components.MINI_H
import com.yuyin.reverb.ui.components.MINI_MORPH_SLOPE
import com.yuyin.reverb.ui.components.MiniPlayer
import com.yuyin.reverb.ui.screens.AboutScreen
import com.yuyin.reverb.ui.screens.DiscoverScreen
import com.yuyin.reverb.ui.screens.FeedScreen
import com.yuyin.reverb.ui.screens.LibraryScreen
import com.yuyin.reverb.ui.screens.LicensesScreen
import com.yuyin.reverb.ui.screens.ListenStatsScreen
import com.yuyin.reverb.ui.screens.PlayerScreen
import com.yuyin.reverb.ui.screens.PodcastDetailScreen
import com.yuyin.reverb.ui.screens.QueueScreen
import com.yuyin.reverb.ui.screens.SettingsScreen
import com.yuyin.reverb.ui.screens.StampsScreen

/**
 * 外层导航：全屏页面（tab 外壳 / 播放器 / 设置 / 关于 / 开源）互不共享底部栏，
 * 跳转这些页面时整个 tab 外壳作为一个整体转场，不存在底部栏占位变化 → 无上下闪动。
 */
@Composable
fun ReverbRoot(openPlayerSignal: Int = 0) {
    val rootNav = rememberNavController()

    // 这里**不再**申请通知权限。原先是一进来就无条件弹,与隐私政策写明的
    // 「仅在你主动开启『订阅更新提醒』时征求你的同意」不符,也属于"启动即申请非必要权限"。
    // 改到设置页那个开关里申请(与「真实频谱」同一范式:授权成功才落地开关)。

    // 通知栏点击进来（openPlayerSignal 自增）时打开播放页
    LaunchedEffect(openPlayerSignal) {
        if (openPlayerSignal > 0 && PlayerController.current.value != null) {
            rootNav.navigate("player") { launchSingleTop = true }
        }
    }

    // 「点封面/头像进频道页」的入口:在 NavHost 外层提供一次,列表行、待播那一行、
    // 迷你播放条各自按 `episode.feedUrl` 判可点不可点(见 Components.kt coverChannelJump)。
    // ⚠️ 必须 `remember`:这条 lambda 每次重组新建的话,所有读它的列表都会跟着失效重排,
    // 而它抓的 rootNav 本来就是稳定的(rememberNavController)。
    val openPodcastChannel: (String) -> Unit = remember(rootNav) {
        { feed -> rootNav.navigate("podcast/${Uri.encode(feed)}") }
    }

    CompositionLocalProvider(LocalOpenPodcastChannel provides openPodcastChannel) {
    NavHost(navController = rootNav, startDestination = "main") {
        composable("main") { MainShell(rootNav) }
        // 频道详情作为全屏页(与播放页/设置同级),整体转场,避免进详情时底部栏收起导致的上下闪动;
        // 仍在底部保留迷你播放条,不显示 tab。
        composable("podcast/{feed}") { entry ->
            val feed = entry.arguments?.getString("feed").orEmpty()
            FloatingMini(
                onExpand = { rootNav.navigate("player") },
                onOpenQueue = { rootNav.navigate("queue") },
                // 已经在这档的页面里:播放条封面再点就是往栈上压一份同一个页面
                miniCoverOpensChannel = false
            ) {
                PodcastDetailScreen(feedUrl = feed, onBack = { rootNav.popBackStack() })
            }
        }
        composable("player") {
            FullScreen {
                PlayerScreen(
                    onBack = { rootNav.popBackStack() },
                    onOpenChannel = { feed -> rootNav.navigate("podcast/${Uri.encode(feed)}") },
                    onOpenQueue = { rootNav.navigate("queue") }
                )
            }
        }
        composable("queue") {
            FloatingMini(onExpand = { rootNav.navigate("player") }, onOpenQueue = {}) {
                // 已在队列页:入口键不再响应,避免向同一路由重复压栈
                QueueScreen(onBack = { rootNav.popBackStack() })
            }
        }
        composable("settings") {
            FullScreen {
                SettingsScreen(
                    onBack = { rootNav.popBackStack() },
                    onOpenAbout = { rootNav.navigate("about") },
                    onOpenLicenses = { rootNav.navigate("licenses") },
                    onOpenFootprint = { rootNav.navigate("footprint") }
                )
            }
        }
        composable("footprint") { FullScreen { StampsScreen(onBack = { rootNav.popBackStack() }) } }
        composable("listen_stats") { FullScreen { ListenStatsScreen(onBack = { rootNav.popBackStack() }) } }
        composable("about") { FullScreen { AboutScreen(onBack = { rootNav.popBackStack() }) } }
        composable("licenses") { FullScreen { LicensesScreen(onBack = { rootNav.popBackStack() }) } }
    }
    }
}

/** 外层全屏页无 Scaffold，需自行铺主题背景并避开系统状态栏/导航栏。 */
@Composable
private fun FullScreen(content: @Composable () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        Box(Modifier.fillMaxSize().systemBarsPadding()) {
            content()
        }
    }
}

/** 带底部栏的 tab 外壳：三个顶层 tab 常驻叠层(不走导航栈),详情 / 播放 / 设置由外层承载。 */
@Composable
private fun MainShell(rootNav: NavHostController) {
    /**
     * 三个顶层 tab **不走导航栈**,叠在同一个 Box 里用 [tabKept] 切换。
     *
     * 为什么(2026-09-28,Pixel 3 实测):「换 tab 卡」这条被报了**三次**,前两次都当成
     * "切换时多画了一段东西"——第一次怀疑玻璃栏逐帧读 size,第二次抓到 NavHost 缺省的
     * 700ms 交叉淡入并关掉(见 H108),用户当时说"不卡了",之后又回来了。
     * 这次先做**不含被怀疑动作的对照**,同一台机同一种量法(Choreographer 掉帧行数):
     *
     * ```
     * 音阁内换分段 / 发现内换分类      Skipped = 0
     * 点已选中的那颗 tab(只按不换)   Skipped = 0,整次交互只出 1 帧
     * 发现 → 音阁(目的地重建)        Skipped = 31 ≈ 517 ms  ← 卡顿就在这一下
     * ```
     *
     * 于是成本既不在转场、也不在底部栏、也不在分段内容,而在**切走的那一页被整个 dispose**:
     * NavHost 只组合当前 entry,切回来要从零 compose,而且进页的刷新会重跑
     * (logcat 里每次切回发现都重发一次 `Charts.topByGenre`,切进音阁重发一次
     * `InboxStore.refresh`)。叠层之后每页只在**第一次被选中**时建一次(`seen*` 那笔账见下面注释),
     * 之后切换只是翻一个整数。**加第三格时必须继续走这套**(见 H108),不能退回 NavHost。
     */
    val tabs = listOf(
        GlassTabSpec(stringResource(R.string.nav_discover), Icons.Rounded.Explore),
        GlassTabSpec(stringResource(R.string.nav_feed), Icons.Rounded.RssFeed),
        GlassTabSpec(stringResource(R.string.nav_library), Icons.Rounded.LibraryMusic)
    )
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    /// 追更 / 音阁各建过没有。**懒**建它们的理由分两条:
    /// ① 冷启动不该为一个没打开的页面付 compose 的钱;
    /// ② **进了那一页才会发它自己的那笔请求** —— 追更一建就触发 `InboxBody` 的进页刷新
    ///    (合并所有订阅拉最新单集,可能十几个源),音阁一建会读六段的数据。
    ///    这条从 2 格变 3 格之后更重要:原先「进音阁顺带刷最新」是因为两者在同一棵子里,
    ///    现在拆开了,刷新只跟着追更那一格走。
    /// 首建之后一直留着 —— 留着才是要解决的问题(见上面那段差分)。
    var seenFeed by rememberSaveable { mutableStateOf(false) }
    var seenLibrary by rememberSaveable { mutableStateOf(false) }

    fun select(i: Int) {
        if (i == 1) seenFeed = true
        if (i == 2) seenLibrary = true
        selectedTab = i
    }

    // 系统返回的语义与内层 NavHost 时代一致:不在首页先回首页,已在首页才交给系统退出。
    // (以前这条路由内层回退栈天然提供,拆掉栈之后必须显式接回来。)
    BackHandler(enabled = selectedTab != 0) { select(0) }

    /**
     * 底部悬浮玻璃栏(与鸿蒙 GlassTabBar 同款,装机验收基准)。原来是一块贴底的
     * Material NavigationBar —— 玻璃要"浮"起来,内容必须能从栏下滚过,所以整块
     * 改成叠层:NavHost 铺满,列表用 [LocalGlassBottomPad] 让出底部余量,
     * 栏与迷你播放条悬浮在内容之上。
     */
    var overlayPx by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    val bottomPad = remember(overlayPx) { with(density) { overlayPx.toFloat().toDp() } + 8.dp }

    /**
     * 播放条是否**收进栏那一条带**(鸿蒙同款:往下滚收起、往上滚展开)。
     *
     * 用 `MutableState` 而不是 `by` 的写法,是为了让这个值能被下面那个 `object` 表达式
     * 直接读写 —— Kotlin 的**局部委托属性不能被闭包捕获**,写成 `var collapsed by ...`
     * 在这条连接里根本读不到。
     */
    val currentEpisode by PlayerController.current.collectAsStateWithLifecycle()
    val playing = currentEpisode != null
    val collapsed = rememberSaveable { mutableStateOf(false) }
    val morphThresholdPx = with(density) { MINI_MORPH_SLOPE.toPx() }

    /**
     * 滚动累计器(鸿蒙那边是 `Index.feedScroll`,同一套判据)。
     *
     * 为什么挂 [NestedScrollConnection] 而不是去改各页的 `scrollState`:全仓**没有任何一处
     * 把列表的滚动状态提升到外壳**(实测测绘过),而三张页各有一个 `LazyColumn`,
     * 要提升得改三处并把状态穿透进各页 body。这一层是**父级连接**,子页的 `LazyColumn`
     * 自己会往上报 post-scroll,不用它们知道这件事 —— 零侵入。
     *
     * 判据用**累计量**而不是单帧量:惯性滑动一帧只有 1–8px,按单帧判阈值要么一碰就翻、
     * 要么永远不翻。每次翻转后清零,所以"往回滚 40dp"要重新攒满,不会在临界点来回抖。
     *
     * ⚠️ 只认 [NestedScrollSource.Drag] 与 [NestedScrollSource.Fling] —— 这两个只能由手指产生
     * (Fling 是抬手后的惯性,仍然是那一下拖的延续)。**不要**用 `isScrollInProgress` /
     * `onScroll` 之类程序化滚动也会触发的信号,那会把"进页自动滚到某处"算成用户意图(硬规矩 9)。
     *
     * ⚠️ 这个回调**每帧都跑**,所以里面只许有加减法和一次布尔比较(硬规矩 6)。
     * 累加器用 [FloatArray] 而不是 `mutableFloatStateOf`:它只是判据的中间量,
     * **不该触发任何重 compose** —— 真正被改的状态只有 `collapsed`,而它只让栏的透明度、
     * 播放条的五个几何量(都在 [MiniPlayer] 内部由同一条弹簧派生)重算。
     * 让位量按展开态恒定、与收没收束无关(见下面那个 `Box` 的高度),所以翻转**不会**重排列表 ——
     * 这一条与鸿蒙 `barReserve` 同一个理由:省下的那点空白换一次滚动掉帧,不值。
     *
     * ⚠️ `onPostScroll` 的第二个参数在**本端 Compose 1.6.x 是 `Offset`**(1.7 起才换成
     * `NestedScrollParams`)。这里只用 `consumed`,升级 Compose 时这一处签名要跟着改,
     * 否则会像第一次写那样直接编不过(而不是行为变了)。
     *
     * ⚠️ **`consumed.y` 的符号与直觉相反:手指向上划(内容向后翻)报负值**,
     * 所以回调里第一件事是 `-consumed.y`。漏掉这一步不会崩、不会报错,
     * 只会让两个分支各管反一支 —— 在列表顶部的设备上净效果是"永远不收束"
     * (装机划了 24 次播放条纹丝不动,见 H180 补记)。**判据只能靠 dump 里播放条的
     * bounds 真的下移了 165px(60dp)来确认,不能靠"日志里有滚动"。**
     */
    val morphAcc = remember { FloatArray(1) }
    val morphConnection = remember(morphThresholdPx, playing) {
        object : NestedScrollConnection {
            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource
            ): Offset {
                if (!playing) return Offset.Zero
                if (source != NestedScrollSource.Drag && source != NestedScrollSource.Fling) {
                    return Offset.Zero
                }
                // ⚠️ **符号换算写在出口处**:Compose 的 `consumed.y` 与直觉相反 ——
                // 手指**向上**划(内容往后翻、要收束的那一支)报的是**负**值。
                // 这里先取反成"向前为正"的 dragged,再累计;否则两个分支各管反一支,
                // 上滑命中"展开"、下滑命中"收束",在列表顶部的设备上净效果是**永远不收束**
                // (装机实测:划了 24 次播放条纹丝不动,探针打出 consumed=-122,见 H181)。
                val dragged = -consumed.y
                morphAcc[0] += dragged
                if (morphAcc[0] >= morphThresholdPx) {
                    morphAcc[0] = 0f
                    if (!collapsed.value) collapsed.value = true
                } else if (morphAcc[0] <= -morphThresholdPx) {
                    morphAcc[0] = 0f
                    if (collapsed.value) collapsed.value = false
                }
                return Offset.Zero
            }
        }
    }

    // 停止播放(队列清空 / 播完)时收起状态必须跟着复位,否则下次起播第一帧就是收束态、
    // 三个 tab 点不动,看起来像"栏坏了"。
    LaunchedEffect(playing) {
        if (!playing) {
            collapsed.value = false
            morphAcc[0] = 0f
        }
    }

    // 状态栏让位:App 是 edge-to-edge 的(setDecorFitsSystemWindows=false),tab 外壳
    // 不让位的话 ScreenHeader 的顶距直接顶进状态栏。**background 必须在
    // statusBarsPadding 之前** —— 反过来背景只铺到状态栏以下,通知栏区域露黑底,
    // 沉浸式就没了(第一版修法犯过)。只垫 status bar,底部由悬浮栏自带的
    // navigationBarsPadding 管。
    Box(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .nestedScroll(morphConnection)
    ) {
        CompositionLocalProvider(LocalGlassBottomPad provides bottomPad) {
            // 三页叠在一起,谁可见由 selectedTab 决定。**不要用 if 把它们互斥包起来** ——
            // 那就退回"切走即销毁"的老问题(见 MainShell 上面那段差分)。
            // [tabKept] 的语义是"照样测量与布局,但不画、不进无障碍树";
            // 隐藏页因此一直占好尺寸,切回来第一帧就是对的。
            // 组合顺序按底部栏的格序排(发现 → 追更 → 音阁),这样页号与代码位置对得上。
            Box(
                Modifier
                    .fillMaxSize()
                    .zIndex(if (selectedTab == 0) Z_VISIBLE else Z_HIDDEN)
                    .tabKept(selectedTab != 0)
            ) {
                DiscoverScreen(onOpen = { p -> rootNav.navigate("podcast/${Uri.encode(p.feedUrl)}") })
            }
            if (seenFeed) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .zIndex(if (selectedTab == 1) Z_VISIBLE else Z_HIDDEN)
                        .tabKept(selectedTab != 1)
                ) {
                    FeedScreen()
                }
            }
            if (seenLibrary) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .zIndex(if (selectedTab == 2) Z_VISIBLE else Z_HIDDEN)
                        .tabKept(selectedTab != 2)
                ) {
                    LibraryScreen(
                        onOpen = { p -> rootNav.navigate("podcast/${Uri.encode(p.feedUrl)}") },
                        onOpenSettings = { rootNav.navigate("settings") },
                        onOpenListenStats = { rootNav.navigate("listen_stats") }
                    )
                }
            }
            // **吸收层**:夹在所有内容页之上、底部栏之下(命中顺序 可见页 [Z_VISIBLE] → 吸收层 [Z_SHIELD] → 隐藏页 [Z_HIDDEN])。
            // 隐藏页现在有两张(追更 / 音阁),它们都在 Z_HIDDEN 同一档,而吸收层排在**全部**内容页之后,
            // 所以这一层照样挡得住两张 —— 不需要按页各摆一颗。
            //
            // 为什么必须有这一层(2026-09-28,Pixel 3 实测):整层摘掉之后,在「发现」的真空白处
            // 点一下 —— 坐标正好压在隐藏那页的「下载 / 收藏」chip 上 —— 切回音阁**分段真的被改了**。
            // 可见页不是整屏都可点的:行距、间距、留白处的手势不会被它消费,于是整段漏到下面那页,
            // 表现就是"切回来发现刚才那页自己换了分段 / 滚走了"。
            //
            // 为什么夹在中间,而不是把吞事件的 pointerInput 直接挂到隐藏页上:
            // Initial 遍先于 Main 遍走完所有节点,隐藏页若在 Initial 里 consume,
            // 可见页在 Main 里的 `awaitFirstDown()`(默认要求未消费)就拿不到这一下。
            // ⚠️ 这一句是**推断,没实测**(没有再装一版"挂隐藏页"的去对照)。
            // 实测过的是当前这一版:可见页的滚动、点击进详情、系统返回全部照常
            // (消费只挡住"同一事件里排在后面的节点",不会追认到下一个事件,所以挡不住上层的正常识别)。
            Box(
                Modifier
                    .fillMaxSize()
                    .zIndex(Z_SHIELD)
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            do {
                                awaitPointerEvent().changes.forEach { it.consume() }
                            } while (currentEvent.changes.any { it.pressed })
                        }
                    }
            )
        }
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                // 见 [Z_BAR]:两页带上显式 zIndex 之后,栏必须也跟着显式压在上面。
                // 不是保险 —— 摘掉这一行装机实测:栏的两个标签从 `uiautomator dump` 里消失、
                // 点 (746,1945) 完全不换页(8 轮落点全 X),截屏底部也没有栏的像素。
                .zIndex(Z_BAR)
                .fillMaxWidth()
                // 底部留白 = **整个**手势区。鸿蒙同一处是 0.62 倍(`INSET_KEEP`),
                // 那个数是"栏底到小白条 = 小白条到屏底"这条规则在那台机上的解;
                // 本机量出来整个 inset 已经比目标紧一点(5.4dp vs 7.1dp),照抄会把栏底压到小白条上沿。
                // 移植时重解规则、别搬常数 —— 见 H104。
                //
                // ⚠️ 但"两边等距"这条规则本身被装机否了:等距只保证不偏心,
                // 不保证看得见、够得着 —— 装机反馈"贴得太近"。所以在 inset 之外再抬 6.dp,
                // 抬完复量:栏底→小白条 21 px → **40 px**,小白条→屏底 21 px 不变。
                // (同一处本机还量出过 16 px 那一组,那是"到小白条**上沿**"的口径,
                //  与"到可见亮边"差几个像素 —— 绝对值别当规范,要复现自己重扫。)
                // 鸿蒙那台要一起抬得重解它的 0.62,不是把这个 6dp 抄过去(这轮没动鸿蒙)。
                .navigationBarsPadding()
                .padding(bottom = 6.dp)
                .onSizeChanged { overlayPx = it.height }
        ) {
            /**
             * 栏 + 播放条**叠在同一条带上**,不再上下排。
             *
             * 为什么从 `Column { MiniPlayer; GlassNavBar }` 改成 Box(2026-10-15,向鸿蒙收束形态对齐):
             * 收束态播放条要**落进栏那 52dp 里**(整块与栏等高、栏淡到 0),而上下排列的 Column
             * 做不到"叠上去"。改成叠层之后这一块的**高度按展开态那一档恒定**
             * (栏 + 缝 + 胶囊),于是 [onSizeChanged] 报出去的页面让位量与收没收束无关 ——
             * 这一点必须成立,否则每次翻转都要重排整条列表,而翻转恰好发生在滚动中。
             * 两态的**落点差**由 [MiniPlayer] 内部那道 `lift` 给(同一条弹簧派生,见那条注释的 ⚠️)。
             *
             * ⚠️ 停止播放时这一块的宽度仍要留给栏,所以是"没有播放条"而不是"整块消失"。
             */
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(if (playing) GLASS_BAR_H + MINI_GAP + MINI_H else GLASS_BAR_H)
            ) {
                // 底部栏在这一层**恒显示**(它是顶层外壳的一部分;详情/播放页各有各的外壳,
                // 不经过这里)。以前包一层 `AnimatedVisibility(isTopLevel)`,而 isTopLevel 由
                // 内层导航的 route 推出来 —— 拆掉内层栈之后那个判断恒为真,留着只会让人以为
                // 这里还有"隐藏 tab"的状态(详情页第 87 行那条注释说的是另一件事)。
                GlassNavBar(
                    tabs = tabs,
                    selected = selectedTab,
                    onSelect = { i -> select(i) },
                    modifier = Modifier.align(Alignment.BottomCenter),
                    collapsed = collapsed.value
                )
                MiniPlayerBar(
                    onExpand = { rootNav.navigate("player") },
                    onOpenQueue = { rootNav.navigate("queue") },
                    collapsed = collapsed.value,
                    // 盘上是**当前那一格**的图标(与鸿蒙 [BALL_ICONS] 同一语义:这颗球读作
                    // "整条栏收在这里",不是"回首页"),所以取栏的 spec 而不是固定的房子。
                    ballIcon = tabs.getOrNull(selectedTab)?.icon,
                    // 点球只展开、**不改当前 tab**(与鸿蒙 expandMini 同一条:不改页,清零累加器)
                    onRestore = {
                        morphAcc[0] = 0f
                        collapsed.value = false
                    },
                    collapseIntoBar = true,
                    modifier = Modifier.align(Alignment.BottomCenter)
                )
            }
        }
    }
}

/**
 * tab 外壳这一层的命中/绘制次序(数值本身没有意义,只要大小关系成立)。
 * [Z_BAR] 必须高于 [Z_VISIBLE]:底部玻璃栏与迷你播放条是后声明的兄弟节点,
 * 本来只靠声明顺序压在内容之上;两页一旦带上 zIndex,**显式的会盖过隐式的**,
 * 不给栏一个更大的数就会被可见页整块压住(栏看不见、也点不着)。
 */
private const val Z_HIDDEN = 0f
private const val Z_SHIELD = 1f
private const val Z_VISIBLE = 2f
private const val Z_BAR = 3f

/**
 * 「留着但看不见」的 Modifier —— 隐藏页**照做测量与布局**,只是不画、不进无障碍树。
 *
 * 为什么两件事都要:
 * - 不画用 [drawWithContent] 直接空实现,比 `graphicsLayer { alpha = 0f }` 省 —— 后者仍然
 *   把整棵子树绘制一遍再乘 0,而这里子树是两张满屏列表,这笔钱不该付。
 * - [clearAndSetSemantics] 让读屏与 `uiautomator dump` 只看得见当前那一页。不做这条,
 *   无障碍会把背后那页念出来,装机取证拿到的节点树也会多出一整套假节点(H116 的量法就靠它)。
 *
 * 手势不在这里管,由中间那道吸收层挡(理由见调用处)。
 */
private fun Modifier.tabKept(hidden: Boolean): Modifier = if (!hidden) this else this
    .drawWithContent { }
    .clearAndSetSemantics { }

/**
 * 底部迷你播放条(有正在播放的内容才显示)。供 tab 外壳与频道详情全屏页共用。
 *
 * 只有 tab 外壳那一处传 `collapseIntoBar = true`(整块叠在玻璃栏之上,要按态上下抬落点);
 * 详情 / 队列那两处是"播放条自己贴底",不传 → 收起状态恒为 false、球槽不出现。
 */
@Composable
private fun MiniPlayerBar(
    onExpand: () -> Unit,
    onOpenQueue: () -> Unit = {},
    collapsed: Boolean = false,
    ballIcon: ImageVector? = null,
    onRestore: () -> Unit = {},
    collapseIntoBar: Boolean = false,
    /// 封面点击是否跳频道页。默认 true,**只有频道详情页那份传 false**(经 [FloatingMini] 传下来):
    /// 在那里点自己这档的头像等于往栈上再压一份同一个页面。
    coverOpensChannel: Boolean = true,
    modifier: Modifier = Modifier
) {
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val buffering by PlayerController.buffering.collectAsStateWithLifecycle()
    val position by PlayerController.position.collectAsStateWithLifecycle()
    val duration by PlayerController.duration.collectAsStateWithLifecycle()
    val hasNext by PlayerController.hasNext.collectAsStateWithLifecycle()
    val cur = current
    // ⚠️ [modifier] 必须挂在 **AnimatedVisibility 这一层**,不能往下传给 MiniPlayer。
    // AnimatedVisibility 自己会包一层 Box,调用处给的 `align(BottomCenter)` 一旦穿过它,
    // 生效的父级就变成它内部那个"按内容收紧"的 Box —— align 被吃掉,整块退回默认的顶对齐,
    // 于是 MiniPlayer 内部那道 `lift` 只是把容器撑高、**整块根本不往下落**(收束态与栏不重合)。
    // 装机实测:展开态图标中心 1874、收束态 1885,差 11px(只有块高 44→52 的那半档),
    // 而按落点算式该差 **154px** = `lift(60dp=165px) − Δ块高/2(11px)` ——
    // 上面这两个"错的数"和那个 154 都能由同一条算式精确复现,见 H181。
    AnimatedVisibility(visible = cur != null, modifier = modifier) {
        if (cur != null) {
            val progress = if (duration > 0) position.toFloat() / duration else 0f
            MiniPlayer(
                episode = cur,
                isPlaying = isPlaying,
                buffering = buffering,
                progress = progress,
                hasNext = hasNext,
                onToggle = { PlayerController.togglePlayPause() },
                onNext = { PlayerController.next() },
                onExpand = onExpand,
                onOpenQueue = onOpenQueue,
                collapsed = collapsed,
                ballIcon = ballIcon,
                onRestore = onRestore,
                collapseIntoBar = collapseIntoBar,
                coverOpensChannel = coverOpensChannel
            )
        }
    }
}

/**
 * 频道详情 / 待播队列这两页的外壳:**悬浮播放条 + 底部直通屏底**。
 *
 * 为什么从 `Column { 内容 ; MiniPlayerBar }` 改成叠层(2026-10-16,用户指出「频道页的播放条不是悬浮的」):
 * 旧写法播放条自己占一行、底边正好压在 `systemBarsPadding` 的让位上沿 —— 于是胶囊下半截的两个圆角
 * 吃在屏幕边里,读出来就是「底部一块不透明的长方形板」,和三个 tab 页上那颗悬浮椭圆不是同一个东西。
 * 鸿蒙侧频道页早就是悬浮层(见 `harmony/.../pages/Index.ets` 里 `podcast` 分支那段注释),
 * 这两页是本端漏改的漂移,不是新设计。
 *
 * ⚠️ 但**只改成叠层还不够**(同一日用户第二次指出:「底部依然有一小段不透明」,并确认不是胶囊):
 * 那一块是 `FullScreen` 留下的 —— 它外层铺满整窗的不透明 `background`、内层 `systemBarsPadding()`,
 * 于是手势区那 16dp 是一条**纯色板**,列表滚到边就被截断,而胶囊悬浮在这条板上方 8dp,
 * 读起来就是"内容里嵌了一块板"。三个 tab 页从来没有这一块:外壳只垫状态栏,
 * 底部由悬浮栏自己按 `navigationBarsPadding` 落(见 [MainShell] 里那段"background 必须在 padding 之前")。
 * 所以这两页**不再套 `FullScreen`**,背景与状态栏由这里铺,底部让位量按 tab 外壳同一口径拆成两处:
 *
 * - 条子底边离**屏底** = 手势区 + [MINI_GAP];
 * - 内容侧让位量 = 手势区 + [MINI_H] + [MINI_GAP](没在播时只剩手势区那一档,
 *   否则末行会压在小白条上),经 [LocalGlassBottomPad] 给下去 —— 不给的话末项永远滚不出条子底下;
 * - **永不收束**(`collapsed` / `collapseIntoBar` 都留默认):这两页没有玻璃栏,
 *   没有可落进去的那一行,球槽也不该出现。
 *
 * ⚠️ 手势区要**同时**进落点和让位量这两处,只进一处都不成立:只进落点则末行藏在白条下面,
 * 只进让位量则条子仍坐在板上沿、下面那条板照旧。
 */
@Composable
private fun FloatingMini(
    onExpand: () -> Unit,
    onOpenQueue: () -> Unit = {},
    /// 透给播放条封面:频道详情页要传 false(已经在这一档的页面里)。
    miniCoverOpensChannel: Boolean = true,
    content: @Composable () -> Unit
) {
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val navInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val bottomPad = if (current == null) navInset else navInset + MINI_H + MINI_GAP
    CompositionLocalProvider(LocalGlassBottomPad provides bottomPad) {
        Box(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .statusBarsPadding()
        ) {
            content()
            MiniPlayerBar(
                onExpand = onExpand,
                onOpenQueue = onOpenQueue,
                coverOpensChannel = miniCoverOpensChannel,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = navInset + MINI_GAP)
            )
        }
    }
}
