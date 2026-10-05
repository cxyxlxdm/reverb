import Foundation

/// 逐字稿的**缓存口径与时间轴不变式**。
///
/// 为什么写在类外:`TranscriptStore` 是 `@MainActor`,而它的缓存解码刻意搬到后台线程
/// (一份词级稿实测 192 KB,主线程解码会让切集卡一下)。校验版本与夹单调这两步
/// 要跟着解码一起在后台跑完,所以它们不能是 MainActor 的成员。
/// 与 Android `TranscriptStore.CACHE_VERSION` / 鸿蒙 `TranscriptStore.CACHE_VERSION` 同值同义。
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
        case idle              // 未转录:显示"生成转录"
        /// 正在读本机缓存。解码搬到后台之后不再是同一帧出结果,
        /// 这几十毫秒若沿用 idle 会**闪一下「生成转录」按钮**。与鸿蒙的 LoadingCache 对齐。
        case loadingCache
        case downloadingAudio  // 流式单集:先下载音频
        case installingModel   // 首次:系统下载语言模型
        case running           // 识别中
        case done              // 完成(或命中缓存)
        case failed(String)
        case unsupportedLocale // 该语言不受支持
        case needsMacOS26      // 系统过旧
    }

    @Published private(set) var segments: [TranscribedSegment] = []
    @Published private(set) var volatileTail: String = ""   // 生成期未定稿的实时尾巴;缓存命中为空
    @Published private(set) var state: State = .idle
    @Published private(set) var episodeId: String = ""
    @Published private(set) var localeId: String = ""

    private var generation = 0
    private var job: Task<Void, Never>?

    private static let subdir: URL = {
        let d = AppSupport.dir.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// `version` 是**可选**的:v2 之前写出的缓存压根没这个键,缺省按 v1 处理(见 `TranscriptFormat.version`)。
    private struct Cached: Codable { let version: Int?; let localeId: String; let complete: Bool; let segments: [TranscribedSegment] }

    // MARK: - 对外

    /// 切到某单集/语言时调用:取消旧任务,命中缓存则直接显示,否则置 idle 等待用户手动生成。
    /// **async**:缓存解码在后台(实测一份 192 KB,主 actor 上解码是白占主线程)。
    func prepare(episodeId: String, localeId: String) async {
        guard episodeId != self.episodeId || localeId != self.localeId || state == .idle else { return }
        cancel()
        generation += 1
        let gen = generation
        self.episodeId = episodeId
        self.localeId = localeId
        volatileTail = ""
        segments = []
        state = .loadingCache
        let cached = await loadCache(episodeId: episodeId, localeId: localeId)
        // 解码期间用户可能已经切集/切语言 —— 那时这份结果作废(与鸿蒙同一守卫)
        guard gen == generation else { return }
        if let cached, cached.complete {
            segments = cached.segments   // 缓存命中:秒显全文,不重播打字机
            state = .done
        } else {
            state = .idle
        }
    }

    /// 手动开始转录。localURL 有值=已下载(纯离线);否则用远程直链先下载音频。
    func start(episodeId: String, audioURL: String, localURL: URL?, localeId: String) {
        guard #available(macOS 26, *) else { state = .needsMacOS26; return }
        cancel()
        generation += 1
        let gen = generation
        self.episodeId = episodeId
        self.localeId = localeId
        segments = []
        volatileTail = ""
        state = localURL == nil ? .downloadingAudio : .running

        job = Task { [weak self] in
            await self?.run(gen: gen, episodeId: episodeId, audioURL: audioURL, localURL: localURL, localeId: localeId)
        }
    }

    func cancel() {
        job?.cancel()   // 停止消费 → 事件流 onTermination 取消底层分析
        job = nil
    }

    // MARK: - 执行

    @available(macOS 26, *)
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
            return Cached(version: TranscriptFormat.version, localeId: cached.localeId,
                          complete: cached.complete,
                          segments: TranscriptFormat.monotonic(cached.segments))
        }.value
    }

    /// 写缓存:同样在后台编码 + 写盘。segments 是值类型,捕获即快照,不存在数据竞争。
    private func saveCache(episodeId: String, localeId: String, segments: [TranscribedSegment]) {
        let url = cacheURL(episodeId: episodeId, localeId: localeId)
        let c = Cached(version: TranscriptFormat.version, localeId: localeId, complete: true, segments: segments)
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
