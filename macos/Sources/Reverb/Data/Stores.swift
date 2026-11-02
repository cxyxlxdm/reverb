import Foundation

/// 应用私有目录 + 通用 JSON 读写。持久化到 ~/Library/Application Support/Reverb/。
enum AppSupport {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Reverb", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// iOS 的 iCloud/电脑备份默认整份带上 Application Support。音频下载、自动缓存、
    /// 封面与逐字稿动辄数百 MB,进备份等于白占用户的 iCloud 空间;而它们全都可以重建,
    /// 丢了最多重下一次。与 Android/鸿蒙的备份白名单同一个口径:**只备份清单与元数据**
    /// (订阅、收藏、历史、下载账本、印记、批注、收听时长、设置),大块可再生文件一律排除。
    ///
    /// macOS 不调用(`#if os(iOS)` 里是空实现):Time Machine 排除项由用户自己管,
    /// 而且 `TimeMachineExclusion` 那类标记会改用户备份策略,不该由 App 单方面决定。
    static func excludeFromBackup(_ url: URL) {
        #if os(iOS)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        #else
        _ = url
        #endif
    }

    static func load<T: Decodable>(_ file: String, as type: T.Type) -> T? {
        let url = dir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // ── 落盘:去抖 + 离开主线程 ────────────────────────────────────────────────
    //
    // 为什么需要:这些 store 都是 `@MainActor`,而 `save` 原先在主 actor 上
    // **同步**做 `JSONEncoder().encode` + `write(to:)`。播放中每 5 秒
    // `history.updatePosition` 就会整份写回一次 —— 本机实测 history.json **270 KB**;
    // inbox.json 自 2026-10-25 起按三端口径落 300 条(Android 同规模实测 741 KB),
    // 每轮刷新写一次。这些编码与写盘都是主线程上的固定开销。
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

    static func save<T: Encodable>(_ file: String, _ value: T, excludeFromBackup: Bool = false) {
        let work: () -> Void = {
            let url = dir.appendingPathComponent(file)
            if let data = try? JSONEncoder().encode(value) {
                try? data.write(to: url, options: .atomic)
                if excludeFromBackup { Self.excludeFromBackup(url) }
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

    /// 备份恢复用的**批量**合并入口(见 REVIEW-2026-10-25 中-7)。
    ///
    /// 与「逐条 `record`」的差别有两层,第二层才是加它的原因:
    /// ① **合并语义完全相同** —— 同 id 冲突取 `updatedAt` 较新者,平局留在场那一份(不回退进度);
    ///    来入条目胜出时 episode / positionMs / durationMs / played 整体覆盖,与原来
    ///    `record` + `updatePosition` + `markPlayed` 三连的净效果一致。
    /// ② **上限的作用域不同** —— `record` 每插一条就 `prefix(maxCount)` 夹一次并 persist 一次。
    ///    恢复是"一次进来几十上百条",于是每插一条就踢掉表尾一条:
    ///    一份 100 条的备份能把**本机既有历史整批顶掉**(和来入条目的 updatedAt 无关,纯粹是被
    ///    "插入即截断"挤的),同时写盘 100 次(每次都是整份 history.json)。
    ///    这里改成:先在全量集合上合并 → 排一次序 → 截断一次 → 落盘一次。
    ///    「只留最近 100 条」这条上限本身没动,动的是它**在整批之后才生效一次**。
    ///
    /// `record` 原样保留:日常起播走它,那条路径一次只加一条,"插入即截断"在那里是正确行为。
    func mergeForRestore(_ incoming: [HistoryEntry]) {
        guard !incoming.isEmpty else { return }
        var merged: [String: HistoryEntry] = [:]
        for h in history { merged[h.episode.id] = h }
        for inc in incoming {
            let id = inc.episode.id
            if let cur = merged[id], inc.updatedAt <= cur.updatedAt { continue }
            merged[id] = inc
        }
        // 最近置顶;`sorted(by:)` 是稳定排序,同一时间戳的两条保持它们在各自列表里的原有先后。
        let ordered = merged.values.sorted { $0.updatedAt > $1.updatedAt }
        history = Array(ordered.prefix(maxCount))
        Log.i("Store", "历史批量合并恢复 来入\(incoming.count) 合并后\(merged.count) 保留\(history.count)")
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

/// 听觉批注:一集可以有很多条,新写的置顶,落盘 `notes.json`(与 Android / 鸿蒙同格式)。
@MainActor final class NoteStore: ObservableObject {
    @Published private(set) var notes: [EpisodeNote]
    init() {
        // 没有可播音频地址的条目丢掉,而不是留一条"点不动"的批注 ——
        // 列表里躺一条永远播不了的记录,比少一条更让人怀疑是 bug(与另两端同一口径)。
        let all = AppSupport.load("notes.json", as: [EpisodeNote].self) ?? []
        notes = NoteStore.normalize(all.filter { !$0.episode.audioUrl.isEmpty })
        Log.i("Store", "批注加载 \(notes.count) 条" + (all.count > notes.count ? " 丢弃 \(all.count - notes.count) 条无音频" : ""))
    }

    /// 从盘上或备份里读来的批注过一次**归一**:按落笔时刻倒序,并把 `positionMs` 的负值归 0。
    ///
    /// 为什么补在「读盘 + 恢复」这一道:时间线和"点一句跳到那一秒"直接吃这个列表,而
    /// `notes.json` 是**三端共用**的文件 —— 本端的写入点管不住它的前任(另一端写的顺序、
    /// 手工编辑过的内容、系统级云备份还原那种**整份文件覆盖回来**的路径,压根不经过 `addAll`)。
    /// 硬规矩 10 说的"不变式在数据出口一次性保证",对读盘而言那个出口就是这份文件的**入口**。
    /// `Array.sorted` 走的是稳定排序,同一毫秒写下的两条保持原有先后。
    ///
    /// **刻意不套用 `add` 那条「上限夹到该集时长」**:`add` 里那个夹成立,是因为按下"写批注"的
    /// 那一刻手上有播放器实时位置作真值参照;而读盘时唯一可比的是 **RSS 元数据时长** ——
    /// 它是发布方自报的近似值,常常比真实音频短。拿一个近似上限去改写用户早就写下的那一秒,
    /// 比留着那个越界值更糟(界面上的时间戳自己跳了位,而用户无从知道是谁改的)。
    /// 越界值走到播放那一步,由播放器按真实时长夹。与 Android / 鸿蒙同一口径,三端逐字对齐。
    private static func normalize(_ list: [EpisodeNote]) -> [EpisodeNote] {
        list.map { $0.positionMs < 0 ? EpisodeNote(noteId: $0.noteId, episode: $0.episode,
                                                   positionMs: 0, text: $0.text, createdAt: $0.createdAt) : $0 }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 落一条批注。返回 nil 表示文字为空而放弃(空批注没有意义,还会在列表里成一个无法分辨的空行)。
    ///
    /// `positionMs` 在**这里**夹进 `[0, 该集时长]`:界面上那个时间要能代表"那一秒真的在这一集里"。
    /// 拖进度条与 prepare 之间有个窗口,那一刻播放器给的位置可能是上一集的时长或超出本集的值
    /// —— 硬规矩 10:不变式在数据出口一次性保证,不在渲染侧兜底。
    @discardableResult
    func add(_ e: Episode, positionMs: Int, text: String, at now: Int) -> EpisodeNote? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let cap = e.durationSec > 0 ? e.durationSec * 1000 : Int.max
        let note = EpisodeNote(noteId: UUID().uuidString, episode: e,
                               positionMs: min(max(positionMs, 0), cap), text: body, createdAt: now)
        notes.insert(note, at: 0)
        Log.i("Store", "批注 add id=\(note.noteId) pos=\(note.positionMs)ms len=\(body.count) total=\(notes.count)")
        persist()
        return note
    }

    func remove(_ noteId: String) {
        let before = notes.count
        notes.removeAll { $0.noteId == noteId }
        Log.i("Store", "批注 remove id=\(noteId) -\(before - notes.count) 共 \(notes.count)")
        persist()
    }

    /// 备份恢复:按 `noteId` 去重(同一份备份重复恢复不会写出两份),再走同一条 `normalize`
    /// —— 与 `init()` 一个口径,这样"从备份恢复出来的列表"和"下次冷启动从盘上读到的列表"是同一份内容。
    func addAll(_ items: [EpisodeNote]) {
        let before = notes.count
        for n in items where !notes.contains(where: { $0.noteId == n.noteId }) { notes.append(n) }
        notes = NoteStore.normalize(notes)
        Log.i("Store", "批注批量合并 +\(notes.count - before)(共 \(notes.count))")
        persist()
    }

    private func persist() { AppSupport.save("notes.json", notes) }
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
    /// 以下三格**在本端没有界面**,只为了备份互通而存在:
    ///
    /// - `allowCellularDownload`:桌面没有蜂窝基带,"只能 Wi-Fi 下载"在 Mac 上无从谈起;
    /// - `updatesEnabled`:桌面没有常驻的订阅巡检/通知(追更页是拉取式,打开才刷);
    /// - `subsGrid`:订阅列表/宫格的切换,触屏上才有"切宫格"这个动作,桌面侧本来就没有这一视图开关
    ///   (见 REVIEW-2026-10-25 中-8 补的那一格)。
    ///
    /// 那为什么还存?因为备份 JSON 是三端共用的格式(见 `Data/BackupManager.swift` 顶部注释),
    /// 手机导出 → Mac 恢复 → 再从 Mac 导出回手机 这条路,原先会把这几格**静默抹掉**,
    /// 用户在手机上明明没动过"允许蜂窝下载",换回手机却变了。既然本端无对应行为,
    /// 唯一正确的处理就是**原样带过去**:读进来、存下来、导出时一字不改地写回去。
    @Published var allowCellularDownload: Bool { didSet { d.set(allowCellularDownload, forKey: "allow_cellular_download") } }
    @Published var updatesEnabled: Bool { didSet { d.set(updatesEnabled, forKey: "updates_enabled") } }
    @Published var subsGrid: Bool { didSet { d.set(subsGrid, forKey: "subs_grid") } }
    /// 发现页分类顺序(用户排过的 key 序列)。
    ///
    /// **这一格不是"只存不用"**:1.0.6 起发现页的分类下拉里有「自定义分类排序…」,
    /// 读写都在本端生效(见 `UI/DiscoverView.swift` `CategoryOrderSheet`)。
    /// 空数组 = 从没排过(按原序显示),**不是"恢复默认"** —— 与 Android
    /// `CategoryStore` / 鸿蒙 `CategoryStore` 同一条语义,所以恢复备份时也照这条读:
    /// 空数组不覆盖本机已排过的顺序(见 `BackupManager` 的 `applySettings`)。
    @Published var categoryOrder: [String] { didSet { d.set(categoryOrder, forKey: "category_order") } }
    /// 播放模式**按列**存:key 是 `ListTag` 的值,value 是 `PlayMode` 的 rawValue(ordinal)。
    /// 与 Android 的 `play_mode_map` / 鸿蒙同名同义(见 `PlayMode` 注释与 H119)。
    /// 这里用 dictionary 而不是 Android 那套 "k=v" 字符串集合:UserDefaults 原生支持字典,
    /// 也就不会有 Android 那边「feedUrl 含 `=` 时按最后一个 `=` 切」的读回坑(H118 记过)。
    @Published var playModeByTag: [String: Int] { didSet { d.set(playModeByTag, forKey: "play_mode_map") } }
    /// 回落值:没有列身份的入口(单播、迷你条、发现页)用它。空 tag 不落进上面那张表。
    @Published var playModeDefault: Int { didSet { d.set(playModeDefault, forKey: "play_mode") } }
    /// 语音转文字:开启后播放页出现"转录"轮播页。默认关(需 macOS 26 + 首次下载语言模型)。
    @Published var transcriptionEnabled: Bool { didSet { d.set(transcriptionEnabled, forKey: "transcription_enabled") } }
    /// 是否已同意**当前版本**的隐私政策。
    ///
    /// 存的是「已同意的政策版本」而不是布尔:政策有实质变更时(新增网络访问点、新增权限、
    /// 改变数据用途…)按合规惯例要重新征求一次同意。**与 Android `SettingsStore.PRIVACY_VERSION`
    /// 同一个数,两边一起 +1** —— 手机与桌面说同一种话,不该一端的用户被重问、另一端没有。
    ///
    /// 门控在 `ReverbApp` 的 `PrivacyGate`:未同意时主界面树**根本不构建**,
    /// 发现页那些 `.task` 也就不会去请求 iTunes / fyyd / gpodder(与 Android 同一条理由)。
    ///
    /// 变更历史:1 = 首个版本;2 = 1.0.5(应用内更新带来的 `api.github.com`,桌面端没有这套机制,
    /// 但与手机端同一个数);3 = 1.0.6(视频站接口 `api.bilibili.com`、其 CDN、封面地址与短链);
    /// **4 = 1.0.6 macOS 补上应用内更新** —— 桌面端这时才真的开始请求 `api.github.com`,
    /// 对 macOS 用户来说是新增的网络访问点,按合规口径要重新征求一次。
    ///
    /// ⚠️ 这是**唯一一次**桌面比手机先行:Android 自 1.0.5 起就在请求同一个接口,
    /// 它的同意页早就写过这件事,所以 Android / 鸿蒙的 `PRIVACY_VERSION` 停在 3 不动 ——
    /// 让手机用户为一件他们已经同意过的事再点一次同意,不是谨慎,是骚扰。
    /// 下一次三端都有的实质变更再一起 +1(把这三行注释当作「为什么这里不同步」的凭据)。
    /// **1.0.7 的直播流没有 +1**:它不引入任何有名有姓的第三方 —— 请求的就是用户自己
    /// 粘贴的那条流地址,与「粘 RSS」同一类,同意页正文早已写明「直接请求发布方或托管方」。
    static let privacyVersion = 4
    @Published private(set) var privacyAccepted: Bool
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
        // 这两格**默认关**,与 Android `SettingsStore.kt` / 鸿蒙 `SettingsStore.ets` 同一口径
        // (见 REVIEW-2026-10-25 高-2)。原先这里写的是 `?? true`,注释还自称「初值与另两端同口径」——
        // 那句话是错的:两端都是 false,于是"要和手机默认一致才不篡改备份"这个动机
        // 恰好被写成了反效果:一台从没恢复过手机备份的 Mac 导出的备份(导出弹窗默认全勾含 settings),
        // 拿到 Android 恢复时会**无条件把那两个开关打开**。
        // 默认关不是"桌面用不到所以随便填",而是合规要求:
        // - `updatesEnabled`:政策承诺「仅在你主动开启订阅更新提醒时征求同意」,默认开等于没经同意就去要通知权限;
        // - `allowCellularDownload`:默认开等于替用户在蜂窝网络下花流量。
        // 本端这两格仍然没有界面、只为了「手机 → Mac → 手机」不把手机那侧的设置抹掉(见上方属性注释)。
        allowCellularDownload = d.object(forKey: "allow_cellular_download") as? Bool ?? false
        updatesEnabled = d.object(forKey: "updates_enabled") as? Bool ?? false
        // 与 Android `subs_grid` / 鸿蒙 `Prefs.getBool('subs_grid', false)` 同一初值 false。
        // 本端没有这个开关的界面,这个数只可能是从备份里读回来的,所以初值要跟两端一致 ——
        // 一台从没恢复过备份的 Mac 导出时写 true,等于替手机那侧的用户打开了宫格视图。
        subsGrid = d.object(forKey: "subs_grid") as? Bool ?? false
        categoryOrder = d.stringArray(forKey: "category_order") ?? []
        transcriptionEnabled = d.object(forKey: "transcription_enabled") as? Bool ?? true
        language = d.string(forKey: "app_language") ?? ""
        playModeByTag = (d.dictionary(forKey: "play_mode_map") as? [String: Int]) ?? [:]
        playModeDefault = d.object(forKey: "play_mode") as? Int ?? 0
        // 没存过 = 从没同意过(桌面端以前没有这一页,不存在 Android 那条
        // `privacy_accepted` 布尔的老格式要兼容)。
        privacyAccepted = (d.object(forKey: "privacy_version") as? Int ?? 0) >= Self.privacyVersion
    }

    /// 同意当前版本的隐私政策。写入后主界面树才第一次构建。
    func acceptPrivacy() {
        d.set(Self.privacyVersion, forKey: "privacy_version")
        privacyAccepted = true
    }

    /// 写某一列的模式。**空 tag 不写这张表** —— 它表示「没有列身份」,走回落那一格。
    func setPlayMode(_ v: Int, for tag: String) {
        if tag.isEmpty { playModeDefault = v; return }
        playModeByTag[tag] = v
    }
}
