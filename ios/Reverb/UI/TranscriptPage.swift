import SwiftUI

/// 播放页「逐字稿」sheet:优先发布方官方稿,没有时在本机离线转写。
/// 与 macOS 版同一套 `TranscriptStore` 状态机;差别只有系统版本门槛写 iOS。
struct TranscriptPage: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var transcripts: TranscriptStore

    let episode: Episode
    let accent: Color
    var active: Bool = true

    // 进度每 0.5s 一跳,靠这对锚点在两次采样之间逐帧外推,当前句才会逐字推进。
    @State private var anchorMs: Int = 0
    @State private var anchorAt: Date = Date()

    // 全文搜索。匹配结果在**状态变化时**算一次(硬规矩 6),渲染只按句下标查表。
    @State private var searching = false
    @State private var query = ""
    @State private var cursor = 0
    @State private var searchResult = TranscriptSearch.empty
    /// 搜索把某句滚到眼前:由这一步触发列表滚动,而不是在计算里直接碰 ScrollViewProxy。
    @State private var scrollTarget: Int?

    // 导出用的临时文件。稿子就绪时写一次,不在渲染路径里做 IO。
    @State private var textFile: URL?
    @State private var markdownFile: URL?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 搜索且有关键词时不自动跟读 —— 否则播放每两句就把用户从命中处拽走。
    private var autoFollow: Bool { !(searching && !trimmedQuery.isEmpty) }

    private var localeId: String {
        switch env.settings.language {
        case "en", "fr", "es": return "en"
        case "zh-Hant": return "zh-Hant"
        case "zh-Hans": return "zh-Hans"
        default: return (Locale.current.language.languageCode?.identifier == "zh") ? "zh-Hans" : "en"
        }
    }

    private var currentIndex: Int? {
        transcripts.segments.lastIndex(where: { $0.startMs <= player.positionMs })
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .task(id: episode.id + "|" + localeId) {
            await transcripts.prepare(episode: episode, localeId: localeId)
        }
        .onChange(of: player.positionMs) { _, new in
            anchorMs = new
            anchorAt = Date()
        }
        // 稿子变了(流式追加 / 换集)就重算一次命中;关键词没变时命中位置会随后移,必须跟着重算
        .onChange(of: transcripts.segments) { _, segs in
            refreshSearch(segs)
            prepareShareFiles(segs)
        }
        .task(id: episode.id) { prepareShareFiles(transcripts.segments) }
    }

    @ViewBuilder private var header: some View {
        if searching {
            TranscriptFindBar(
                query: $query,
                count: searchResult.hits.count,
                cursor: cursor,
                onPrev: { step(-1) },
                onNext: { step(1) },
                onCancel: closeSearch)
        } else {
            HStack {
                Text("转录").font(.headline)
                Spacer()
                Button {
                    searching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(Text("搜索逐字稿"))
                if textFile != nil || markdownFile != nil {
                    TranscriptExportMenu(textFile: textFile, markdownFile: markdownFile)
                }
            }
        }
    }

    // MARK: - 搜索与导出

    private func refreshSearch(_ segments: [TranscribedSegment]) {
        searchResult = TranscriptSearch.find(segments: segments, query: trimmedQuery)
        cursor = 0
        if let first = searchResult.hits.first { scrollTarget = first.index }
    }

    private func step(_ delta: Int) {
        let hits = searchResult.hits
        guard !hits.isEmpty else { return }
        cursor = ((cursor + delta) % hits.count + hits.count) % hits.count
        let hit = hits[cursor]
        scrollTarget = hit.index
        // 上一处 / 下一处是**跳转**:与 Android 一致,点一下就把播放头挪到那句开头
        if hit.index < transcripts.segments.count {
            player.seek(toMs: transcripts.segments[hit.index].startMs)
        }
    }

    private func closeSearch() {
        searching = false
        query = ""
        cursor = 0
        searchResult = TranscriptSearch.empty
    }

    /// 两种格式各写一份临时文件交给系统分享面板。稿子每追加一句会调一次 ——
    /// 但只在**流式识别**期间发生,且一集顶多几十 KB,不构成渲染路径负担。
    private func prepareShareFiles(_ segments: [TranscribedSegment]) {
        guard !segments.isEmpty else {
            textFile = nil
            markdownFile = nil
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reverb-transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ format: TranscriptExport.Format) -> URL? {
            let url = dir.appendingPathComponent(TranscriptExport.fileName(episode: episode, format: format))
            let body = TranscriptExport.build(episode: episode, segments: segments, format: format)
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch {
                Log.w("Transcript", "导出文件写失败:\(error.localizedDescription)")
                return nil
            }
        }
        textFile = write(.text)
        markdownFile = write(.markdown)
    }

    @ViewBuilder private var content: some View {
        switch transcripts.state {
        case .idle:
            startPrompt
        case .loadingCache:
            progress("正在读取…")
        case .fetchingOfficial:
            progress("正在获取发布方提供的逐字稿…")
        case .downloadingAudio:
            progress("正在准备音频…")
        case .installingModel:
            progress("正在下载语言模型…")
        case .running:
            transcriptList(runningTail: true)
        case .done:
            transcriptList(runningTail: false)
        case .failed(let msg):
            retry(msg)
        case .unsupportedLocale:
            hint("magnifyingglass", "该语言暂不支持转录")
        case .needsMacOS26:
            hint("exclamationmark.triangle", "需要 iOS 26")
        }
        Spacer(minLength: 0)
    }

    private var startPrompt: some View {
        let official = !episode.transcriptUrl.isEmpty
        let title: LocalizedStringKey = official ? "这一集发布方提供了逐字稿" : "把这集音频离线转成文字"
        let action: LocalizedStringKey = official ? "查看逐字稿" : "生成转录"
        return VStack(spacing: 14) {
            Spacer()
            Image(systemName: official ? "doc.text" : "text.viewfinder")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action) { startTranscription() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func progress(_ text: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func retry(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(.orange)
            Text(msg).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试") { startTranscription() }.buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func hint(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func row(idx: Int, seg: TranscribedSegment, current: Int?) -> some View {
        let marks = searchResult.rangesByIndex[idx] ?? []
        let markColor = Color.primary.opacity(0.20)
        Group {
            if idx == current {
                KaraokeLine(seg: seg, accent: accent,
                            anchorMs: anchorMs, anchorAt: anchorAt,
                            speed: player.speed, isPlaying: player.isPlaying && active,
                            marks: marks, markColor: markColor)
            } else if marks.isEmpty {
                Text(seg.text).foregroundColor(idx < (current ?? -1) ? .secondary : .primary)
            } else {
                Text(Self.marked(seg.text, marks, color: markColor))
                    .foregroundColor(idx < (current ?? -1) ? .secondary : .primary)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { player.seek(toMs: seg.startMs) }
        .id(idx)
    }

    /// 把命中区间贴到底色上。区间是**字符下标**(见 `TranscriptSearch`),这里的切片单位也是 Character。
    static func marked(_ text: String, _ ranges: [Range<Int>], color: Color) -> AttributedString {
        var a = AttributedString(text)
        let chars = a.characters
        for r in ranges {
            let lower = max(0, min(r.lowerBound, text.count))
            let upper = max(lower, min(r.upperBound, text.count))
            guard upper > lower else { continue }
            let lo = chars.index(chars.startIndex, offsetBy: lower)
            let hi = chars.index(chars.startIndex, offsetBy: upper)
            a[lo..<hi].backgroundColor = color
        }
        return a
    }

    private func transcriptList(runningTail: Bool) -> some View {
        // 当前句整表只算一次:每个可见行各算一遍就是 O(可见行 × 总句数),
        // 长稿每 0.5s 都会重跑(硬规矩 6 / H137 同一条乘法)。
        let current = currentIndex
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(transcripts.segments.enumerated()), id: \.offset) { idx, seg in
                        row(idx: idx, seg: seg, current: current)
                    }
                    if runningTail {
                        if !transcripts.volatileTail.isEmpty {
                            Text(transcripts.volatileTail)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在识别…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        .id("tail")
                    }
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
            .onChange(of: currentIndex) { _, new in
                if !runningTail, autoFollow, let new {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
            // 搜索跳到某一处:列表滚过去。置回 nil 是为了同一句连点两次也能再滚一次。
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
            }
            .onChange(of: transcripts.segments.count) { _, _ in
                if runningTail { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("tail", anchor: .bottom) } }
            }
            .onChange(of: transcripts.volatileTail) { _, _ in
                if runningTail { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    private func startTranscription() {
        transcripts.start(
            episode: episode,
            audioURL: episode.audioUrl,
            localURL: env.downloads.localURL(episode.id),
            localeId: localeId)
    }
}

/// 当前句逐字高亮:进度只有 0.5s 一跳,这里逐帧外推,按预铺的字符时间线点亮。
private struct KaraokeLine: View {
    let accent: Color
    let anchorMs: Int
    let anchorAt: Date
    let speed: Double
    let isPlaying: Bool
    var marks: [Range<Int>] = []
    var markColor: Color = .clear

    private let fullText: String
    private let charEndMs: [Int]
    private let segEndMs: Int

    init(seg: TranscribedSegment, accent: Color, anchorMs: Int, anchorAt: Date, speed: Double, isPlaying: Bool,
         marks: [Range<Int>] = [], markColor: Color = .clear) {
        self.accent = accent
        self.anchorMs = anchorMs
        self.anchorAt = anchorAt
        self.speed = max(0.1, speed)
        self.isPlaying = isPlaying
        self.marks = marks
        self.markColor = markColor
        let (t, times) = Self.timeline(seg)
        self.fullText = t
        self.charEndMs = times
        self.segEndMs = max(seg.endMs, seg.startMs)
    }

    var body: some View {
        if isPlaying {
            TimelineView(.animation) { ctx in
                reveal(at: clampedMs(for: ctx.date))
            }
        } else {
            reveal(at: anchorMs)
        }
    }

    private func clampedMs(for date: Date) -> Int {
        let dt = date.timeIntervalSince(anchorAt)
        let extra = dt > 0 ? Int(dt * 1000 * speed) : 0
        return min(anchorMs + extra, segEndMs)
    }

    /// 已读到的字符用强调色,未读的用主色。
    ///
    /// 搜索命中时改走 `AttributedString`:底色和逐字前景色是两种不同的属性,
    /// 而 `Text + Text` 的拼接只支持前景色。每帧重建的只是一句(几十个字符),开销可控。
    private func reveal(at ms: Int) -> Text {
        var n = 0
        while n < charEndMs.count && charEndMs[n] <= ms { n += 1 }
        let chars = Array(fullText)
        let read = min(n, chars.count)
        if marks.isEmpty {
            let done = String(chars[0..<read])
            let rest = String(chars[read...])
            return Text(done).foregroundColor(accent) + Text(rest).foregroundColor(.primary)
        }
        var a = AttributedString(fullText)
        a.foregroundColor = .primary
        let idx = a.characters
        for r in marks {
            let lower = max(0, min(r.lowerBound, chars.count))
            let upper = max(lower, min(r.upperBound, chars.count))
            guard upper > lower else { continue }
            let lo = idx.index(idx.startIndex, offsetBy: lower)
            let hi = idx.index(idx.startIndex, offsetBy: upper)
            a[lo..<hi].backgroundColor = markColor
        }
        if read > 0 {
            let hi = idx.index(idx.startIndex, offsetBy: read)
            a[..<hi].foregroundColor = accent
        }
        return Text(a)
    }

    static func timeline(_ seg: TranscribedSegment) -> (String, [Int]) {
        if let words = seg.words, !words.isEmpty {
            var text = ""
            var times: [Int] = []
            for w in words {
                let cs = Array(w.text)
                guard !cs.isEmpty else { continue }
                let span = max(0, w.endMs - w.startMs)
                for i in 0..<cs.count {
                    text.append(cs[i])
                    let frac = Double(i + 1) / Double(cs.count)
                    times.append(w.startMs + Int(Double(span) * frac))
                }
            }
            if !times.isEmpty { return (text, times) }
        }
        let cs = Array(seg.text)
        let span = max(0, seg.endMs - seg.startMs)
        var times: [Int] = []
        times.reserveCapacity(cs.count)
        for i in 0..<cs.count {
            let frac = Double(i + 1) / Double(cs.count)
            times.append(seg.startMs + Int(Double(span) * frac))
        }
        return (seg.text, times)
    }
}