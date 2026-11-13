import SwiftUI

/// 播放页「转录」轮播页:离线把当前单集音频转成文字,随播放高亮、点句跳转。
/// 仅从 macOS 14+ 的轮播容器实例化;发布方官方稿在这一档就能用,
/// 本机识别才进一步要求 macOS 26(`TranscriptStore.localASRAvailable`)。
@available(macOS 14, *)
struct TranscriptPage: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var transcripts: TranscriptStore

    let episode: Episode
    let accent: Color
    var active: Bool = true   // 是否为当前可见页;false 时当前句静态显示,不跑逐帧刷新

    // 平滑外推的锚点:播放进度每 0.5s 才更新一次,靠这对锚点在两次采样间逐帧插值,
    // 让当前句逐字推进而非半秒一跳。
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

    /// 转录语言按应用界面语言确定(一段音频通常只有一种语言,不做手动切换)。
    private var localeId: String {
        switch env.settings.language {
        case "en", "fr", "es": return "en"
        case "zh-Hant": return "zh-Hant"
        case "zh-Hans": return "zh-Hans"
        default: return (Locale.current.language.languageCode?.identifier == "zh") ? "zh-Hans" : "en"
        }
    }

    /// 当前播放位置对应的句子下标。
    private var currentIndex: Int? {
        transcripts.segments.lastIndex(where: { $0.startMs <= player.positionMs })
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .task(id: episode.id + "|" + localeId) {
            await transcripts.prepare(episode: episode, localeId: localeId)
        }
        // 每次播放进度采样(约 0.5s)刷新锚点,当前句据此逐帧外推
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

    // MARK: - 头部

    private var header: some View {
        Group {
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
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("搜索逐字稿"))
                    if textFile != nil || markdownFile != nil {
                        TranscriptExportMenu(textFile: textFile, markdownFile: markdownFile)
                    }
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

    // MARK: - 主体(按状态)

    /// 不再用 `if #available(macOS 26)` 把整页包住:发布方官方稿只是下载并解析一个文件,
    /// 14–15 上同样可用。要不要 26 由 `TranscriptStore` 的状态决定(`needsMacOS26`)。
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
            hint("exclamationmark.triangle", "需要 macOS 26")
        }
        Spacer(minLength: 0)
    }

    private var startPrompt: some View {
        let official = !episode.transcriptUrl.isEmpty
        // 两类稿**要说不同的话**:官方稿只是下载一个文件(一两秒),本机识别是几分钟的满载计算。
        let title: LocalizedStringKey = official ? "这一集发布方提供了逐字稿" : "把这集音频离线转成文字"
        let action: LocalizedStringKey = official ? "查看逐字稿" : "生成转录"
        return VStack(spacing: 14) {
            Spacer()
            Image(systemName: official ? "doc.text" : "text.viewfinder")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.callout).foregroundStyle(.secondary)
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

    /// 单句渲染:当前句逐字打字机高亮(KaraokeLine 逐帧外推),已读句变暗,未读句正常。
    /// 搜索命中那一段在两种分支里都贴同一块底色 —— 底色与逐字高亮是两个维度,可以共存。
    @ViewBuilder private func row(idx: Int, seg: TranscribedSegment) -> some View {
        let cur = currentIndex
        let marks = searchResult.rangesByIndex[idx] ?? []
        let markColor = Color.primary.opacity(0.20)
        Group {
            if idx == cur {
                KaraokeLine(seg: seg, accent: accent,
                            anchorMs: anchorMs, anchorAt: anchorAt,
                            speed: player.speed, isPlaying: player.isPlaying && active,
                            marks: marks, markColor: markColor)
            } else if marks.isEmpty {
                Text(seg.text).foregroundColor(idx < (cur ?? -1) ? .secondary : .primary)
            } else {
                Text(Self.marked(seg.text, marks, color: markColor))
                    .foregroundColor(idx < (cur ?? -1) ? .secondary : .primary)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(transcripts.segments.enumerated()), id: \.offset) { idx, seg in
                        row(idx: idx, seg: seg)
                    }
                    if runningTail {
                        // 未定稿的实时尾巴(流式/打字机):淡色显示,定稿后并入上面的句子
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
            // 播放时:滚到当前句;生成时:滚到底部让流式尾巴始终可见
            .onChange(of: currentIndex) { _, new in
                if !runningTail, autoFollow, let new { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) } }
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

    // MARK: - 动作

    private func startTranscription() {
        transcripts.start(
            episode: episode,
            audioURL: episode.audioUrl,
            localURL: env.downloads.localURL(episode.id),
            localeId: localeId)
    }
}

/// 当前句的逐字打字机高亮。播放进度只有 0.5s 一跳,这里用 TimelineView 逐帧外推出
/// 平滑毫秒,再按预铺的「每字符时间线」逐字点亮 —— 有词级时间按词分摊,无则整句均分,
/// 因此老缓存(无词级时间)同样得到逐字效果。只有当前一行用逐帧刷新,其余行静态,开销可控。
@available(macOS 14, *)
private struct KaraokeLine: View {
    let accent: Color
    let anchorMs: Int
    let anchorAt: Date
    let speed: Double
    let isPlaying: Bool
    var marks: [Range<Int>] = []
    var markColor: Color = .clear

    private let fullText: String
    private let charEndMs: [Int]   // 每个字符「读到」的毫秒(升序)
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
            reveal(at: anchorMs)   // 暂停时不跑逐帧,按锚点静态显示
        }
    }

    /// 由 0.5s 一跳的进度外推平滑毫秒;封顶到本句结束,避免抢跑到下一句。
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

    /// 生成 (整句文本, 每字符结束毫秒)。词级时间→按词区间线性分摊到字符;
    /// 无词级时间(老缓存/整句)→整句 [startMs,endMs] 均分到字符,同样逐字。
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
