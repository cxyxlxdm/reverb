package com.yuyin.reverb.ui

import android.Manifest
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.yuyin.reverb.R
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.components.GlassNavBar
import com.yuyin.reverb.ui.components.GlassTabSpec
import com.yuyin.reverb.ui.components.LocalGlassBottomPad
import com.yuyin.reverb.ui.components.MiniPlayer
import com.yuyin.reverb.ui.screens.AboutScreen
import com.yuyin.reverb.ui.screens.DiscoverScreen
import com.yuyin.reverb.ui.screens.LibraryScreen
import com.yuyin.reverb.ui.screens.LicensesScreen
import com.yuyin.reverb.ui.screens.ListenStatsScreen
import com.yuyin.reverb.ui.screens.PlayerScreen
import com.yuyin.reverb.ui.screens.PodcastDetailScreen
import com.yuyin.reverb.ui.screens.QueueScreen
import com.yuyin.reverb.ui.screens.SettingsScreen
import com.yuyin.reverb.ui.screens.StampsScreen

private data class TopDest(val route: String, val label: String, val icon: ImageVector)

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

    NavHost(navController = rootNav, startDestination = "main") {
        composable("main") { MainShell(rootNav) }
        // 频道详情作为全屏页(与播放页/设置同级),整体转场,避免进详情时底部栏收起导致的上下闪动;
        // 仍在底部保留迷你播放条,不显示 tab。
        composable("podcast/{feed}") { entry ->
            val feed = entry.arguments?.getString("feed").orEmpty()
            FullScreen {
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f)) {
                        PodcastDetailScreen(feedUrl = feed, onBack = { rootNav.popBackStack() })
                    }
                    MiniPlayerBar(
                        onExpand = { rootNav.navigate("player") },
                        onOpenQueue = { rootNav.navigate("queue") }
                    )
                }
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
            FullScreen {
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f)) {
                        QueueScreen(onBack = { rootNav.popBackStack() })
                    }
                    // 已在队列页:入口键不再响应,避免向同一路由重复压栈
                    MiniPlayerBar(onExpand = { rootNav.navigate("player") }, onOpenQueue = {})
                }
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

/** 带底部栏的 tab 外壳：内层导航承载 发现 / 音阁 / 播客详情（详情保留迷你播放条、隐藏 tab）。 */
@Composable
private fun MainShell(rootNav: NavHostController) {
    val tabNav = rememberNavController()

    val backStackEntry by tabNav.currentBackStackEntryAsState()
    val route = backStackEntry?.destination?.route

    val tabs = listOf(
        TopDest("discover", stringResource(R.string.nav_discover), Icons.Rounded.Explore),
        TopDest("library", stringResource(R.string.nav_library), Icons.Rounded.LibraryMusic)
    )
    // route 在 tab 切换瞬间可能短暂为 null,若据此判定会让底部栏动画进出、内容上下跳动;
    // 故 null 一律视作顶层(两个 tab 都带底部栏),消除切 tab 时偶发的上下闪动。
    val isTopLevel = route == null || tabs.any { it.route == route }
    val rawIdx = tabs.indexOfFirst { it.route == route }
    // 选中 tab:route 瞬时为 null 时沿用上一次的,药丸别被抖回第一格
    var lastTab by remember { mutableIntStateOf(0) }
    LaunchedEffect(rawIdx) { if (rawIdx >= 0) lastTab = rawIdx }
    val selectedTab = if (rawIdx >= 0) rawIdx else lastTab

    /**
     * 底部悬浮玻璃栏(与鸿蒙 GlassTabBar 同款,装机验收基准)。原来是一块贴底的
     * Material NavigationBar —— 玻璃要"浮"起来,内容必须能从栏下滚过,所以整块
     * 改成叠层:NavHost 铺满,列表用 [LocalGlassBottomPad] 让出底部余量,
     * 栏与迷你播放条悬浮在内容之上。
     */
    var overlayPx by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    val bottomPad = remember(overlayPx) { with(density) { overlayPx.toFloat().toDp() } + 8.dp }

    // 状态栏让位:App 是 edge-to-edge 的(setDecorFitsSystemWindows=false),tab 外壳
    // 不让位的话 ScreenHeader 的顶距直接顶进状态栏。**background 必须在
    // statusBarsPadding 之前** —— 反过来背景只铺到状态栏以下,通知栏区域露黑底,
    // 沉浸式就没了(第一版修法犯过)。只垫 status bar,底部由悬浮栏自带的
    // navigationBarsPadding 管。
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).statusBarsPadding()) {
        CompositionLocalProvider(LocalGlassBottomPad provides bottomPad) {
            NavHost(
                navController = tabNav,
                startDestination = "discover",
                modifier = Modifier.fillMaxSize()
            ) {
                composable("discover") {
                    DiscoverScreen(onOpen = { p -> rootNav.navigate("podcast/${Uri.encode(p.feedUrl)}") })
                }
                composable("library") {
                    LibraryScreen(
                        onOpen = { p -> rootNav.navigate("podcast/${Uri.encode(p.feedUrl)}") },
                        onOpenSettings = { rootNav.navigate("settings") },
                        onOpenListenStats = { rootNav.navigate("listen_stats") }
                    )
                }
            }
        }
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .onSizeChanged { overlayPx = it.height },
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            MiniPlayerBar(
                onExpand = { rootNav.navigate("player") },
                onOpenQueue = { rootNav.navigate("queue") }
            )
            AnimatedVisibility(visible = isTopLevel) {
                GlassNavBar(
                    tabs = tabs.map { GlassTabSpec(it.label, it.icon) },
                    selected = selectedTab,
                    onSelect = { i ->
                        tabNav.navigate(tabs[i].route) {
                            launchSingleTop = true
                            restoreState = true
                            popUpTo(tabNav.graph.startDestinationId) { saveState = true }
                        }
                    }
                )
            }
        }
    }
}

/** 底部迷你播放条(有正在播放的内容才显示)。供 tab 外壳与频道详情全屏页共用。 */
@Composable
private fun MiniPlayerBar(onExpand: () -> Unit, onOpenQueue: () -> Unit = {}) {
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val buffering by PlayerController.buffering.collectAsStateWithLifecycle()
    val position by PlayerController.position.collectAsStateWithLifecycle()
    val duration by PlayerController.duration.collectAsStateWithLifecycle()
    val hasNext by PlayerController.hasNext.collectAsStateWithLifecycle()
    val cur = current
    AnimatedVisibility(visible = cur != null) {
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
                onOpenQueue = onOpenQueue
            )
        }
    }
}
