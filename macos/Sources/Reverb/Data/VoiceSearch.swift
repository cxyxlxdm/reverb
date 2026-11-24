import Foundation
import AVFoundation
import Speech

/// 语音搜索:录一小段麦克风音频到临时文件 → 交给本机 `Transcriber`(SpeechAnalyzer)识别 → 删录音。
///
/// 交互是「点一下开始、再点一下结束」:第一下起录音,第二下停止并识别,识别结果回给调用方
/// 填进搜索框。**整条链路都在设备上**,与逐字稿共用同一条底座;录音只活在
/// `NSTemporaryDirectory()`,识别完立刻删除,不写进任何 store,也不进备份。
///
/// 门槛与逐字稿相同:SpeechAnalyzer 要 iOS 26 / macOS 26。低于这个版本 [isSupported] 为 false,
/// 界面据此不摆麦克风按钮(而不是点了才失败)。
@MainActor
final class VoiceSearchController: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        /// 已停止录音,正在跑识别
        case transcribing
    }

    enum StartResult {
        case started
        case permissionDenied
        case unsupported
        case failed
    }

    @Published private(set) var state: State = .idle

    private var recorder: AVAudioRecorder?
    private var tempURL: URL?

    static var isSupported: Bool {
        if #available(macOS 26, iOS 26, *) { return true }
        return false
    }

    /// 起录音。权限被拒 / 录音器起不来时回落到 idle 并如实返回原因。
    func start() async -> StartResult {
        guard state == .idle else { return .failed }
        guard Self.isSupported else { return .unsupported }
        guard await Self.requestMicPermission() else { return .permissionDenied }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-search-\(UUID().uuidString).wav")
        // 16 kHz / 单声道 / 16-bit PCM:与 SenseVoice 那侧的目标格式一致,
        // 也是 SpeechAnalyzer 读取最省事的一档。
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            #endif
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else {
                Self.endSession()
                try? FileManager.default.removeItem(at: url)
                return .failed
            }
            recorder = rec
            tempURL = url
            state = .recording
            Log.i("Voice", "开始录音 \(url.lastPathComponent)")
            return .started
        } catch {
            Self.endSession()
            try? FileManager.default.removeItem(at: url)
            Log.w("Voice", "录音器启动失败:\(error.localizedDescription)")
            return .failed
        }
    }

    /// 停止并识别。返回识别文本;**nil 表示没识别出内容或当前语言不支持**(界面提示重试)。
    func stopAndTranscribe(locale: Locale) async -> String? {
        guard state == .recording, let rec = recorder, let url = tempURL else { return nil }
        rec.stop()
        recorder = nil
        tempURL = nil
        Self.endSession()
        state = .transcribing
        defer {
            try? FileManager.default.removeItem(at: url)
            state = .idle
        }
        guard #available(macOS 26, iOS 26, *) else { return nil }
        guard let resolved = await Transcriber.resolveLocale(preferred: locale) else {
            Log.w("Voice", "当前语言没有可用的本机识别 locale=\(locale.identifier)")
            return nil
        }
        var text = ""
        do {
            for try await ev in Transcriber.events(fileURL: url, locale: resolved) {
                if case .segment(let s) = ev { text += s.text }
            }
        } catch {
            Log.w("Voice", "识别失败:\(error.localizedDescription)")
            return nil
        }
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.i("Voice", "识别完成 字=\(q.count)")
        return q.isEmpty ? nil : q
    }

    /// 放弃这次录音(界面关闭 / 视图消失)。不识别、不留文件。
    func cancel() {
        recorder?.stop()
        recorder = nil
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        tempURL = nil
        Self.endSession()
        state = .idle
    }

    private static func requestMicPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return false
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    /// 收掉录音会话并把播放类目还回去 —— 否则播放器再出声时会落在 `.record` 上而静音。
    private static func endSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .spokenAudio)
        #endif
    }
}
