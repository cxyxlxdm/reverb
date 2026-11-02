import SwiftUI

/// 根视图:四格 Tab(发现 / 追更 / 音阁 / 设置),每格自带 `NavigationStack`。
/// 迷你播放条挂在内容底部、Tab 栏之上;点开是全屏播放页。
struct RootView: View {
    enum Tab: Hashable { case discover, inbox, library, settings }

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: PlayerController

    @State private var tab: Tab = .discover
    @State private var showPlayer = false
    @State private var discoverPath = NavigationPath()
    @State private var inboxPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    init() {
        #if DEBUG
        // 模拟器上没有可用的点击注入工具(Xcode 27 不再带 Simulator.app),
        // 所以留两个 Debug 启动参数给验收用,Release / TestFlight 里不存在:
        // `-start-tab settings` / `-open-player`。
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-start-tab"), i + 1 < args.count {
            switch args[i + 1] {
            case "discover": _tab = State(initialValue: .discover)
            case "inbox": _tab = State(initialValue: .inbox)
            case "library": _tab = State(initialValue: .library)
            case "settings": _tab = State(initialValue: .settings)
            default: break
            }
        }
        _showPlayer = State(initialValue: args.contains("-open-player"))
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            TabRoot(path: $discoverPath, showPlayer: $showPlayer) { DiscoverView() }
                .tabItem { Label("发现", systemImage: "sparkles") }
                .tag(Tab.discover)

            TabRoot(path: $inboxPath, showPlayer: $showPlayer) { InboxView() }
                .tabItem { Label("追更", systemImage: "tray.full") }
                .tag(Tab.inbox)

            TabRoot(path: $libraryPath, showPlayer: $showPlayer) { LibraryView() }
                .tabItem { Label("音阁", systemImage: "books.vertical") }
                .tag(Tab.library)

            TabRoot(path: $settingsPath, showPlayer: $showPlayer) { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView()
                .environmentObject(settings)
                .environmentObject(player)
        }
    }
}

/// 每格 Tab 的外壳:导航栈 + 频道页目的地 + 底部迷你播放条。
private struct TabRoot<Content: View>: View {
    @Binding var path: NavigationPath
    @Binding var showPlayer: Bool
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .navigationDestination(for: Podcast.self) { PodcastDetailView(podcast: $0) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if player.current != nil {
                        MiniPlayer { showPlayer = true }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: player.current != nil)
        .tint(Theme.accent(settings.accentIndex))
    }
}