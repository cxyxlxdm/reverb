import Foundation
import AVFoundation
import Combine

/// 播放门面:AVPlayer 播放 + 队列上下文(上/下一集)+ 随机电台 + 睡眠定时 + 音频淡入淡出。
/// 与 Android 版 PlayerController 行为对齐。
@MainActor
final class PlayerController: ObservableObject {

    @Published private(set) var current: Episode?
    @Published private(set) var isPlaying = false
    @Published private(set) var positionMs: Int = 0
    @Published private(set) var durationMs: Int = 0
    @Published private(set) var buffering = false
    @Published private(set) var speed: Double = 1.0
    @Published private(set) var radioMode = false
    @Published private(set) var hasNext = false
    @Published private(set) var hasPrev = false
    // 睡眠定时:剩余毫秒(0=关),或「本集结束」
    @Published private(set) var sleepRemainingMs: Int = 0
    @Published private(set) var sleepEndOfEpisode = false

    let speedSteps: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: AnyCancellable?

    private var history: HistoryStore?
    private var settings: SettingsStore?

    // 队列上下文
    private var queue: [Episode] = []
    private var queueIndex = 0
    // 电台
    private var radioNext: (() async -> Episode?)?
    private var radioHistory: [Episode] = []
    private var radioPos = -1
    private let radioHistoryCap = 100

    // 淡入淡出 / 睡眠
    private var fadeTimer: Timer?
    private var sleepTimer: Timer?
    private let sleepFadeMs = 8_000
    private var tickCount = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.onTick(time) }
        }
        statusObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.buffering = (status == .waitingToPlayAtSpecifiedRate)
                self.isPlaying = (status == .playing)
                if self.tickCount % 10 == 0 { self.saveProgress() }
            }
    }

    func bind(history: HistoryStore, settings: SettingsStore) {
        self.history = history
        self.settings = settings
        self.speed = settings.defaultSpeed
    }

    // MARK: - 播放入口

    /// 单集(无上下文)。
    func play(_ episode: Episode) { playQueue([episode], startIndex: 0) }

    /// 以列表为队列从 startIndex 起播。
    func playQueue(_ episodes: [Episode], startIndex: Int) {
        guard !episodes.isEmpty else { return }
        if radioMode { stopRadio() }
        queue = episodes
        queueIndex = min(max(startIndex, 0), episodes.count - 1)
        updateNavFlags()
        playEpisode(episodes[queueIndex])
    }

    /// 同一集则暂停/继续,否则以该列表为队列起播。
    func playOrToggle(_ episode: Episode, queue: [Episode]) {
        if current?.id == episode.id { togglePlayPause() }
        else { playQueue(queue, startIndex: queue.firstIndex { $0.id == episode.id } ?? 0) }
    }

    func playOrToggle(_ episode: Episode) { playOrToggle(episode, queue: [episode]) }

    private func playEpisode(_ episode: Episode, isRadio: Bool = false) {
        if !isRadio && radioMode { stopRadio() }
        current = episode
        positionMs = 0
        durationMs = 0
        history?.record(episode, at: Date().timeIntervalSince1970)
        let resumeMs = history?.positionFor(episode.id) ?? 0

        guard let url = URL(string: episode.audioUrl) else { return }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        if resumeMs > 3000 { player.seek(to: CMTime(value: Int64(resumeMs), timescale: 1000)) }
        player.volume = 0
        player.play()
        player.rate = Float(speed)
        fadeVolume(to: 1.0, durationMs: 900)
    }

    // MARK: - 队列导航

    func next() {
        if radioMode {
            if radioPos >= 0 && radioPos < radioHistory.count - 1 {
                radioPos += 1; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio: true)
            } else { advanceRadio() }
        } else if queueIndex < queue.count - 1 {
            queueIndex += 1; updateNavFlags(); playEpisode(queue[queueIndex])
        }
    }

    func previous() {
        if radioMode {
            if radioPos > 0 { radioPos -= 1; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio: true) }
        } else if queueIndex > 0 {
            queueIndex -= 1; updateNavFlags(); playEpisode(queue[queueIndex])
        }
    }

    private func updateNavFlags() {
        if radioMode { hasPrev = radioPos > 0; hasNext = true }
        else { hasPrev = queueIndex > 0; hasNext = queueIndex >= 0 && queueIndex < queue.count - 1 }
    }

    // MARK: - 随机电台

    func startRadio(_ next: @escaping () async -> Episode?) {
        radioNext = next
        radioHistory.removeAll()
        radioPos = -1
        radioMode = true
    }

    func stopRadio() { radioNext = nil; radioMode = false; updateNavFlags() }

    func playRadioEpisode(_ episode: Episode) {
        radioHistory.append(episode)
        if radioHistory.count > radioHistoryCap { radioHistory.removeFirst() }
        radioPos = radioHistory.count - 1
        updateNavFlags()
        playEpisode(episode, isRadio: true)
    }

    private func advanceRadio() {
        guard let next = radioNext else { return }
        Task { @MainActor in
            let ep = await next()
            if let ep, radioMode { playRadioEpisode(ep) } else { stopRadio() }
        }
    }

    // MARK: - 传输控制

    func togglePlayPause() {
        if isPlaying { player.pause() } else { player.play(); player.rate = Float(speed) }
    }

    func seek(toMs ms: Int) {
        let t = max(0, ms)
        player.seek(to: CMTime(value: Int64(t), timescale: 1000))
        positionMs = t
    }

    func skipForward() { seekBy(ms: (settings?.skipForwardSec ?? 30) * 1000) }
    func skipBackward() { seekBy(ms: -((settings?.skipBackSec ?? 10) * 1000)) }
    private func seekBy(ms delta: Int) { seek(toMs: max(0, positionMs + delta)) }

    func setSpeed(_ s: Double) {
        speed = s
        if isPlaying { player.rate = Float(s) }
    }

    // MARK: - 睡眠定时

    func setSleepTimer(minutes: Int) {
        sleepEndOfEpisode = false
        sleepRemainingMs = minutes * 60_000
        startSleepTicker()
    }

    func setSleepEndOfEpisode() {
        sleepTimer?.invalidate()
        sleepRemainingMs = 0
        sleepEndOfEpisode = true
    }

    func cancelSleep() {
        sleepTimer?.invalidate(); sleepTimer = nil
        fadeTimer?.invalidate(); fadeTimer = nil
        sleepRemainingMs = 0
        sleepEndOfEpisode = false
        player.volume = 1.0
    }

    private func startSleepTicker() {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let remain = self.sleepRemainingMs - 1000
                if remain <= 0 {
                    self.sleepRemainingMs = 0
                    self.player.pause(); self.player.volume = 1.0
                    self.sleepTimer?.invalidate(); self.sleepTimer = nil
                } else {
                    self.sleepRemainingMs = remain
                    if remain <= self.sleepFadeMs {
                        self.player.volume = Float(Double(remain) / Double(self.sleepFadeMs))
                    }
                }
            }
        }
    }

    // MARK: - 淡入

    private func fadeVolume(to target: Float, durationMs: Int) {
        fadeTimer?.invalidate()
        let steps = max(1, durationMs / 50)
        var i = 0
        let start = player.volume
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                i += 1
                let f = min(1.0, Float(i) / Float(steps))
                self.player.volume = start + (target - start) * f
                if i >= steps { t.invalidate() }
            }
        }
    }

    // MARK: - 内部

    private func onTick(_ time: CMTime) {
        positionMs = Int(time.seconds * 1000)
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            durationMs = Int(d * 1000)
        }
        tickCount += 1
        if tickCount % 10 == 0 { saveProgress() }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stopAfter = self.sleepEndOfEpisode
                self.sleepEndOfEpisode = false
                if let ep = self.current { self.history?.updatePosition(ep.id, positionMs: 0, durationMs: self.durationMs) }
                if self.radioMode && !stopAfter { self.advanceRadio() }
            }
        }
    }

    private func saveProgress() {
        guard let ep = current else { return }
        history?.updatePosition(ep.id, positionMs: max(0, positionMs), durationMs: max(0, durationMs))
    }
}
