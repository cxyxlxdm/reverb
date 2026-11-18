import Foundation

// 判据必须是平台,不是 `canImport`:macOS SDK 27 里 ActivityKit 模块**存在**,
// `canImport(ActivityKit)` 为真,而 `ActivityAttributes` / `LiveActivityIntent` 标了
// unavailable in macOS —— 于是 macOS 侧的 `swift build` 在这份文件上直接失败
// (`swift test` 也跟着挂,因为 ReverbTests 依赖整个模块)。表现是「只跑过 iOS 编译门、
// 没跑 macOS 门」的漏检,见 H284。
#if os(iOS)
import ActivityKit
import AppIntents

/// 播放页的 **Live Activity 契约**(iOS 锁屏 / 灵动岛)。App 与 Widget 扩展编同一份,
/// 与 `WidgetState.swift` 同一个理由:两进程之间只认结构体,不认对方的单例。
///
/// 进度**不靠 App 每秒推送**:`positionMs` 只在状态变化时写一次,视图按
/// `anchor + (now - anchor) * rate` 自己外推 —— 系统给出的计时器控件(`ProgressView(timerInterval:)`
/// / `Text(timerInterval:)`)本身就是按绝对时间走的。这样 App 在后台被挂起时,
/// 灵动岛上的倒计时仍然准确。⚠️ 暂停时必须把 `anchor` 改写成"此刻",否则恢复播放后
/// 进度会按暂停前那个锚点跳回一大截。
public struct PlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var podcast: String
        public var playing: Bool
        public var live: Bool
        public var positionMs: Int
        public var durationMs: Int
        public var rate: Double
        public var dark: Bool
        /// 上面那组进度数值对应的时刻(事件发生的那一瞬)。
        public var anchor: Date

        public init(
            title: String,
            podcast: String,
            playing: Bool,
            live: Bool,
            positionMs: Int,
            durationMs: Int,
            rate: Double,
            dark: Bool,
            anchor: Date
        ) {
            self.title = title
            self.podcast = podcast
            self.playing = playing
            self.live = live
            self.positionMs = positionMs
            self.durationMs = durationMs
            self.rate = rate
            self.dark = dark
            self.anchor = anchor
        }
    }

    /// 集 id。只用于去重与深链,不在界面上显示。
    public var episodeId: String

    public init(episodeId: String) {
        self.episodeId = episodeId
    }
}

/// 灵动岛 / 锁屏上的按键。与主屏卡片的 `ReverbWidgetControlIntent` 走同一个命令出口
/// (`WidgetCommandCenter`)—— 扩展进程没有播放器,动作一律交回 App 执行,
/// 且是"背景执行、不拉起界面"的那一档。
///
/// 为什么单独一个类型:主屏卡片认 `AudioPlaybackIntent`,Live Activity 的按键要求
/// `LiveActivityIntent`。两者都只是把字符串转交给同一张命令表,不复制动作实现。
@available(iOS 17.0, *)
public struct ReverbLiveActivityControlIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "播放控制"
    public static var description = IntentDescription("在锁屏 / 灵动岛上播放、暂停或切换上一集 / 下一集")
    public static var openAppWhenRun: Bool = false
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
#endif
