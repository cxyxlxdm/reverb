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
            HStack {
                Text("转录").font(.headline)
                Spacer()
            }
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
        Group {
            if idx == current {
                KaraokeLine(seg: seg, accent: accent,
                            anchorMs: anchorMs, anchorAt: anchorAt,
                            speed: player.speed, isPlaying: player.isPlaying && active)
            } else {
                Text(seg.text).foregroundColor(idx < (current ?? -1) ? .secondary : .primary)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { player.seek(toMs: seg.startMs) }
        .id(idx)
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
                if !runningTail, let new {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
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

    private let fullText: String
    private let charEndMs: [Int]
    private let segEndMs: Int

    init(seg: TranscribedSegment, accent: Color, anchorMs: Int, anchorAt: Date, speed: Double, isPlaying: Bool) {
        self.accent = accent
        self.anchorMs = anchorMs
        self.anchorAt = anchorAt
        self.speed = max(0.1, speed)
        self.isPlaying = isPlaying
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

    private func reveal(at ms: Int) -> Text {
        var n = 0
        while n < charEndMs.count && charEndMs[n] <= ms { n += 1 }
        let chars = Array(fullText)
        let done = String(chars[0..<min(n, chars.count)])
        let rest = String(chars[min(n, chars.count)...])
        return Text(done).foregroundColor(accent) + Text(rest).foregroundColor(.primary)
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