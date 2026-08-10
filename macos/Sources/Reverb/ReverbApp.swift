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
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
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
