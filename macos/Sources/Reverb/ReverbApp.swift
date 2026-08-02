import SwiftUI

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

/// 无界面播放自检:用真实 PlayerController 播 4 秒,打印进度是否推进。
enum SelfTest {
    static func run(audioUrl: String) {
        MainActor.assumeIsolated {
            let pc = PlayerController()
            let ep = Episode(id: "selftest", title: "SelfTest", description: "",
                             audioUrl: audioUrl, artworkUrl: "", podcastTitle: "Probe")
            pc.playQueue([ep], startIndex: 0)
            let start = Date()
            while Date().timeIntervalSince(start) < 4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                print(String(format: "SELFTEST pos=%dms playing=%@ dur=%dms",
                             pc.positionMs, pc.isPlaying ? "yes" : "no", pc.durationMs))
            }
            print(pc.positionMs > 500 ? "SELFTEST RESULT: PLAYBACK OK" : "SELFTEST RESULT: NO PROGRESS")
        }
    }
}
