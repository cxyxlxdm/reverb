import Foundation

/// 「转录」状态机与缓存。每单集 × 每语言各存一份 JSON 到
/// ~/Library/Application Support/Reverb/Transcripts/,命中缓存秒显。
/// 转录本身走 Transcriber(仅 macOS 26,完全设备端)。
@MainActor final class TranscriptStore: ObservableObject {

    enum State: Equatable {
        case idle              // 未转录:显示"生成转录"
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

    private struct Cached: Codable { let localeId: String; let complete: Bool; let segments: [TranscribedSegment] }

    // MARK: - 对外

    /// 切到某单集/语言时调用:取消旧任务,命中缓存则直接显示,否则置 idle 等待用户手动生成。
    func prepare(episodeId: String, localeId: String) {
        guard episodeId != self.episodeId || localeId != self.localeId || state == .idle else { return }
        cancel()
        generation += 1
        self.episodeId = episodeId
        self.localeId = localeId
        volatileTail = ""
        if let cached = loadCache(episodeId: episodeId, localeId: localeId), cached.complete {
            segments = cached.segments   // 缓存命中:秒显全文,不重播打字机
            state = .done
        } else {
            segments = []
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
                    segments.append(seg)
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
    private func loadCache(episodeId: String, localeId: String) -> Cached? {
        guard let data = try? Data(contentsOf: cacheURL(episodeId: episodeId, localeId: localeId)) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }
    private func saveCache(episodeId: String, localeId: String, segments: [TranscribedSegment]) {
        let c = Cached(localeId: localeId, complete: true, segments: segments)
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: cacheURL(episodeId: episodeId, localeId: localeId), options: .atomic)
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
