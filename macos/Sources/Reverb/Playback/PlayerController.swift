import Foundation
import AVFoundation
import Combine
import MediaPlayer
import AppKit

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
    /// 用户播放队列(up next):优先于当前上下文队列/电台续播。
    @Published private(set) var userQueue: [Episode] = []
    // 睡眠定时:剩余毫秒(0=关),或「本集结束」
    @Published private(set) var sleepRemainingMs: Int = 0
    @Published private(set) var sleepEndOfEpisode = false
    @Published private(set) var playbackError: String?   // 加载失败提示(nil=正常)

    let speedSteps: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: AnyCancellable?
    private var itemStatusObserver: AnyCancellable?
    private var loadRetries = 0
    private var lastIsRadio = false

    private var history: HistoryStore?
    private var settings: SettingsStore?
    private var listenStats: ListenStatsStore?
    // 累计收听时长的基线:仅统计"同一集、播放中、合理正向增量"的内容毫秒
    private var lastCountedPosMs = 0
    private var lastCountedEpId = ""
    /// 下载模块注入:给定单集,若已离线下载则返回本地文件 URL,优先本地播放。
    var localFileProvider: ((Episode) -> URL?)?

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
                if !self.isPlaying { self.listenStats?.flush() }   // 暂停即落盘累计时长
                self.updateNowPlaying()
            }
        setupRemoteCommands()
    }

    // MARK: - 系统 Now Playing 中心 + 媒体键/控制中心

    private var artworkCacheURL = ""
    private var artworkCache: MPMediaItemArtwork?

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Double(settings?.skipForwardSec ?? 30))]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skipForward(); return .success }
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Double(settings?.skipBackSec ?? 10))]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skipBackward(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(toMs: Int(e.positionTime * 1000)); return .success
        }
    }

    private func updateNowPlaying() {
        guard let ep = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.title,
            MPMediaItemPropertyArtist: ep.podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0
        ]
        if durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0 }
        if let art = artworkCache, artworkCacheURL == ep.artworkUrl { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        loadArtworkIfNeeded(ep.artworkUrl)
    }

    private func loadArtworkIfNeeded(_ url: String) {
        guard !url.isEmpty, url != artworkCacheURL, let u = URL(string: url) else { return }
        artworkCacheURL = url
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: u).0,
                  let img = NSImage(data: data) else {
                Log.w("NowPlaying", "封面加载失败 \(url)")
                return
            }
            let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            await MainActor.run { [weak self] in
                guard let self, self.current?.artworkUrl == url else { return }
                self.artworkCache = art
                self.updateNowPlaying()
            }
        }
    }

    func bind(history: HistoryStore, settings: SettingsStore) {
        self.history = history
        self.settings = settings
        self.speed = settings.defaultSpeed
    }

    func bindListenStats(_ s: ListenStatsStore) { self.listenStats = s }

    // MARK: - 播放入口

    /// 单集(无上下文)。
    func play(_ episode: Episode) { playQueue([episode], startIndex: 0) }

    /// 以列表为队列从 startIndex 起播。
    func playQueue(_ episodes: [Episode], startIndex: Int) {
        guard !episodes.isEmpty else {
            Log.w("Player", "playQueue 空队列,忽略")
            return
        }
        loadRetries = 0
        if radioMode { stopRadio() }
        queue = episodes
        queueIndex = min(max(startIndex, 0), episodes.count - 1)
        Log.i("Player", "playQueue count=\(episodes.count) index=\(queueIndex)")
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
        lastIsRadio = isRadio
        playbackError = nil
        current = episode
        positionMs = 0
        durationMs = 0
        listenStats?.flush()   // 结算上一集残余
        // 内置引导音频不是一集真正的播客:不进历史、不计收听时长,
        // 否则"收听时长"榜首会是引导音频,「继续收听」里也会挂着它。
        let isGuide = GuideEpisode.isGuide(episode.id)
        if !isGuide { history?.record(episode, at: Date().timeIntervalSince1970) }
        let resumeMs = isGuide ? 0 : (history?.positionFor(episode.id) ?? 0)
        // 统计基线对齐到续播起点,避免把 resume 跳转记成收听
        lastCountedEpId = episode.id
        lastCountedPosMs = resumeMs

        let local = localFileProvider?(episode)
        guard let url = local ?? URL(string: episode.audioUrl) else {
            Log.e("Player", "playEpisode 无效音频 URL id=\(episode.id) title=\"\(episode.title)\" audioUrl=\(episode.audioUrl)")
            playbackError = String(localized: "加载失败,请检查网络后重试")
            return
        }
        Log.i("Player", "playEpisode id=\(episode.id) title=\"\(episode.title)\" feed=\"\(episode.podcastTitle)\" radio=\(isRadio) 源=\(local != nil ? "本地" : "网络") resume=\(resumeMs)ms")
        let item = AVPlayerItem(url: url)
        // 观察加载状态:失败(常见于睡眠唤醒后网络栈短暂异常)自动重试,仍失败则给出可见提示,避免静默卡死
        itemStatusObserver = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    Log.i("Player", "AVPlayerItem readyToPlay id=\(episode.id)")
                    self.loadRetries = 0
                    self.playbackError = nil
                case .failed:
                    Log.e("Player", "AVPlayerItem failed id=\(episode.id)", error: item.error)
                    self.handleLoadFailure(episode)
                default:
                    break
                }
            }
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        if resumeMs > 3000 { player.seek(to: CMTime(value: Int64(resumeMs), timescale: 1000)) }
        player.volume = 0
        player.play()
        player.rate = Float(speed)
        fadeVolume(to: 1.0, durationMs: 900)
        updateNowPlaying()
    }

    /// 加载失败:同一集下自动重试至多 3 次(退避 0.8s),超限则提示,等待用户手动重试。
    private func handleLoadFailure(_ episode: Episode) {
        guard current?.id == episode.id else { return }
        if loadRetries < 3 {
            loadRetries += 1
            let isRadio = lastIsRadio
            Log.w("Player", "加载失败,自动重试 \(loadRetries)/3 id=\(episode.id)")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                if self.current?.id == episode.id { self.playEpisode(episode, isRadio: isRadio) }
            }
        } else {
            loadRetries = 0
            Log.e("Player", "加载失败,重试耗尽,提示用户手动重试 id=\(episode.id)")
            playbackError = String(localized: "加载失败,请检查网络后重试")
        }
    }

    /// 手动重试当前集(供 UI 的「重试」用)。
    func retry() {
        guard let ep = current else { return }
        Log.i("Player", "手动重试 id=\(ep.id)")
        loadRetries = 0
        playEpisode(ep, isRadio: lastIsRadio)
    }

    // MARK: - 用户播放队列(up next)

    /// 追加到队尾(已在队列中则忽略)。
    func enqueue(_ ep: Episode) {
        guard !userQueue.contains(where: { $0.id == ep.id }) else {
            Log.d("Queue", "enqueue 跳过已存在 id=\(ep.id)")
            return
        }
        userQueue.append(ep)
        Log.i("Queue", "enqueue id=\(ep.id) title=\"\(ep.title)\" 队列=\(userQueue.count)")
        updateNavFlags()
    }

    /// 插入到队首,作为「下一个播放」(已存在则移动到队首)。
    func playNext(_ ep: Episode) {
        userQueue.removeAll { $0.id == ep.id }
        userQueue.insert(ep, at: 0)
        Log.i("Queue", "playNext id=\(ep.id) title=\"\(ep.title)\" 队列=\(userQueue.count)")
        updateNavFlags()
    }

    func removeFromQueue(_ id: String) {
        userQueue.removeAll { $0.id == id }
        Log.i("Queue", "removeFromQueue id=\(id) 队列=\(userQueue.count)")
        updateNavFlags()
    }

    /// 队列内重排。offsets 遵循 SwiftUI onMove 语义。
    func moveInQueue(from: Int, to: Int) {
        guard from >= 0, from < userQueue.count, from != to else { return }
        let ep = userQueue.remove(at: from)
        let dest = to > from ? to - 1 : to
        userQueue.insert(ep, at: min(max(dest, 0), userQueue.count))
    }

    func clearQueue() {
        guard !userQueue.isEmpty else { return }
        Log.i("Queue", "清空播放队列 \(userQueue.count) 条")
        userQueue.removeAll()
        updateNavFlags()
    }

    /// 取出并播放指定位置的一集(退出电台,不改动既有上下文队列)。
    private func consumeUserQueue(at index: Int, reason: String) {
        guard userQueue.indices.contains(index) else { return }
        let ep = userQueue.remove(at: index)
        Log.i("Queue", "consume(\(reason)) id=\(ep.id) title=\"\(ep.title)\" 剩余=\(userQueue.count)")
        loadRetries = 0
        if radioMode { stopRadio() }
        playEpisode(ep)
        updateNavFlags()
    }

    /// 点击队列单集直接跳播:从队列摘出立即播,其余顺序不动(与 Android/鸿蒙同名同义)。
    func playFromQueue(id: String) {
        if let i = userQueue.firstIndex(where: { $0.id == id }) {
            consumeUserQueue(at: i, reason: "tap")
        }
    }

    // MARK: - 队列导航

    func next() {
        loadRetries = 0
        Log.i("Player", "next radio=\(radioMode) index=\(queueIndex) radioPos=\(radioPos) userQueue=\(userQueue.count)")
        // 用户队列优先
        if !userQueue.isEmpty { consumeUserQueue(at: 0, reason: "next"); return }
        if radioMode {
            if radioPos >= 0 && radioPos < radioHistory.count - 1 {
                radioPos += 1; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio: true)
            } else { advanceRadio() }
        } else if queueIndex < queue.count - 1 {
            queueIndex += 1; updateNavFlags(); playEpisode(queue[queueIndex])
        }
    }

    func previous() {
        loadRetries = 0
        Log.i("Player", "previous radio=\(radioMode) index=\(queueIndex) radioPos=\(radioPos)")
        if radioMode {
            if radioPos > 0 { radioPos -= 1; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio: true) }
        } else if queueIndex > 0 {
            queueIndex -= 1; updateNavFlags(); playEpisode(queue[queueIndex])
        }
    }

    private func updateNavFlags() {
        if radioMode { hasPrev = radioPos > 0; hasNext = true }
        else {
            hasPrev = queueIndex > 0
            hasNext = (queueIndex >= 0 && queueIndex < queue.count - 1) || !userQueue.isEmpty
        }
    }

    // MARK: - 随机电台

    func startRadio(_ next: @escaping () async -> Episode?) {
        Log.i("Radio", "startRadio")
        radioNext = next
        radioHistory.removeAll()
        radioPos = -1
        radioMode = true
    }

    func stopRadio() {
        if radioMode { Log.i("Radio", "stopRadio 历史=\(radioHistory.count)") }
        radioNext = nil; radioMode = false; updateNavFlags()
    }

    func playRadioEpisode(_ episode: Episode) {
        loadRetries = 0
        radioHistory.append(episode)
        if radioHistory.count > radioHistoryCap { radioHistory.removeFirst() }
        radioPos = radioHistory.count - 1
        Log.i("Radio", "playRadioEpisode id=\(episode.id) radioPos=\(radioPos)")
        updateNavFlags()
        playEpisode(episode, isRadio: true)
    }

    private func advanceRadio() {
        guard let next = radioNext else { return }
        Log.i("Radio", "advanceRadio 拉取下一集…")
        Task { @MainActor in
            let ep = await next()
            if let ep, radioMode { playRadioEpisode(ep) } else {
                Log.w("Radio", "advanceRadio 无下一集,停止电台")
                stopRadio()
            }
        }
    }

    // MARK: - 传输控制

    func togglePlayPause() {
        Log.d("Player", "togglePlayPause 当前 isPlaying=\(isPlaying)")
        if isPlaying { player.pause() } else { player.play(); player.rate = Float(speed) }
    }

    func seek(toMs ms: Int) {
        let t = max(0, ms)
        Log.d("Player", "seek → \(t)ms")
        player.seek(to: CMTime(value: Int64(t), timescale: 1000))
        positionMs = t
    }

    func skipForward() { seekBy(ms: (settings?.skipForwardSec ?? 30) * 1000) }
    func skipBackward() { seekBy(ms: -((settings?.skipBackSec ?? 10) * 1000)) }
    private func seekBy(ms delta: Int) { seek(toMs: max(0, positionMs + delta)) }

    func setSpeed(_ s: Double) {
        Log.d("Player", "setSpeed \(s)×")
        speed = s
        if isPlaying { player.rate = Float(s) }
    }

    // MARK: - 睡眠定时

    func setSleepTimer(minutes: Int) {
        Log.i("Sleep", "设置睡眠定时 \(minutes) 分钟")
        sleepEndOfEpisode = false
        sleepRemainingMs = minutes * 60_000
        startSleepTicker()
    }

    func setSleepEndOfEpisode() {
        Log.i("Sleep", "设置睡眠定时:本集结束")
        sleepTimer?.invalidate()
        sleepRemainingMs = 0
        sleepEndOfEpisode = true
    }

    func cancelSleep() {
        Log.i("Sleep", "取消睡眠定时")
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
                    Log.i("Sleep", "睡眠定时触发,暂停播放")
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
        countListening()
        tickCount += 1
        if tickCount % 10 == 0 { saveProgress() }
        if tickCount % 4 == 0 { updateNowPlaying() } // 约每 2 秒同步系统 Now Playing 进度
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
                Log.i("Player", "播放结束 id=\(self.current?.id ?? "-") radio=\(self.radioMode) userQueue=\(self.userQueue.count) 本集结束停止=\(stopAfter)")
                if let ep = self.current, !GuideEpisode.isGuide(ep.id) {
                    self.history?.updatePosition(ep.id, positionMs: 0, durationMs: self.durationMs)
                    self.history?.markPlayed(ep.id, true)   // 自然播完:标记已播完
                }
                self.listenStats?.flush()
                if stopAfter {
                    // 睡眠「本集结束」:到此为止,不续播
                } else if self.radioMode {
                    self.advanceRadio()
                } else if !self.userQueue.isEmpty {
                    // 队列续播:取出队首继续
                    self.consumeUserQueue(at: 0, reason: "end")
                }
            }
        }
    }

    private func saveProgress() {
        guard let ep = current else { return }
        // 引导音频不写历史:playEpisode 已跳过 record,这里若还写就会又建出一条
        if GuideEpisode.isGuide(ep.id) { return }
        history?.updatePosition(ep.id, positionMs: max(0, positionMs), durationMs: max(0, durationMs))
    }

    /// 累计"实际播放过的内容毫秒":仅当同一集、播放中、且增量为合理正向值(1..3000ms)时计入。
    /// 快进/快退的大跳变(越界)与暂停(增量≈0)自然被剔除;倍速下按内容时长计。
    private func countListening() {
        guard let ep = current else { lastCountedEpId = ""; return }
        if GuideEpisode.isGuide(ep.id) { return }   // 引导音频不计时长
        if ep.id == lastCountedEpId {
            let delta = positionMs - lastCountedPosMs
            if isPlaying && delta >= 1 && delta <= 3000 {
                listenStats?.add(episode: ep, deltaMs: delta)
            }
        }
        lastCountedPosMs = positionMs
        lastCountedEpId = ep.id
    }
}
