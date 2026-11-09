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
            // 深链挂在**同意门外面**:未同意时 `RootView` 不存在,挂在它身上的
            // `.onOpenURL` 也不会存在,卡片点进来的那一次会被丢掉(macOS 上踩过,见 H249)。
            // 这里先收进 `DeepLinkInbox`,等同意后 `RootView` 出现再由 onAppear 取走。
            .onOpenURL { DeepLinkInbox.shared.post($0) }
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
/// 卡片深链的缓冲区。与 macOS 那份(`macos/Sources/Reverb/ReverbApp.swift`)同形:
/// 系统投递时 `RootView` 可能还不存在(首次启动的同意门未过),先存着,等界面就绪再取。
@MainActor
final class DeepLinkInbox: ObservableObject {
    static let shared = DeepLinkInbox()
    @Published private(set) var arrival: URL?
    private var pending: URL?
    func post(_ url: URL) { pending = url; arrival = url }
    func takePending() -> URL? { defer { pending = nil }; return pending }
}
