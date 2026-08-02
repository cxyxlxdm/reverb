import SwiftUI

@main
struct ReverbApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(env.player)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(colorScheme(env.settings.themeMode))
        }
        .windowToolbarStyle(.unified)
    }

    private func colorScheme(_ mode: Int) -> ColorScheme? {
        switch mode {
        case 1, 3: return .light   // 浅色 / 纯白
        case 2: return .dark       // 深色
        default: return nil        // 跟随系统
        }
    }
}
