import Foundation

/// 逐字稿的**缓存口径与时间轴不变式**。
///
/// 为什么写在类外:`TranscriptStore` 是 `@MainActor`,而它的缓存解码刻意搬到后台线程
/// (一份词级稿实测 192 KB,主线程解码会让切集卡一下)。校验版本与夹单调这两步
/// 要跟着解码一起在后台跑完,所以它们不能是 MainActor 的成员。
/// 与 Android `TranscriptStore.CACHE_VERSION` / 鸿蒙 `TranscriptStore.CACHE_VERSION` **同一套含义**,
/// 但不要求同号:两端 1.0.8 换了识别引擎(whisper / Core Speech → sherpa-onnx),各自升到 3;
/// 这一端仍是 `SpeechAnalyzer`,口径没变,所以留在 2。缓存只在本机读,跨端不比对版本号。
enum TranscriptFormat {
    /// 缓存格式 / 时间轴口径的版本。**改了时刻的算法就要 +1**(硬规矩 11),
    /// 否则用户机器上已经生成的旧稿会一直按旧口径显示,修复等于没生效,而用户没有自救入口。
    ///
    /// - v1(缺失 `version` 字段的一律当 v1):词级时刻直接取 `audioTimeRange`,
    ///   句与句、词与词之间**不校验单调性**;
    /// - v2:在数据出口一次性保证「起点 ≥0 且单调不减、终点不早于起点」(见 `monotonic`)。
    static let version = 2

    /// 把句子起点夹成 **不小于 `floor`**、终点不早于起点,词级同理。
    ///
    /// 非做不可的理由:渲染侧找当前句用的是 `segments.lastIndex { $0.startMs <= now }`
    /// (`UI/TranscriptPage.swift:32`),这个写法**只在起点单调时才正确** ——
    /// 队尾混进一个异常小的值,它就永远满足条件,于是高亮钉死在那一句再也不动
    /// (Android 端的真实事故,见 TROUBLESHOOTING H60)。Apple 的 `audioTimeRange`
    /// 不保证按 run 递增,而将来若接官方稿(另一份别人生成的时间轴),同样不能假定它排好,
    /// 所以这条放在**两个来源共同经过的出口**上。
    static func monotonic(_ segments: [TranscribedSegment], floor: Int = 0) -> [TranscribedSegment] {
        var out: [TranscribedSegment] = []
        out.reserveCapacity(segments.count)
        var at = floor
        for s in segments {
            let start = max(s.startMs, at)
            at = start
            out.append(TranscribedSegment(
                text: s.text, startMs: start, endMs: max(s.endMs, start),
                words: s.words.map { tidyWords($0, floor: start) }))
        }
        return out
    }

    /// 词级同一规则:起点不小于句起点也不减,终点不早于起点。
    /// 不做"已经有序就原样返回"的快路径 —— 这条只在**读缓存(后台线程)与每句入库一次**
    /// 上跑,不在渲染路径上(硬规矩 6 管的是每秒两次的代码)。
    private static func tidyWords(_ words: [TranscribedWord], floor: Int) -> [TranscribedWord] {
        var out: [TranscribedWord] = []
        out.reserveCapacity(words.count)
        var at = floor
        for w in words {
            let start = max(w.startMs, at)
            at = start
            out.append(TranscribedWord(text: w.text, startMs: start, endMs: max(w.endMs, start)))
        }
        return out
    }
}

/// 「转录」状态机与缓存。每单集 × 每语言各存一份 JSON 到
/// ~/Library/Application Support/Reverb/Transcripts/,命中缓存秒显。
/// 转录本身走 Transcriber(仅 macOS 26,完全设备端)。
@MainActor final class TranscriptStore: ObservableObject {

    enum State: Equatable {
        case idle              // 未取稿:显示"查看逐字稿"或"生成转录"
        /// 正在读本机缓存。解码搬到后台之后不再是同一帧出结果,
        /// 这几十毫秒若沿用 idle 会**闪一下按钮**。与鸿蒙的 LoadingCache 对齐。
        case loadingCache
        case fetchingOfficial  // 正取发布方的官方稿(与 Android `FetchingOfficial` 同名同义)
        case downloadingAudio  // 流式单集:先下载音频
        case installingModel   // 首次:系统下载语言模型
        case running           // 识别中
        case done              // 完成(或命中缓存)
        case failed(String)
        case unsupportedLocale // 该语言不受支持
        case needsMacOS26      // 系统过旧,且这一集没有官方稿
    }

    @Published private(set) var segments: [TranscribedSegment] = []
    @Published private(set) var volatileTail: String = ""   // 生成期未定稿的实时尾巴;缓存命中为空
    @Published private(set) var state: State = .idle
    @Published private(set) var episodeId: String = ""
    @Published private(set) var localeId: String = ""

    private var generation = 0
    private var job: Task<Void, Never>?

    /// 「转录前下整集音频」这一步该不该放行,nil = 不拦(macOS 的取值 —— 桌面没有蜂窝基带)。
    ///
    /// 这是三条大流量路径里的第三条,长期没接闸门(见 Android `util/CellularGate.kt` 头注):
    /// 用户关了「仅在 Wi-Fi 下载」,下载与缓存都老实用 Wi-Fi,只有「转逐字稿」会在蜂窝上
    /// 悄悄跑掉一整集。**只拦本机识别前的那次下载**;发布方官方稿是一个小文本文件,
    /// 与 Android 同一条口径。已下载/已缓存到本地的集压根走不到这里,离线转写照旧。
    var allowsTransfer: (() -> Bool)?

    /// 私有订阅源的 `Authorization`:官方稿与 feed 同主机时才有值。
    /// 由 `AppEnvironment` 注入仓库的 `authHeader(for:)` —— 与音频、feed 走同一个判据,
    /// 不能在这里另写一套主机匹配(见 H253)。
    var authHeaderProvider: ((String) -> String?)?

    /// `nonisolated`: `diskUsageBytes()` 要在后台扫它,而本类整体是 `@MainActor`
    /// (否则 `Self.subdir` 的读取就是一次跨 actor 访问,Swift 6 语言模式下直接报错)。
    nonisolated private static let subdir: URL = {
        let d = AppSupport.dir.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        AppSupport.excludeFromBackup(d)
        return d
    }()

    /// `version` 是**可选**的:v2 之前写出的缓存压根没这个键,缺省按 v1 处理(见 `TranscriptFormat.version`)。
    /// `episodeId` 同样可选,理由一致 —— 补这个字段之前写出的缓存没有它。它存的是**未 sanitize 的原始 id**:
    /// 文件名走 `sanitize`(非字母数字全折 `_` 且截 120),所以 `abc:def` 与 `abc_def` 会落到同一个路径;
    /// 读回时拿这个字段核对归属,对不上就当没缓存(REVIEW-2026-10-25 低·族 A 末尾,三端同改)。
    private struct Cached: Codable { let version: Int?; let localeId: String; let complete: Bool; let segments: [TranscribedSegment]; let episodeId: String? }

    // MARK: - 对外

    /// 切到某单集/语言时调用:取消旧任务,命中缓存则直接显示,否则置 idle 等待用户手动开始。
    /// **async**:缓存解码在后台(实测一份 192 KB,主 actor 上解码是白占主线程)。
    ///
    /// 传整条 `Episode` 而不是 id:待机态要看 `transcriptUrl` 决定——
    /// 有官方稿时说「查看逐字稿」,没有且系统过旧才落到 `needsMacOS26`。
    func prepare(episode: Episode, localeId: String) async {
        guard episode.id != self.episodeId || localeId != self.localeId || state == .idle else { return }
        cancel()
        generation += 1
        let gen = generation
        self.episodeId = episode.id
        self.localeId = localeId
        volatileTail = ""
        segments = []
        state = .loadingCache
        let cached = await loadCache(episodeId: episode.id, localeId: localeId)
        // 解码期间用户可能已经切集/切语言 —— 那时这份结果作废(与鸿蒙同一守卫)
        guard gen == generation else { return }
        if let cached, cached.complete {
            segments = cached.segments   // 缓存命中:秒显全文,不重播打字机
            state = .done
        } else {
            // 有官方稿就永远有活路(下载一个文件,不需要 macOS 26);没有官方稿时才看本机引擎
            state = (episode.transcriptUrl.isEmpty && !Self.localASRAvailable) ? .needsMacOS26 : .idle
        }
    }

    /// 本机离线识别是否可用(Apple Speech 的新接口要 macOS 26)。
    /// 发布方官方稿**不经过**这道门 —— 那只是下载一个文件,所以 14/15 上也能看
    /// (更早的系统没有播放页轮播,整条转录 UI 不出现)。
    static var localASRAvailable: Bool {
        #if os(macOS)
        if #available(macOS 26, *) { return true }
        #else
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }

    /// 手动开始取稿/转录。localURL 有值=已下载(纯离线);否则识别前先下音频。
    func start(episode: Episode, audioURL: String, localURL: URL?, localeId: String) {
        cancel()
        generation += 1
        let gen = generation
        self.episodeId = episode.id
        self.localeId = localeId
        segments = []
        volatileTail = ""
        state = episode.transcriptUrl.isEmpty
            ? (localURL == nil ? .downloadingAudio : .running)
            : .fetchingOfficial

        job = Task { [weak self] in
            await self?.runAny(gen: gen, episode: episode, audioURL: audioURL,
                               localURL: localURL, localeId: localeId)
        }
    }

    /// **先官方稿、后本机识别**(与 Android `TranscriptStore.runJob` 同一条顺序)。
    ///
    /// 官方稿这条路不要求 macOS 26 —— 它只是下载并解析一个文件,所以老系统上
    /// 「有官方稿」的集照样能看;只有真的回退到本机识别时才需要 26。
    private func runAny(gen: Int, episode: Episode, audioURL: String, localURL: URL?, localeId: String) async {
        func stale() -> Bool { gen != generation }

        if !episode.transcriptUrl.isEmpty {
            if !stale() { state = .fetchingOfficial }
            let fetched = await TranscriptFetcher.fetch(url: episode.transcriptUrl,
                                                        declaredType: episode.transcriptType,
                                                        authHeader: authHeaderProvider?(episode.transcriptUrl))
            if stale() { return }
            if let fetched, !fetched.isEmpty {
                // 发布方给的时间轴不能假定排好;出口统一夹一次(硬规矩 10)
                let segs = TranscriptFormat.monotonic(fetched)
                segments = segs
                state = .done
                saveCache(episodeId: episode.id, localeId: localeId, segments: segs)
                Log.i("Transcript", "用官方稿 \(segs.count) 句 id=\(episode.id)")
                return
            }
            // 取不到就往下走本机识别 ——「稿链接坏了」不该让功能整个不可用
            Log.w("Transcript", "官方稿取不到,回退本机识别 id=\(episode.id)")
        }

        #if os(macOS)
        guard #available(macOS 26, *) else {
            if !stale() { state = .needsMacOS26 }
            return
        }
        #else
        guard #available(iOS 26, *) else {
            if !stale() { state = .needsMacOS26 }
            return
        }
        #endif
        await run(gen: gen, episodeId: episode.id, audioURL: audioURL, localURL: localURL, localeId: localeId)
    }

    func cancel() {
        job?.cancel()   // 停止消费 → 事件流 onTermination 取消底层分析
        job = nil
    }

    /// 「清除缓存」:取消在跑的任务、作废当前这几格,并删掉全部已生成的稿。
    ///
    /// **先抬代号再删文件**:在途识别每条语句入库前都会看代号,否则它会在目录清空之后
    /// 把刚生成的那份 `saveCache` 又写回去 —— 用户点了清除,数字却马上又变回来
    /// (与 `AudioCacheManager.clearAll` 同一条顺序)。
    func clearAll() {
        cancel()
        generation += 1
        segments = []
        volatileTail = ""
        state = .idle
        episodeId = ""
        localeId = ""
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Self.subdir.path)) ?? []
        for n in names { try? fm.removeItem(at: Self.subdir.appendingPathComponent(n)) }
        Log.i("Transcript", "clearAll files=\(names.count)")
    }

    /// 已生成稿件的磁盘占用。设置页把它算进缓存总量。
    ///
    /// 写成 **static + nonisolated** 而不是实例方法:本类整体是 `@MainActor`,
    /// 调用方要在 `Task.detached` 里扫目录,捕获一个 `@MainActor` 实例进后台闭包
    /// 在 Swift 6 语言模式下本身就是一次跨 actor 捕获;而这里要的只是那个目录。
    nonisolated static func diskUsageBytes() -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.subdir.path) else { return 0 }
        var total: Int64 = 0
        for n in names {
            let p = Self.subdir.appendingPathComponent(n).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: - 执行

    #if os(macOS)
    @available(macOS 26, *)
    #else
    @available(iOS 26, *)
    #endif
    private func run(gen: Int, episodeId: String, audioURL: String, localURL: URL?, localeId: String) async {
        func stale() -> Bool { gen != generation }

        // 1) 解析可用 locale
        guard let locale = await Transcriber.resolveLocale(preferred: Self.locale(for: localeId)) else {
            if !stale() { state = .unsupportedLocale }
            return
        }

        // 2) 确定本地文件(流式则先下载到临时文件)
        var tempToDelete: URL?
        let fileURL: URL
        if let local = localURL {
            fileURL = local
        } else {
            // 闸门放在这里而不是更上层:只有"要下整集音频"这一支该被拦,
            // 官方稿与本地转写都不该受「仅在 Wi-Fi 下载」影响。
            if let allowsTransfer, !allowsTransfer() {
                Log.w("Transcript", "转录前的音频下载被计费链路闸门拦下 id=\(episodeId)")
                if !stale() {
                    state = .failed(String(localized: "仅 Wi-Fi 下载已开启，切换到 Wi-Fi 后点按重试"))
                }
                return
            }
            guard let remote = URL(string: audioURL) else {
                if !stale() { state = .failed(String(localized: "音频地址无效")) }; return
            }
            do {
                let (tmp, _) = try await URLSession.shared.download(from: remote)
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + remote.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                tempToDelete = dest
                fileURL = dest
            } catch {
                if !stale() { state = .failed(String(localized: "音频下载失败")) }
                return
            }
            if stale() {
                if let t = tempToDelete { try? FileManager.default.removeItem(at: t) }
                return
            }
            state = .running
        }
        defer { if let t = tempToDelete { try? FileManager.default.removeItem(at: t) } }

        // 3) 转录:在 MainActor 上顺序消费事件流,逐句 append(无锁、顺序天然保证)。
        do {
            for try await ev in Transcriber.events(fileURL: fileURL, locale: locale) {
                if stale() { return }
                switch ev {
                case .installingModel:
                    state = .installingModel
                case .volatile(let tail):
                    volatileTail = tail
                    if state != .running { state = .running }
                case .segment(let seg):
                    // **时间轴不变式在入库这一刻保证**(硬规矩 10):渲染侧找当前句用的是
                    // `lastIndex { $0.startMs <= now }`,只在起点单调时才正确。
                    // 每句只夹"新增这一条",下限取上一条的起点 —— 于是整条链一次性有序,
                    // 存进缓存的也已经是收敛后的那份。
                    let floorMs = segments.last?.startMs ?? 0
                    segments.append(TranscriptFormat.monotonic([seg], floor: floorMs)[0])
                    volatileTail = ""   // 该尾巴已定稿并入 segments
                    if state != .running { state = .running }
                }
            }
            if stale() { return }
            volatileTail = ""
            state = .done
            saveCache(episodeId: episodeId, localeId: localeId, segments: segments)
        } catch is CancellationError {
            // 静默:用户切走/取消
        } catch {
            if !stale() { state = .failed(String(localized: "转录失败,点按重试")) }
        }
    }

    // MARK: - 缓存

    private func cacheURL(episodeId: String, localeId: String) -> URL {
        Self.subdir.appendingPathComponent("\(Self.sanitize(episodeId)).\(localeId.isEmpty ? "auto" : localeId).json")
    }
    /// 读缓存:**在后台线程解码**。逐字稿是本 App 最大的一份 JSON
    /// (一集词级稿实测 192 KB,长单集更大),放在主 actor 上解码会让切集卡一下。
    /// 版本校验与时间轴收敛也在这同一个后台任务里做完 —— 于是主线程拿到的已经是可用的那份。
    private func loadCache(episodeId: String, localeId: String) async -> Cached? {
        let url = cacheURL(episodeId: episodeId, localeId: localeId)
        return await Task.detached(priority: .userInitiated) { () -> Cached? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let cached = try? JSONDecoder().decode(Cached.self, from: data) else { return nil }
            // 旧口径的稿**整体作废**(硬规矩 11):界面上看不出这份稿是按哪套算法生成的,
            // 而改了时刻算法之后继续显示旧稿,等于修复没生效,用户也没有清缓存的入口自救。
            if (cached.version ?? 1) < TranscriptFormat.version {
                Log.i("Transcript", "缓存是旧口径(v\(cached.version ?? 1)),丢弃重转")
                return nil
            }
            // 文件名撞车时(两条 id sanitize 后同名),用文件里写的原始 id 辨归属。
            // **缺这个字段的旧缓存照认** —— 那时只可能是自己写的,拦它只会白重转一次。
            if let owner = cached.episodeId, owner != episodeId {
                Log.w("Transcript", "缓存归属不符(文件名撞车),丢弃 id=\(episodeId)")
                return nil
            }
            return Cached(version: TranscriptFormat.version, localeId: cached.localeId,
                          complete: cached.complete,
                          segments: TranscriptFormat.monotonic(cached.segments),
                          episodeId: cached.episodeId)
        }.value
    }

    /// 写缓存:同样在后台编码 + 写盘。segments 是值类型,捕获即快照,不存在数据竞争。
    private func saveCache(episodeId: String, localeId: String, segments: [TranscribedSegment]) {
        let url = cacheURL(episodeId: episodeId, localeId: localeId)
        let c = Cached(version: TranscriptFormat.version, localeId: localeId, complete: true,
                       segments: segments, episodeId: episodeId)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(c) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - locale 映射

    /// UI 语言代码 → 转录期望 Locale。
    static func locale(for id: String) -> Locale {
        switch id {
        case "zh-Hans": return Locale(identifier: "zh-CN")
        case "zh-Hant": return Locale(identifier: "zh-TW")
        case "en": return Locale(identifier: "en-US")
        case "": return Locale.current
        default: return Locale(identifier: id)
        }
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }).prefix(120).description
    }
}
