import Foundation
import AVFoundation
import Speech

/// 词级时间(卡拉OK同步)。text 为该 run 的原始子串(含原有空格),拼接可还原整句。
struct TranscribedWord: Sendable, Codable, Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
}

/// 一句转录结果:文本 + 起止毫秒(用于按播放进度高亮)。
/// words 为词级时间;老缓存无此字段时为 nil,回退整句高亮。
struct TranscribedSegment: Sendable, Codable, Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
    var words: [TranscribedWord]? = nil
}

/// 离线语音转文字封装,基于系统 26 的 SpeechAnalyzer / SpeechTranscriber。
/// 完全设备端:音频不外传;语言模型由系统按语言首次下载一次(之后离线)。
/// 一律以「本地文件」为输入(已下载单集用本地路径;流式单集由上层先下载到临时文件)。
///
/// 同一份源码被 macOS 与 iOS 两个 target 编译;两端的门槛年份相同、平台名不同,
/// 所以可用性标注必须分开写 —— 写成 `@available(macOS 26, *)` 时 iOS 侧会被理解成
/// 「iOS 任意版本都可用」,而音频分析 API 其实要 iOS 26。
#if os(macOS)
@available(macOS 26, *)
#else
@available(iOS 26, *)
#endif
enum Transcriber {

    /// 转录过程事件。
    enum Event: Sendable {
        case installingModel                 // 首次:系统下载语言模型
        case volatile(String)                // 未定稿的实时尾巴(打字机/流式效果)
        case segment(TranscribedSegment)     // 定稿一句(按时间顺序)
    }

    /// 为期望语言挑一个受支持的 locale;挑不到返回 nil。
    static func resolveLocale(preferred: Locale) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let wantTag = preferred.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == wantTag }) { return exact }
        let wantLang = preferred.language.languageCode?.identifier
        if let byLang = supported.first(where: { $0.language.languageCode?.identifier == wantLang }) { return byLang }
        return nil
    }

    /// 转录本地音频文件,以事件流增量吐出。取消消费方即终止分析。
    static func events(fileURL: URL, locale: Locale) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcriber = SpeechTranscriber(
                        locale: locale, transcriptionOptions: [],
                        reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])

                    // 确保语言模型已安装(nil = 已装)。系统级、一次性。
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        continuation.yield(.installingModel)
                        try await request.downloadAndInstall()
                    }

                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    // 先起消费再喂音频,避免漏结果。
                    let consume = Task {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            if result.isFinal {
                                let start = ms(result.range.start.seconds)
                                // 词级时间:从 AttributedString 各 run 的 audioTimeRange 提取
                                var words: [TranscribedWord] = []
                                for run in result.text.runs {
                                    guard let tr = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
                                    let w = String(result.text[run.range].characters)
                                    guard !w.isEmpty else { continue }
                                    let ws = ms(tr.start.seconds)
                                    words.append(TranscribedWord(text: w, startMs: ws, endMs: max(ms(tr.end.seconds), ws)))
                                }
                                continuation.yield(.segment(TranscribedSegment(
                                    text: text, startMs: start, endMs: max(ms(result.range.end.seconds), start),
                                    words: words.isEmpty ? nil : words)))
                            } else {
                                continuation.yield(.volatile(text))   // 未定稿:实时尾巴
                            }
                        }
                    }
                    do {
                        let file = try AVAudioFile(forReading: fileURL)
                        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                        try await consume.value
                        continuation.finish()
                    } catch {
                        consume.cancel()
                        await analyzer.cancelAndFinishNow()
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func ms(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}
