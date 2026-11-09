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
        WindowGroup {
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
        }
        .defaultSize(width: 1240, height: 860)
        .windowToolbarStyle(.unified)

        // 标准 macOS 设置场景:⌘, 及 App 菜单打开,齿轮按钮亦指向此处。
        Settings {
            SettingsView()
                .environmentObject(env)
                .environmentObject(env.player)
                .environmentObject(env.settings)
                .environmentObject(env.downloads)
                .environmentObject(env.downloadManager)
        }
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
