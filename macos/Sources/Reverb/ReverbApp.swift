import SwiftUI
import AVFoundation

/// 入口:正常启动 App;带 --selftest <audioUrl> 时跑一次无界面播放自检(验证 PlayerController 播放管线)。
@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let url = i + 1 < args.count ? args[i + 1] : ""
            SelfTest.run(audioUrl: url)
            return
        }
        ReverbApp.main()
    }
}

struct ReverbApp: App {
    /// 深链走 AppKit 代理,而不是只靠 SwiftUI 的 `.onOpenURL`。
    ///
    /// 2026-11-09 排查时一度读成「系统没投递」:挂在 RootView 上的 `.onOpenURL` 一次都没被调用。
    /// 三个探针(AppKit / 最小 SwiftUI / 挂 `.onReceive` 的)在同样的锁屏状态下都收得到,
    /// 说明环境没问题;真正的原因是本机卡在首次启动的同意门后面 —— `RootView` 根本没构建,
    /// 挂在它身上的哪个回调都不会跑(见 H249)。所以这里**不是**在修一条坏接线,
    /// 而是把接收点提前到代理:同意门还在、RootView 还不存在的时候,`application(_:open:)`
    /// 照样能收到系统投递,先存进 `DeepLinkInbox` 等界面就绪。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment()

    /**
     * 退出前把去抖中的落盘补完。
     *
     * `AppSupport.save` 改成「去抖 + 后台编码写盘」之后(见 Stores.swift 的注释),
     * 最后一次写可能还在 400ms 的窗口里 —— 直接退出就会丢掉最近的播放进度。
     * 三端同一处理:鸿蒙在 `EntryAbility.onBackground` 调 `JsonFile.flushPending()`。
     */
    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            AppSupport.flushPending()
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            // 首次启动的隐私同意门:未同意时 `RootView` 根本不构建,
            // 发现页那些联网 `.task` 也就一次都发不出去(M11)。
            PrivacyGate {
                RootView()
            }
            .environmentObject(env)
            .environmentObject(env.player)
            .environmentObject(env.settings)
            .environmentObject(env.downloads)
            .environmentObject(env.downloadManager)
            .environmentObject(env.listenStats)
            // 把 `openWindow` 留一份给 AppDelegate:`applicationShouldHandleReopen`
            // 是纯 AppKit 回调,拿不到 SwiftUI 的环境值(见类注释)。
            .background(WindowReopenBridge())
        }
        .defaultSize(width: 1240, height: 860)
        .windowToolbarStyle(.unified)

        // 标准 macOS 设置场景:⌘, 及 App 菜单打开,齿轮按钮亦指向此处。
        // 设置窗按内容最小尺寸起约束、可继续拉大:原先 SettingsView 内写死 `.frame(width:height:)`,
        // 窗口跟着被钉成固定尺寸,用户拉不动。`.contentMinSize` 只锁下限,上限交给窗口。
        Settings {
            SettingsView()
                .environmentObject(env)
                .environmentObject(env.player)
                .environmentObject(env.settings)
                .environmentObject(env.downloads)
                .environmentObject(env.downloadManager)
        }
        .windowResizability(.contentMinSize)
    }
}

/// 系统投递进来的 `reverb://` URL 先落到这里,再由 RootView 取走。
///
/// 为什么要一个缓冲:**冷启动**时系统会在 `RootView` 还没订阅之前就投递
/// (同意门没过的机器上更晚),只挂 `onReceive` 会漏掉第一次点击。
/// `takePending()` 是那次「先到后订」的兜底;两条路都走同一个 `open` 方法,重复到达无副作用。
@MainActor
final class DeepLinkInbox: ObservableObject {
    static let shared = DeepLinkInbox()
    @Published private(set) var arrival: URL?
    private var pending: URL?
    func post(_ url: URL) {
        pending = url
        arrival = url
    }
    func takePending() -> URL? {
        defer { pending = nil }
        return pending
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Log.i("DeepLink", "系统投递 scheme=\(url.scheme ?? "-") host=\(url.host ?? "-")")
            DeepLinkInbox.shared.post(url)
        }
    }

    /// 点 Dock 图标 / 在 Finder 里再打开一次时,把主窗口叫回来。
    ///
    /// 背景:红点只关窗口、不退出进程(macOS 的标准行为),但 SwiftUI 的 `WindowGroup`
    /// 不会在用户点 Dock 图标时自己重建那扇窗 —— 2026-11-09 实测:关掉后 `activate`
    /// 与点 Dock 图标都停在 0 扇窗,界面再也出不来,只能 ⌘Q 重开。
    ///
    /// 两条路按代价排序:
    /// ① 窗口对象还在 `NSApp.windows` 里时,直接 `makeKeyAndOrderFront`;
    /// ② 已被释放时(例如先关了窗又开过设置窗口),用 `WindowReopener` 里存下的
    ///    `openWindow(id: "main")` 让 SwiftUI 重建 —— 这个环境动作必须在窗口
    ///    **还活着**时取,关窗之后 `WindowGroup` 的内容视图已经销毁,再没有地方能监听。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 最小化单独处理:窗口在 AX 里已经数不到,用户看到的就是"点 Dock 没反应"。
        // (实测点 Dock 时 AppKit 有时会先自动把它 deminiaturize,所以下面那条
        // `makeKeyAndOrderFront` 也能恢复;这一支是不依赖那个副作用的显式路径。)
        if let mini = sender.windows.first(where: { $0.canBecomeMain && $0.isMiniaturized }) {
            mini.deminiaturize(nil)
            mini.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            Log.i("Window", "Dock 重开:从最小化恢复")
            return true
        }
        guard !flag else { return true }
        if let window = sender.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else if let open = WindowReopener.shared.open {
            open(id: "main")
        } else {
            // 极早期(窗口从未建过)不该走到这里;留一行日志,免得下次又只能靠猜。
            Log.w("Window", "Dock 重开失败:既没有可复用的窗口,也没有 openWindow 动作")
            return true
        }
        sender.activate(ignoringOtherApps: true)
        Log.i("Window", "Dock 重开主窗口 ok")
        return true
    }
}

/// 在窗口还活着时把 SwiftUI 的 `openWindow` 动作存下来,供 AppDelegate 重建主窗口。
///
/// 为什么不在 `WindowGroup` 内容上挂 `.onReceive`:关掉最后一扇窗之后内容视图即销毁,
/// 那条监听也跟着没了 —— 而 `applicationShouldHandleReopen` 恰恰只在没有可见窗口时才需要它。
@MainActor
final class WindowReopener {
    static let shared = WindowReopener()
    var open: OpenWindowAction?
}

/// 零尺寸的桥接视图:只为拿到 `@Environment(\.openWindow)`。
private struct WindowReopenBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowReopener.shared.open = openWindow }
    }
}

/// 无界面播放自检:直接用 AVPlayer 播,打印状态与错误(定位 app 内网络/播放失败)。
enum SelfTest {
    static func run(audioUrl: String) {
        func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard let url = URL(string: audioUrl) else { err("SELFTEST bad url"); return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item); p.volume = 1; p.play()
        let start = Date()
        while Date().timeIntervalSince(start) < 6 {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            err(String(format: "SELFTEST t=%.2f status=%d tcs=%d err=%@",
                       p.currentTime().seconds, item.status.rawValue, p.timeControlStatus.rawValue,
                       String(describing: item.error ?? p.error)))
        }
        err(p.currentTime().seconds > 0.5 ? "SELFTEST RESULT: PLAYBACK OK" : "SELFTEST RESULT: NO PROGRESS")
    }
}
