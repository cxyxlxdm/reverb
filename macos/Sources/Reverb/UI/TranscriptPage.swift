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

    /// 转录语言:中文 / 英文(默认跟随界面语言,空=未定)。
    @State private var localeChoice: String = ""

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
        .task(id: episode.id + "|" + localeChoice) {
            if localeChoice.isEmpty { localeChoice = defaultLocaleId(); return } // 定语言后本 task 会以新 id 再跑
            transcripts.prepare(episodeId: episode.id, localeId: localeChoice)
        }
    }

    // MARK: - 头部:标题 + 语言切换

    private var header: some View {
        HStack {
            Text("转录").font(.headline)
            Spacer()
            Picker("", selection: $localeChoice) {
                Text("中文").tag("zh-Hans")
                Text(verbatim: "English").tag("en")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
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

    private func transcriptList(runningTail: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(transcripts.segments.enumerated()), id: \.offset) { idx, seg in
                        Text(seg.text)
                            .font(.body)
                            .foregroundStyle(idx == currentIndex ? accent : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(toMs: seg.startMs) }
                            .id(idx)
                    }
                    if runningTail {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在识别…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
            .onChange(of: currentIndex) { _, new in
                if let new { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    // MARK: - 动作

    private func startTranscription() {
        transcripts.start(
            episodeId: episode.id,
            audioURL: episode.audioUrl,
            localURL: env.downloads.localURL(episode.id),
            localeId: localeChoice)
    }

    /// 依界面语言给转录默认语言。
    private func defaultLocaleId() -> String {
        switch env.settings.language {
        case "en", "fr", "es": return "en"
        case "zh-Hans", "zh-Hant": return "zh-Hans"
        default:
            return (Locale.current.language.languageCode?.identifier == "zh") ? "zh-Hans" : "en"
        }
    }
}
