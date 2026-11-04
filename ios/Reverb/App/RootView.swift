import SwiftUI

/// 根视图:四格 Tab(发现 / 追更 / 音阁 / 设置),每格自带 `NavigationStack`。
/// 迷你播放条挂在内容底部、Tab 栏之上;点开是全屏播放页。
struct RootView: View {
    enum Tab: Hashable { case discover, inbox, library, settings }

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var env: AppEnvironment

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
        // 字号:手机端沿用 Android / 鸿蒙那四档(0.85 / 1.0 / 1.15 / 1.3)。
        // SwiftUI 没有任意倍率的全局字号,只能映射到最接近的 `DynamicTypeSize`;
        // 「标准」不施加约束 ⇒ 跟随系统辅助功能字号,这是 iOS 用户预期内的行为。
        .dynamicTypeSize(FontScale.dynamicTypeSize(settings.fontScale))
        .overlay(alignment: .top) {
            TopToast(text: env.toast.text)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: env.toast.text)
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView()
                .environmentObject(settings)
                .environmentObject(player)
        }
    }
}

/// 四档字号的映射表。数值与 Android `SettingsStore.FONT_SCALES` / 鸿蒙 `Theme.FONT_SCALES`
/// 逐项相同,但 iOS 只能落到离散的 `DynamicTypeSize` 上 —— 两边都是「同一档叫法、最接近的倍率」,
/// 不承诺逐像素一致(见 `docs/FEATURES.md` 字号那一行)。
enum FontScale {
    static let scales: [Double] = [0.85, 1.0, 1.15, 1.3]
    static let labels = ["小", "标准", "大", "特大"]

    static func index(for scale: Double) -> Int {
        var best = 1
        var diff = Double.greatestFiniteMagnitude
        for (i, s) in scales.enumerated() {
            let d = abs(s - scale)
            if d < diff { diff = d; best = i }
        }
        return best
    }

    static func dynamicTypeSize(_ scale: Double) -> DynamicTypeSize {
        switch index(for: scale) {
        case 0: return .small      // ≈0.88
        case 2: return .xLarge     // ≈1.12
        case 3: return .xxxLarge   // ≈1.35(最接近 1.3 的一档)
        default: return .large     // 系统默认,跟随辅助功能设置
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