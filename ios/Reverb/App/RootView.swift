import SwiftUI
import UIKit

/// 根视图:五格 Tab(发现 / 电台 / 追更 / 音阁 / 设置),每格自带 `NavigationStack`。
/// 迷你播放条挂在内容底部、Tab 栏之上;点开是全屏播放页。
struct RootView: View {
    enum Tab: Hashable { case discover, radio, inbox, library, settings }

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var env: AppEnvironment

    @State private var tab: Tab = .discover
    @State private var showPlayer = false
    @State private var discoverPath = NavigationPath()
    @State private var radioPath = NavigationPath()
    @State private var inboxPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    /// 双击底部 tab 回顶:每一格自己一个计数器,改哪个就只让哪一页滚。
    /// 为什么不用"滚到第 0 项"的共享状态:三页各有一批滚动容器(音阁一段一个),
    /// 由各页按自己当前那一段去解释这个数,外壳不掺和(与 Android 三个 token 同形)。
    @State private var discoverTopToken = 0
    @State private var inboxTopToken = 0
    @State private var libraryTopToken = 0

    init() {
        #if DEBUG
        // 模拟器上没有可用的点击注入工具(Xcode 27 不再带 Simulator.app),
        // 所以留两个 Debug 启动参数给验收用,Release / TestFlight 里不存在:
        // `-start-tab settings` / `-open-player`。
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-start-tab"), i + 1 < args.count {
            switch args[i + 1] {
            case "discover": _tab = State(initialValue: .discover)
            case "radio": _tab = State(initialValue: .radio)
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
            TabRoot(path: $discoverPath, showPlayer: $showPlayer) {
                DiscoverView(scrollTopToken: discoverTopToken)
            }
                .tabItem { Label("发现", systemImage: "sparkles") }
                .tag(Tab.discover)

            // 「电台」在设置里被关掉时整格不出现。与 macOS 的分段同口径:
            // 冷启动时 `tab` 若还停在电台(DEBUG 启动参数 / 状态恢复),下面 onChange 会切回发现。
            if settings.radioEnabled {
                TabRoot(path: $radioPath, showPlayer: $showPlayer) {
                    RadioView()
                }
                .tabItem { Label("电台", systemImage: "radio") }
                .tag(Tab.radio)
            }

            TabRoot(path: $inboxPath, showPlayer: $showPlayer) {
                InboxView(scrollTopToken: inboxTopToken)
            }
                .tabItem { Label("追更", systemImage: "tray.full") }
                .tag(Tab.inbox)

            TabRoot(path: $libraryPath, showPlayer: $showPlayer) {
                LibraryView(scrollTopToken: libraryTopToken)
            }
                .tabItem { Label("音阁", systemImage: "books.vertical") }
                .tag(Tab.library)

            TabRoot(path: $settingsPath, showPlayer: $showPlayer) { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // 双击当前那颗 tab → 那一格滚回顶部。探针不画东西、不占位,
        // 作用只是在 UITabBar 上装一个两击手势(为什么必须走这一层见 `TabBarDoubleTapProbe`)。
        .background {
            TabBarDoubleTapProbe { idx in
                // 电台格消失时后面三格整体前移一位。按**当前**可见序列算,
                // 不能写死 2/3 —— 那会让「关掉电台后双击追更」落到音阁上。
                let shift = settings.radioEnabled ? 0 : 1
                switch idx + shift {
                case 0: discoverTopToken += 1
                case 2: inboxTopToken += 1
                case 3: libraryTopToken += 1
                default: break   // 电台搜完自然停在顶部,设置页没有长列表,双击不做任何事
                }
            }
        }
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
        // 在同一张设置页里关掉电台:如果正停在那一格,切回发现。
        .onChange(of: settings.radioEnabled) { on in
            if !on && tab == .radio { tab = .discover }
        }
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
        // 卡片深链 `reverb://player[?id=…]`。接收点在 `ReverbApp` 的 `.onOpenURL`(同意门外),
        // 这里只消费 `DeepLinkInbox`:后续到达走订阅,「RootView 还没出现就投递」的那次
        // 由 onAppear 取走(与 macOS 同形,见 H249)。
        .onReceive(DeepLinkInbox.shared.$arrival.compactMap { $0 }) { _ in
            if let url = DeepLinkInbox.shared.takePending() { openFromWidget(url) }
        }
        .onAppear {
            if let url = DeepLinkInbox.shared.takePending() { openFromWidget(url) }
        }
    }

    /// 带 id 时先按历史装载成暂停态再开播放页 —— 与 Android 的 `EXTRA_OPEN_EPISODE` 同一条:
    /// **不自动播放**。重复到达无副作用:`prepare` 同 id 短路,`showPlayer` 是幂等置位。
    private func openFromWidget(_ url: URL) {
        guard url.scheme == "reverb", url.host == "player" else { return }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value ?? ""
        if !id.isEmpty, player.current?.id != id,
           let ep = env.history.history.first(where: { $0.episode.id == id })?.episode {
            player.prepare(ep)
        }
        showPlayer = true
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

/**
 双击底部 tab 的探针。
 
 为什么必须走 UIKit 这一层:SwiftUI 的 `TabView` 只在**真的换格**时触发 `selection` 变化,
 点当前这颗 tab 没有任何回调 —— 与 Android `GlassNavBar`(点已选中的那颗不走 `onSelect`)
 和鸿蒙 `onTabBarClick`(@since 6.0.0 才提供原始点击)是同一条限制。三端都只能自己在
 底栏层接一次点击。
 
 探针本身宽高 0、不绘制:它存在的唯一目的是拿到窗口里的 `UITabBar`,在上面装一个
 **两击**手势(`numberOfTapsRequired = 2`,系统自己按双击间隔判时,与 Android/鸿蒙那个 380ms
 窗口等价)。`cancelsTouchesInView` 与 `delaysTouchesEnded` 都关掉 —— 第一下必须照常切格,
 不能被"等第二下"拖慢。
 
 哪个格子被点:按 `bounds.width / items.count` 等分算。⚠️ 不要去遍历 `subviews` 找
 `UITabBarButton` 的 frame:那要按私有类名匹配,系统一改名就静默失效;系统 tab 栏的格子
 本来就是等分的,等分法只依赖公开 API。
 */
private struct TabBarDoubleTapProbe: UIViewRepresentable {
    let onDoubleTap: (Int) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onDoubleTap = onDoubleTap
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onDoubleTap = onDoubleTap
    }

    final class ProbeView: UIView {
        var onDoubleTap: ((Int) -> Void)?
        /// 已经装过手势的那一条 tab 栏。换窗口/换控制器时重装,同一根不重复装。
        private weak var observedBar: UITabBar?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        /// `didMoveToWindow` 可能早于 SwiftUI 建出 `UITabBarController`,所以布局期再试一次;
        /// `observedBar` 那层判断保证反复调用只装一次。
        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfNeeded()
        }

        private func attachIfNeeded() {
            guard let root = window?.rootViewController,
                  let tabs = Self.findTabBarController(in: root) else { return }
            let bar = tabs.tabBar
            guard bar !== observedBar else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handle(_:)))
            tap.numberOfTapsRequired = 2
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            bar.addGestureRecognizer(tap)
            observedBar = bar
            // 挂没挂上是这条功能唯一「看不见」的一步(真触摸没法自动注入),留一行日志给验收。
            Log.i("TabBar", "双击回顶探针已挂上 items=\(bar.items?.count ?? 0)")
        }

        @objc private func handle(_ gesture: UITapGestureRecognizer) {
            guard let bar = observedBar, let items = bar.items, !items.isEmpty else { return }
            let point = gesture.location(in: bar)
            guard bar.bounds.width > 0 else { return }
            let slice = bar.bounds.width / CGFloat(items.count)
            let index = min(max(Int(point.x / slice), 0), items.count - 1)
            Log.i("TabBar", "双击 tab idx=\(index) → 回顶")
            onDoubleTap?(index)
        }

        private static func findTabBarController(in vc: UIViewController) -> UITabBarController? {
            if let tabs = vc as? UITabBarController { return tabs }
            for child in vc.children {
                if let found = findTabBarController(in: child) { return found }
            }
            if let presented = vc.presentedViewController {
                return findTabBarController(in: presented)
            }
            return nil
        }
    }
}

extension TabBarDoubleTapProbe.ProbeView: UIGestureRecognizerDelegate {
    /// 与 tab 栏自己的点击处理并存:两击被识别时也不抢掉系统的选中逻辑。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
