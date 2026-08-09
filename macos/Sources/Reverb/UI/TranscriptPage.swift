import SwiftUI

/// 播放页「转录」轮播页:离线把当前单集音频转成文字,随播放高亮、点句跳转。
/// 仅从 macOS 14+ 的轮播容器实例化;转录能力本身进一步要求 macOS 26。
@available(macOS 14, *)
struct TranscriptPage: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var transcripts: TranscriptStore

    let episode: Episode
    let accent: Color

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
            transcripts.prepare(episodeId: episode.id, localeId: localeId)
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

    @ViewBuilder private var content: some View {
        if #available(macOS 26, *) {
            switch transcripts.state {
            case .idle:
                startPrompt
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
        } else {
            hint("exclamationmark.triangle", "需要 macOS 26")
        }
        Spacer(minLength: 0)
    }

    private var startPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "text.viewfinder").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("把这集音频离线转成文字").font(.callout).foregroundStyle(.secondary)
            Button("生成转录") { startTranscription() }
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

    /// 单句渲染:当前句做词级卡拉OK(已读到的词用强调色),已读句变暗,未读句正常。
    private func lineView(idx: Int, seg: TranscribedSegment) -> Text {
        let cur = currentIndex
        if idx == cur, let words = seg.words, !words.isEmpty {
            return words.reduce(Text("")) { acc, w in
                acc + Text(w.text).foregroundColor(player.positionMs >= w.startMs ? accent : .primary)
            }
        }
        let color: Color = idx == cur ? accent : (idx < (cur ?? -1) ? .secondary : .primary)
        return Text(seg.text).foregroundColor(color)
    }

    private func transcriptList(runningTail: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(transcripts.segments.enumerated()), id: \.offset) { idx, seg in
                        lineView(idx: idx, seg: seg)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(toMs: seg.startMs) }
                            .id(idx)
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
            episodeId: episode.id,
            audioURL: episode.audioUrl,
            localURL: env.downloads.localURL(episode.id),
            localeId: localeId)
    }
}
