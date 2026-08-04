package com.yuyin.reverb.ui

import android.Manifest
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
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
import com.yuyin.reverb.ui.components.MiniPlayer
import com.yuyin.reverb.ui.screens.AboutScreen
import com.yuyin.reverb.ui.screens.DiscoverScreen
import com.yuyin.reverb.ui.screens.LibraryScreen
import com.yuyin.reverb.ui.screens.LicensesScreen
import com.yuyin.reverb.ui.screens.PlayerScreen
import com.yuyin.reverb.ui.screens.PodcastDetailScreen
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

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        val launcher = rememberLauncherForActivityResult(
            ActivityResultContracts.RequestPermission()
        ) { }
        LaunchedEffect(Unit) { launcher.launch(Manifest.permission.POST_NOTIFICATIONS) }
    }

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
                    MiniPlayerBar(onExpand = { rootNav.navigate("player") })
                }
            }
        }
        composable("player") {
            FullScreen {
                PlayerScreen(
                    onBack = { rootNav.popBackStack() },
                    onOpenChannel = { feed -> rootNav.navigate("podcast/${Uri.encode(feed)}") }
                )
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

    val current by PlayerController.current.collectAsStateWithLifecycle()

    val backStackEntry by tabNav.currentBackStackEntryAsState()
    val route = backStackEntry?.destination?.route

    val tabs = listOf(
        TopDest("discover", stringResource(R.string.nav_discover), Icons.Rounded.Explore),
        TopDest("library", stringResource(R.string.nav_library), Icons.Rounded.LibraryMusic)
    )
    // route 在 tab 切换瞬间可能短暂为 null,若据此判定会让底部栏动画进出、内容上下跳动;
    // 故 null 一律视作顶层(两个 tab 都带底部栏),消除切 tab 时偶发的上下闪动。
    val isTopLevel = route == null || tabs.any { it.route == route }
    val showMini = current != null

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            Column {
                val cur = current
                MiniPlayerBar(onExpand = { rootNav.navigate("player") })
                AnimatedVisibility(visible = isTopLevel) {
                    Column {
                        if (showMini && cur != null) {
                            HorizontalDivider(
                                thickness = 0.5.dp,
                                color = MaterialTheme.colorScheme.outline.copy(alpha = 0.6f)
                            )
                        }
                        NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
                            tabs.forEach { d ->
                                NavigationBarItem(
                                    selected = route == d.route,
                                    onClick = {
                                        if (route != d.route) {
                                            tabNav.navigate(d.route) {
                                                launchSingleTop = true
                                                restoreState = true
                                                popUpTo(tabNav.graph.startDestinationId) { saveState = true }
                                            }
                                        }
                                    },
                                    icon = { Icon(d.icon, contentDescription = d.label) },
                                    label = { Text(d.label) },
                                    colors = NavigationBarItemDefaults.colors(
                                        selectedIconColor = MaterialTheme.colorScheme.primary,
                                        selectedTextColor = MaterialTheme.colorScheme.primary,
                                        indicatorColor = MaterialTheme.colorScheme.surfaceVariant
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
    ) { padding ->
        NavHost(
            navController = tabNav,
            startDestination = "discover",
            modifier = Modifier.padding(padding)
        ) {
            composable("discover") {
                DiscoverScreen(onOpen = { p -> rootNav.navigate("podcast/${Uri.encode(p.feedUrl)}") })
            }
            composable("library") {
                LibraryScreen(
                    onOpen = { p -> rootNav.navigate("podcast/${Uri.encode(p.feedUrl)}") },
                    onOpenSettings = { rootNav.navigate("settings") }
                )
            }
        }
    }
}

/** 底部迷你播放条(有正在播放的内容才显示)。供 tab 外壳与频道详情全屏页共用。 */
@Composable
private fun MiniPlayerBar(onExpand: () -> Unit) {
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
                onExpand = onExpand
            )
        }
    }
}
