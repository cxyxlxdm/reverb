import SwiftUI

@main
struct ReverbApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(env.player)
                .environmentObject(env.settings)
        }
        .defaultSize(width: 1240, height: 860)
        .windowToolbarStyle(.unified)

        // 标准 macOS 设置场景:⌘, 及 App 菜单打开,齿轮按钮亦指向此处。
        Settings {
            SettingsView()
                .environmentObject(env)
                .environmentObject(env.player)
                .environmentObject(env.settings)
        }
    }
}
