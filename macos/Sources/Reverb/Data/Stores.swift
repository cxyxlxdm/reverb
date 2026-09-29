import Foundation

/// 应用私有目录 + 通用 JSON 读写。持久化到 ~/Library/Application Support/Reverb/。
enum AppSupport {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Reverb", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func load<T: Decodable>(_ file: String, as type: T.Type) -> T? {
        let url = dir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // ── 落盘:去抖 + 离开主线程 ────────────────────────────────────────────────
    //
    // 为什么需要:这些 store 都是 `@MainActor`,而 `save` 原先在主 actor 上
    // **同步**做 `JSONEncoder().encode` + `write(to:)`。播放中每 5 秒
    // `history.updatePosition` 就会整份写回一次 —— 本机实测 history.json **270 KB**、
    // inbox.json **747 KB**,这是主线程上每 5 秒一次的固定开销。
    // 与鸿蒙那一轮同一个道理(TROUBLESHOOTING H65):去抖要连"生成数据"一起去抖,
    // 只把写盘挪走、编码还留在主线程是没解决问题。
    //
    // 做法:值类型先被闭包捕获(数组是值语义,拷贝即快照),编码与写盘都在后台队列;
    // 同一文件在 debounce 窗口内的多次调用只落最后一次。
    // **代价**:进程被杀时最多丢窗口内的一次写入 —— 所以退出前必须 `flushPending()`
    // (见 `ReverbApp` 的 willTerminate 钩子)。

    private static let ioQueue = DispatchQueue(label: "cn.cxyxl.reverb.appsupport-io", qos: .utility)
    private static let debounce: TimeInterval = 0.4
    private static let lock = NSLock()
    /// 文件名 → 待执行的"编码并写盘";同一文件只保留最新一份
    nonisolated(unsafe) private static var pending: [String: () -> Void] = [:]

    static func save<T: Encodable>(_ file: String, _ value: T) {
        let work: () -> Void = {
            let url = dir.appendingPathComponent(file)
            if let data = try? JSONEncoder().encode(value) {
                try? data.write(to: url, options: .atomic)
            }
        }
        lock.lock()
        pending[file] = work
        lock.unlock()
        ioQueue.asyncAfter(deadline: .now() + debounce) {
            lock.lock()
            let w = pending.removeValue(forKey: file)
            lock.unlock()
            w?()          // 已被更新的那次取走时,这里就是 nil,天然去抖
        }
    }

    /// 立刻把待写内容落盘(同步)。退出前必须调,否则会丢最后一次进度。
    static func flushPending() {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, w) in all { w() }
        if !all.isEmpty { Log.i("Store", "退出前落盘 \(all.count) 个文件") }
    }
}

/// 本地订阅。
@MainActor final class SubscriptionStore: ObservableObject {
    @Published private(set) var subscriptions: [Podcast]
    init() {
        subscriptions = AppSupport.load("subscriptions.json", as: [Podcast].self) ?? []
        Log.i("Store", "订阅加载 \(subscriptions.count) 条")
    }

    func isSubscribed(_ id: String) -> Bool { subscriptions.contains { $0.id == id } }

    func toggle(_ p: Podcast) {
        if let i = subscriptions.firstIndex(where: { $0.id == p.id }) {
            subscriptions.remove(at: i)
            Log.i("Store", "取消订阅 id=\(p.id) title=\"\(p.title)\"")
        } else {
            subscriptions.insert(p, at: 0)
            Log.i("Store", "订阅 id=\(p.id) title=\"\(p.title)\"")
        }
        persist()
    }

    func addAll(_ items: [Podcast]) {
        let before = subscriptions.count
        for p in items where !subscriptions.contains(where: { $0.id == p.id }) { subscriptions.append(p) }
        Log.i("Store", "订阅批量合并 +\(subscriptions.count - before)(共 \(subscriptions.count))")
        persist()
    }
    private func persist() { AppSupport.save("subscriptions.json", subscriptions) }
}

/// 单集收藏,最近置顶。
@MainActor final class FavoriteStore: ObservableObject {
    @Published private(set) var favorites: [Episode]
    init() {
        favorites = AppSupport.load("favorites.json", as: [Episode].self) ?? []
        Log.i("Store", "收藏加载 \(favorites.count) 条")
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggle(_ e: Episode) {
        if let i = favorites.firstIndex(where: { $0.id == e.id }) {
            favorites.remove(at: i)
            Log.i("Store", "取消收藏 id=\(e.id) title=\"\(e.title)\"")
        } else {
            favorites.insert(e, at: 0)
            Log.i("Store", "收藏 id=\(e.id) title=\"\(e.title)\"")
        }
        persist()
    }

    func addAll(_ items: [Episode]) {
        let before = favorites.count
        for e in items where !favorites.contains(where: { $0.id == e.id }) { favorites.append(e) }
        Log.i("Store", "收藏批量合并 +\(favorites.count - before)(共 \(favorites.count))")
        persist()
    }
    private func persist() { AppSupport.save("favorites.json", favorites) }
}

/// 播放历史:最近置顶,记录续播进度,最多 100 条。
@MainActor final class HistoryStore: ObservableObject {
    @Published private(set) var history: [HistoryEntry]
    private let maxCount = 100
    init() {
        history = AppSupport.load("history.json", as: [HistoryEntry].self) ?? []
        Log.i("Store", "历史加载 \(history.count) 条")
    }

    func positionFor(_ id: String) -> Int { history.first { $0.episode.id == id }?.positionMs ?? 0 }

    func record(_ e: Episode, at now: Double) {
        let existing = history.first { $0.episode.id == e.id }
        history.removeAll { $0.episode.id == e.id }
        history.insert(HistoryEntry(episode: e, positionMs: existing?.positionMs ?? 0,
                                    durationMs: existing?.durationMs ?? 0, updatedAt: now), at: 0)
        if history.count > maxCount { history = Array(history.prefix(maxCount)) }
        persist()
    }

    func updatePosition(_ id: String, positionMs: Int, durationMs: Int) {
        guard let i = history.firstIndex(where: { $0.episode.id == id }) else { return }
        history[i].positionMs = positionMs
        history[i].durationMs = durationMs
        persist()
    }

    /// 是否已播完。
    func isPlayed(_ id: String) -> Bool { history.first { $0.episode.id == id }?.played ?? false }

    /// 标记单集已播完 / 未播完。
    func markPlayed(_ id: String, _ played: Bool) {
        guard let i = history.firstIndex(where: { $0.episode.id == id }) else { return }
        guard history[i].played != played else { return }
        history[i].played = played
        Log.i("Store", "标记\(played ? "已" : "未")播完 id=\(id)")
        persist()
    }

    func clear() { Log.i("Store", "清空播放历史"); history = []; persist() }
    private func persist() { AppSupport.save("history.json", history) }
}

/// 听觉印记:每集最多一枚,最近置顶。
@MainActor final class StampStore: ObservableObject {
    @Published private(set) var stamps: [Stamp]
    init() {
        stamps = AppSupport.load("stamps.json", as: [Stamp].self) ?? []
        Log.i("Store", "印记加载 \(stamps.count) 条")
    }

    func sealFor(_ episodeId: String) -> String? { stamps.first { $0.episodeId == episodeId }?.seal }

    func set(episodeId: String, seal: String, title: String, podcastTitle: String, at now: Double) {
        stamps.removeAll { $0.episodeId == episodeId }
        stamps.insert(Stamp(episodeId: episodeId, seal: seal, title: title, podcastTitle: podcastTitle, createdAt: now), at: 0)
        Log.i("Store", "设置印记 id=\(episodeId) seal=\(seal)")
        persist()
    }

    func remove(_ episodeId: String) {
        Log.i("Store", "移除印记 id=\(episodeId)")
        stamps.removeAll { $0.episodeId == episodeId }; persist()
    }

    func addAll(_ items: [Stamp]) {
        let before = stamps.count
        for s in items where !stamps.contains(where: { $0.episodeId == s.episodeId }) { stamps.append(s) }
        Log.i("Store", "印记批量合并 +\(stamps.count - before)(共 \(stamps.count))")
        persist()
    }
    private func persist() { AppSupport.save("stamps.json", stamps) }
}

/// 应用设置(UserDefaults)。theme:0 跟随系统 /1 浅色 /2 深色 /3 纯白。
@MainActor final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard

    @Published var themeMode: Int { didSet { d.set(themeMode, forKey: "theme_mode") } }
    @Published var accentIndex: Int { didSet { d.set(accentIndex, forKey: "accent_index") } }
    @Published var fontScale: Double { didSet { d.set(fontScale, forKey: "font_scale") } }
    @Published var regionOverride: String { didSet { d.set(regionOverride, forKey: "region_override") } } // "" = 自动
    @Published var defaultSpeed: Double { didSet { d.set(defaultSpeed, forKey: "default_speed") } }
    @Published var skipBackSec: Int { didSet { d.set(skipBackSec, forKey: "skip_back") } }
    @Published var skipForwardSec: Int { didSet { d.set(skipForwardSec, forKey: "skip_fwd") } }
    @Published var contextualRadio: Bool { didSet { d.set(contextualRadio, forKey: "contextual_radio") } }
    /// 播放模式**按列**存:key 是 `ListTag` 的值,value 是 `PlayMode` 的 rawValue(ordinal)。
    /// 与 Android 的 `play_mode_map` / 鸿蒙同名同义(见 `PlayMode` 注释与 H119)。
    /// 这里用 dictionary 而不是 Android 那套 "k=v" 字符串集合:UserDefaults 原生支持字典,
    /// 也就不会有 Android 那边「feedUrl 含 `=` 时按最后一个 `=` 切」的读回坑(H118 记过)。
    @Published var playModeByTag: [String: Int] { didSet { d.set(playModeByTag, forKey: "play_mode_map") } }
    /// 回落值:没有列身份的入口(单播、迷你条、发现页)用它。空 tag 不落进上面那张表。
    @Published var playModeDefault: Int { didSet { d.set(playModeDefault, forKey: "play_mode") } }
    /// 语音转文字:开启后播放页出现"转录"轮播页。默认关(需 macOS 26 + 首次下载语言模型)。
    @Published var transcriptionEnabled: Bool { didSet { d.set(transcriptionEnabled, forKey: "transcription_enabled") } }
    /// 界面语言。"" = 跟随系统;否则为语言代码(zh-Hans/zh-Hant/en/fr/es)。写入 AppleLanguages,重启后生效。
    @Published var language: String {
        didSet {
            d.set(language, forKey: "app_language")
            if language.isEmpty {
                d.removeObject(forKey: "AppleLanguages")
            } else {
                d.set([language], forKey: "AppleLanguages")
            }
            d.synchronize()
        }
    }

    init() {
        themeMode = d.object(forKey: "theme_mode") as? Int ?? 0
        accentIndex = d.object(forKey: "accent_index") as? Int ?? 0
        fontScale = d.object(forKey: "font_scale") as? Double ?? 1.0
        regionOverride = d.string(forKey: "region_override") ?? ""
        defaultSpeed = d.object(forKey: "default_speed") as? Double ?? 1.0
        skipBackSec = d.object(forKey: "skip_back") as? Int ?? 10
        skipForwardSec = d.object(forKey: "skip_fwd") as? Int ?? 30
        contextualRadio = d.object(forKey: "contextual_radio") as? Bool ?? false
        transcriptionEnabled = d.object(forKey: "transcription_enabled") as? Bool ?? true
        language = d.string(forKey: "app_language") ?? ""
        playModeByTag = (d.dictionary(forKey: "play_mode_map") as? [String: Int]) ?? [:]
        playModeDefault = d.object(forKey: "play_mode") as? Int ?? 0
    }

    /// 写某一列的模式。**空 tag 不写这张表** —— 它表示「没有列身份」,走回落那一格。
    func setPlayMode(_ v: Int, for tag: String) {
        if tag.isEmpty { playModeDefault = v; return }
        playModeByTag[tag] = v
    }
}
