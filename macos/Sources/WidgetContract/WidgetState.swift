import Foundation
#if os(macOS)
import Darwin
#endif

/// 「继续收听」卡片的数据契约 —— **App 与 Widget 扩展两份代码共用这一个文件**
/// (扩展里通过 target 的 Sources 编进去,App 里显式加进 Reverb target)。
///
/// 为什么走「App 写一份 JSON、扩展只读」而不是扩展自己读历史:
///  - 扩展跑在**独立进程**,拿不到 App 的任何单例(与鸿蒙 `WidgetFormExtension` 同一条边界);
///  - 卡片要的只有"上次听到哪一集、听到第几秒",而这些在 App 里本来就是现成的内存值;
///  - 文案(`继续收听` / 空态 / `直播`)由 App 按当前界面语言算好写进来 —— 扩展因此
///    **不需要**自己再本地化正文,卡片不会出现"App 是法语、卡片是英文"这种错位。
///
/// 字段名与 Android `widget/WidgetState.kt`、鸿蒙 `widget/WidgetFormData.ets` 同义;
/// 三端都从各自的历史/会话文件推出同一组内容。
public struct WidgetState: Codable {
    /// 那一集的 id。深链带上它:冷启动时 `playback_state` 可能还没有当前集
    /// (卡片这条来自历史),不带 id 点开只能停在空播放页 —— 与 Android 的
    /// `EXTRA_OPEN_EPISODE` 同一条理由。
    public var id: String = ""
    public var title: String = ""
    public var podcast: String = ""
    /// 「12:34 / 45:00」或「直播」;没有进度时为空串(卡片不画那一行)
    public var time: String = ""
    /// 0...100,保留一位小数(等价于 Android 那边的 0...1000 千分档)。
    /// 1.0.8 起四端统一到这个精度:整数百分比在 80 分钟的节目上一格约 48 秒,
    /// 5 秒推一次时进度条会"定住"—— 鸿蒙与 Android 已按 0.1% 改过(见 H267)。
    public var percent: Double = 0
    public var hasProgress: Bool = false
    /// 正在播放。播放/暂停图标靠它翻面:进度 > 0 推不出"正在播",暂停时进度也还在。
    /// 与鸿蒙 `WidgetCard.playing` 同一位,App 侧由播放器的 `isPlaying` 写入。
    public var playing: Bool = false
    /// 直播流:没有进度可言
    public var live: Bool = false
    /// 空态(没有在听/听到一半的节目)
    public var empty: Bool = true
    /// 深浅配色。App 的主题档位(跟随系统 / 浅 / 深 / 纯白)只有 App 知道,
    /// 扩展里 `@Environment(\.colorScheme)` 拿到的是**设备**深浅,不是应用档位。
    public var dark: Bool = false
    /// 组容器里的封面文件名;空串 = 卡片退回符号占位
    public var art: String = ""

    /// 全默认值构造。**必须写在类型体里**:写进 extension 不会抑制合成的 `init()`,
    /// 两者重名(跨模块又要 public,所以不能靠默认的 internal 那一份)。
    public init() {}
}

/// 逐键宽容解码(H86:合成解码里「有默认值」**不等于「键可缺省」**)。
/// 卡片数据是跨进程边界,以后加字段时旧文件不能让整张卡退回空态。
/// 必须写在 extension 里 —— 写进类型体会吞掉上面的成员初始化器。
extension WidgetState {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        podcast = (try? c.decode(String.self, forKey: .podcast)) ?? ""
        time = (try? c.decode(String.self, forKey: .time)) ?? ""
        // 旧文件写的是整数百分比;Double 解码能直接吃下 `28`,不用为迁移加版本号。
        if let d = try? c.decode(Double.self, forKey: .percent) {
            percent = d
        } else if let i = try? c.decode(Int.self, forKey: .percent) {
            percent = Double(i)
        } else {
            percent = 0
        }
        hasProgress = (try? c.decode(Bool.self, forKey: .hasProgress)) ?? false
        playing = (try? c.decode(Bool.self, forKey: .playing)) ?? false
        live = (try? c.decode(Bool.self, forKey: .live)) ?? false
        empty = (try? c.decode(Bool.self, forKey: .empty)) ?? true
        dark = (try? c.decode(Bool.self, forKey: .dark)) ?? false
        art = (try? c.decode(String.self, forKey: .art)) ?? ""
    }
}

/// 两个进程之间的固定约定。改这里的任何一项都要同时改 App 侧
/// (`WidgetBridge.swift`)与扩展侧(`ReverbWidget.swift`),没有第三处。
public enum WidgetShared {
    /// App Group(iOS 专用;macOS 见 `containerURL`)。**免费 Personal Team 拿不到这项能力**(签名时报
    /// "does not support the App Groups capability") —— 上真机/TestFlight 需要
    /// Apple Developer Program 会员,与 TestFlight 本身是同一道门(见 docs/IOS.md)。
    public static let appGroup = "group.com.yuyin.reverb"
    /// 数据文件(直接写在组容器根,体积是几百字节)
    public static let stateFile = "widget_state.json"
    /// 封面副本。App 的 `ArtworkCache` 在**自己的**容器里,扩展读不到,所以落一份缩略图过来。
    public static let artFile = "widget_art.jpg"
    /// 点卡片进播放页的深链(scheme 在 App 的 Info.plist 里声明)。
    /// 带 id 时 App 会在没有当前集的情况下**只装载不播放**(见 `PlayerController.prepare`)。
    public static func playerURL(id: String) -> URL {
        var comps = URLComponents()
        comps.scheme = "reverb"
        comps.host = "player"
        if !id.isEmpty { comps.queryItems = [URLQueryItem(name: "id", value: id)] }
        return comps.url ?? URL(string: "reverb://player")!
    }

    /// 卡片数据目录。
    ///
    /// iOS 走 App Group;**macOS 走普通目录**,因为本端是 ad-hoc 签名、没有 Team ID ——
    /// macOS 的 App Group 名要求带 Team 前缀,拿不到组容器(见 `macos/Widget/ReverbWidget.entitlements`)。
    /// 目录与 `AppSupport.dir` 同一个父目录:`~/Library/Application Support/Reverb/widget`。
    ///
    /// 取真实家目录必须走 passwd,不能 `NSHomeDirectory()`:扩展是沙箱进程,后者给的是**容器**路径。
    public static var containerURL: URL? {
        #if os(macOS)
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        let url = home.appendingPathComponent("Library/Application Support/Reverb/widget",
                                               isDirectory: true)
        // App 侧建目录;沙箱里的扩展这句会失败(那一侧本来也只是只读),失败不影响取值。
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #endif
    }

    public static func stateURL(_ container: URL) -> URL { container.appendingPathComponent(stateFile) }
    public static func artURL(_ container: URL) -> URL { container.appendingPathComponent(artFile) }
}
