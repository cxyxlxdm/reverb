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
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text("转录").font(.headline)
            Spacer()
        }
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
    @ViewBuilder private func row(idx: Int, seg: TranscribedSegment) -> some View {
        let cur = currentIndex
        Group {
            if idx == cur {
                KaraokeLine(seg: seg, accent: accent,
                            anchorMs: anchorMs, anchorAt: anchorAt,
                            speed: player.speed, isPlaying: player.isPlaying && active)
            } else {
                Text(seg.text).foregroundColor(idx < (cur ?? -1) ? .secondary : .primary)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { player.seek(toMs: seg.startMs) }
        .id(idx)
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
                if !runningTail, let new { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) } }
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

    private let fullText: String
    private let charEndMs: [Int]   // 每个字符「读到」的毫秒(升序)
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
    private func reveal(at ms: Int) -> Text {
        var n = 0
        while n < charEndMs.count && charEndMs[n] <= ms { n += 1 }
        let chars = Array(fullText)
        let done = String(chars[0..<min(n, chars.count)])
        let rest = String(chars[min(n, chars.count)...])
        return Text(done).foregroundColor(accent) + Text(rest).foregroundColor(.primary)
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
