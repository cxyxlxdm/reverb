import SwiftUI

@main
struct ReverbApp: App {
    @StateObject private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // 首次启动的隐私同意门:未同意时 `RootView` 根本不构建,
            // 发现页那些联网 `.task` 也就一次都发不出去(与另三端同一条)。
            PrivacyGate {
                RootView()
            }
            .environmentObject(env)
            .environmentObject(env.player)
            .environmentObject(env.settings)
            .environmentObject(env.downloads)
            .environmentObject(env.downloadManager)
            .environmentObject(env.listenStats)
            .environmentObject(env.transcripts)
        }
        .onChange(of: scenePhase) { _, phase in
            // `AppSupport.save` 是去抖 + 后台编码落盘(见 Stores.swift 顶部),
            // 进程被系统收走前必须把最后 400ms 窗口里的写补完。
            if phase == .background {
                AppSupport.flushPending()
                // 每次退到后台重排一次:用户可能刚打开/关闭了更新提醒。
                env.updates.scheduleNext()
            }
        }
    }
}