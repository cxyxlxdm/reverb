import Foundation
import AppIntents

/// 卡片按键的**跨进程命令**。iOS / macOS 主屏卡片上的播放、暂停、切集都走这里,
/// 与 Android(`ReverbWidgetProvider` 的显式广播 + `goAsync`)和鸿蒙
/// (`postCardAction` 的 `call`)是同一条产品口径:**按下去只在后台改变播放状态,
/// 不拉起应用界面**;点封面或文字才进播放页。
///
/// 为什么用 `AudioPlaybackIntent` 而不是普通 `AppIntent`:
/// 普通 intent 的 `perform()` 在扩展进程里跑,而卡片的扩展进程**没有播放器**
/// (拿不到 App 的单例,也没有 AVAudioSession)。`AudioPlaybackIntent` 是系统
/// 专为"背景音频"留的口子:它把动作交给 App 执行,不把界面带到前台。
/// 代价是最低版本 iOS 17 / macOS 14 —— 低于 macOS 14 的桌面端不画可点的键。
///
/// 命令的落点由 App 启动时注册(`WidgetCommandCenter.handler`),契约文件本身
/// 不持有播放器;扩展进程里 handler 永远是 nil,它只负责把按钮画出来。
public enum WidgetCommand: String, Codable, Sendable {
    case toggle
    case previous
    case next
}

/// 命令分发。**必须在主线程注册与执行**:播放器是 `@MainActor` 的。
@MainActor
public enum WidgetCommandCenter {
    public static var handler: ((WidgetCommand) -> Void)?

    public static func dispatch(_ raw: String) {
        guard let command = WidgetCommand(rawValue: raw) else { return }
        handler?(command)
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public struct ReverbWidgetControlIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "播放控制"
    public static var description = IntentDescription("在桌面卡片上播放、暂停或切换上一集 / 下一集")
    /// 不收集音、不弹界面;动作本身就是播放器状态变化。
    public static var openAppWhenRun: Bool = false
    /// 只给卡片上的按钮用,不进 Spotlight / 快捷指令列表。
    public static var isDiscoverable: Bool = false

    @Parameter(title: "command")
    public var command: String

    public init() {
        command = WidgetCommand.toggle.rawValue
    }

    public init(_ command: WidgetCommand) {
        self.command = command.rawValue
    }

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            WidgetCommandCenter.dispatch(command)
        }
        return .result()
    }
}
