import Foundation
import AVFoundation
import Combine
import MediaPlayer
import AppKit

/// 列表播放模式。顺序 = 播到列表末尾即停;单曲循环 = 本集播完原地重播;
/// 随机 = 把这个列表打乱播一遍(走完表就停)。
///
/// **与 Android `PlayerController.PlayMode`、鸿蒙同名同 ordinal**(0/1/2),
/// 持久化存的也是 ordinal,所以**新增项只能加在末尾** —— 中间插一个位置,
/// 老用户存的数就会指向另一个模式(换含义的历史见 H118)。
enum PlayMode: Int, CaseIterable {
    case sequential = 0
    case repeatOne = 1
    case shuffle = 2

    /// 日志里用的名字,与 Android / 鸿蒙**同一串**:装机判据是同一条 grep
    /// (`playMode tag='…' -> SHUFFLE`、`playQueue … mode=REPEAT_ONE`),换端不该改词。
    /// 不是给用户看的字(那三个走 Localizable.strings)。
    ///
    /// ⚠️ **但"同一条 grep"这句在 macOS 只对运行时日志成立,对包内的 release 二进制不成立**(2026-10-24 实测,见 H209):
    /// Swift 的 `-O` 把 **9~15 字节**的字面量拆成两条 `movabsq` 立即数存进 `__text`,整词不连续 ——
    /// `SEQUENTIAL`(10B)与 `REPEAT_ONE`(9B)在这个平台上**永远 grep 不到**,只有 `SHUFFLE`(7B)能整词命中。
    /// 所以 `macos/verify-bundle.sh` 的词表按长度分了档(`lit8` / `lit16` / `sym`),
    /// 别把移动端那批词原样抄过来当 macOS 的出包判据 —— 那会造出一批恒 0 的假判据。
    var logName: String {
        switch self {
        case .sequential: return "SEQUENTIAL"
        case .repeatOne: return "REPEAT_ONE"
        case .shuffle: return "SHUFFLE"
        }
    }
}

/// 「列身份」的取值,两处共用同一个串:列右端那颗模式按钮按它读写自己那一格,
/// 列内某一行起播时把它随 `playQueue` 传下去(日志里 `tag='…'` 读到的就是它)。
/// 两边必须一致,否则「在这一列设的模式」和「这一列起播时用的模式」各走各的,
/// 不报错,只表现成"设了没生效"。频道主页前缀保证撞不上音阁那三个分段名。
enum ListTag {
    static let inbox = "inbox"
    static let fav = "fav"
    static let dl = "dl"
    static func podcast(_ channelKey: String) -> String { "podcast:\(channelKey)" }
}

/// 播放门面:AVPlayer 播放 + 队列上下文(上/下一集)+ 按列的播放模式 + 随机电台 + 睡眠定时 + 音频淡入淡出。
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
    /// **每一列自己的**播放模式(与 Android/鸿蒙 1.0.3 定稿口径同构,见 H119)。
    /// key 是 `ListTag` 的值;`""` 那一格是**回落值**(老用户那份全局设置,也是没有列身份时
    /// 起播的走法)。UI 读这张表,不读下面那个「当前生效」的。
    @Published private(set) var playModes: [String: PlayMode] = ["": .sequential]
    /// 正在播的那一列的 tag(`""` = 不属于任何可见列)。它是功能性的:
    /// 「改某一列的模式」只有在改的正是正在播那一列时才当场生效。
    @Published private(set) var activeListTag = ""
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
    /// 批注「跳回那一秒」用的一次性起点覆盖。`-1` = 没有覆盖(所以入口不能写 0)。
    private var startMsOverride = -1
    /// 本次起播的起点是**用户明确指定的那一秒**还是一条**续播进度**。
    /// 两者容差不同,见 `playAt(_:startMs:)` 与 `playEpisode` 里取 resumeMs 的那一段。
    private var pendingSeekExplicit = false

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
    /// **当前生效的**播放模式:自动续播与手动切集都按它走。它是「正在播的这一列」那一格
    /// (没有列身份时是回落值),不直接落盘 —— 落盘的是按列的那张表。
    private var playMode: PlayMode = .sequential
    /// 随机模式用的「打乱索引表」+ 指针。**不是每次抛骰子**:抛骰子会让上一集/下一集不对称
    /// (点下一集之后再点上一集回不到刚才那集),而且同一集可能连着播两次。
    /// 表在起播或切进随机模式时生成一次,正在播的这一集钉在第一位。
    private var shuffleOrder: [Int] = []
    private var shufflePos = -1
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
        refreshPlayModes()
        playMode = mode(for: activeListTag)
    }

    func bindListenStats(_ s: ListenStatsStore) { self.listenStats = s }

    // MARK: - 播放入口

    /// 单集(无上下文)。
    func play(_ episode: Episode) { playQueue([episode], startIndex: 0) }

    /// 以列表为队列从 startIndex 起播。
    ///
    /// - Parameter tag: 队列身份(`ListTag.inbox/fav/dl`、频道主页 `podcast:<key>`)。
    ///   不属于任何可见列表的入口(单播、迷你条、发现页)不传,空串走回落那一格。
    func playQueue(_ episodes: [Episode], startIndex: Int, tag: String = "") {
        guard !episodes.isEmpty else {
            Log.w("Player", "playQueue 空队列,忽略")
            return
        }
        loadRetries = 0
        if radioMode { stopRadio() }
        queue = episodes
        queueIndex = min(max(startIndex, 0), episodes.count - 1)
        activeListTag = tag
        // 先定模式再播:随机要在这一步把表洗出来(当前集钉在第一位)
        applyPlayMode(mode(for: tag))
        Log.i("Player", "playQueue count=\(episodes.count) index=\(queueIndex) tag='\(tag)' mode=\(playMode.logName)")
        playEpisode(episodes[queueIndex])
    }

    /// 同一集则暂停/继续,否则以该列表为队列起播。
    func playOrToggle(_ episode: Episode, queue: [Episode], tag: String = "") {
        if current?.id == episode.id { togglePlayPause() }
        else { playQueue(queue, startIndex: queue.firstIndex { $0.id == episode.id } ?? 0, tag: tag) }
    }

    func playOrToggle(_ episode: Episode) { playOrToggle(episode, queue: [episode]) }

    /// 播这一集,并从**调用方指定的那一秒**起播(批注「跳回那一秒」)。
    ///
    /// 三点都是必须的,不是风格:
    /// - 不走 `playOrToggle`:那一集正在播时它会被判成「按暂停」,点了没反应;
    /// - 队列只放这一集(与 Android / 鸿蒙同口径,批注不是列表播放);
    /// - 起点写进 `startMsOverride`,由 `playEpisode` 在取续播点那里消费 ——
    ///   **不能在入口就清掉**:`handleLoadFailure` 那次自动重试会再进一次 `playEpisode`,
    ///   入口清掉的话重试那轮读到的就是「没有覆盖」,批注从此变成"从头播"。
    func playAt(_ episode: Episode, startMs: Int) {
        Log.i("Player", "playAt \(startMs)ms id=\(episode.id)")
        startMsOverride = startMs > 0 ? startMs : 0
        play(episode)
    }

    // MARK: - 播放模式

    /// 某一列该按什么走法播;没设过的列用回落值(`""` 那一格)。
    func mode(for tag: String) -> PlayMode { playModes[tag] ?? playModes[""] ?? .sequential }

    /// 把 SettingsStore 那份 ordinal 表换成枚举视图;`""` 一格永远存在(回落值)。
    private func refreshPlayModes() {
        guard let s = settings else { return }
        var next: [String: PlayMode] = [:]
        for (k, v) in s.playModeByTag { next[k] = PlayMode(rawValue: v) ?? .sequential }
        next[""] = PlayMode(rawValue: s.playModeDefault) ?? .sequential
        playModes = next
    }

    /// 顺序 → 单曲循环 → 随机 → 顺序。某一列右端那颗模式按钮点一下就走这一列自己的那一格。
    func cyclePlayMode(_ tag: String) {
        let all = PlayMode.allCases
        guard let i = all.firstIndex(of: mode(for: tag)) else { return }
        setPlayMode(all[(i + 1) % all.count], for: tag)
    }

    /// 设定**某一列**的播放模式并落盘。
    ///
    /// 只有改的正是**正在播那一列**时才当场生效;改别的列只是记下它以后的走法 ——
    /// 否则「看着收藏但正在播最新」时点一下就把正在播的走法改掉了,那才是真的串。
    func setPlayMode(_ mode: PlayMode, for tag: String) {
        settings?.setPlayMode(mode.rawValue, for: tag)
        refreshPlayModes()
        Log.i("Player", "playMode tag='\(tag)' -> \(mode.logName)"
            + "\(tag == activeListTag ? " (生效)" : " (未生效:正在播 '\(activeListTag)')")")
        if tag == activeListTag { applyPlayMode(mode) }
    }

    /// 让某个模式**当场生效**:切进随机要重洗一次表并把当前集钉在第一位
    /// (否则从顺序切进随机后「下一集」还按列表顺序走,等于没切);切出随机则丢掉表。
    /// 落盘不在这里 —— 模式按列存,见 `setPlayMode(_:for:)`。
    private func applyPlayMode(_ mode: PlayMode) {
        playMode = mode
        if mode == .shuffle { rebuildShuffleOrder() } else { clearShuffleOrder() }
        updateNavFlags()
    }

    /// 按当前模式重洗随机表:正在播的这一集钉在第一位,其余打乱。
    private func rebuildShuffleOrder() {
        guard !queue.isEmpty else { clearShuffleOrder(); return }
        let pinned = min(max(queueIndex, 0), queue.count - 1)
        shuffleOrder = [pinned] + queue.indices.filter { $0 != pinned }.shuffled()
        shufflePos = 0
    }

    /// 丢掉随机表(切出随机模式、或队列整个换掉时)。留着过期表会让下标指到别的列表。
    private func clearShuffleOrder() {
        shuffleOrder = []
        shufflePos = -1
    }

    /// 当前播放模式下,上下文队列里**手动下一集**要去的下标;没有下一集返回 null(按钮该灰)。
    ///
    /// 顺序与单曲循环在这里是同一个走法:按下「下一集」就是要换一首,原地重播当前这集会被读成按钮坏了。
    /// 「单曲循环播完自己再来一遍」那条特例只在 `advanceQueue(auto: true)` 这条路上生效。
    private func nextQueueIndex() -> Int? {
        switch playMode {
        case .sequential, .repeatOne:
            return (queueIndex >= 0 && queueIndex < queue.count - 1) ? queueIndex + 1 : nil
        case .shuffle:
            return (shufflePos >= 0 && shufflePos < shuffleOrder.count - 1) ? shuffleOrder[shufflePos + 1] : nil
        }
    }

    /// 当前播放模式下,上下文队列里的上一集下标;没有返回 nil。
    private func prevQueueIndex() -> Int? {
        if playMode == .shuffle {
            return shufflePos > 0 ? shuffleOrder[shufflePos - 1] : nil
        }
        let p = queueIndex - 1
        return (p >= 0 && p < queue.count) ? p : nil
    }

    /// 沿当前播放模式走到队列的下一集并播它;走到头(顺序播完 / 随机走完表)什么都不做。
    ///
    /// - Parameter auto: 只有「本集自然播完」这条路径传真。**单曲循环只在自动推进时原地重播**;
    ///   手动按「下一集」不传,于是走 `nextQueueIndex` 的顺序口径。
    private func advanceQueue(auto: Bool = false) {
        if auto && playMode == .repeatOne {
            guard !queue.isEmpty else { return }
            Log.i("Player", "advanceQueue repeat-one index=\(queueIndex)")
            updateNavFlags()
            playEpisode(queue[queueIndex])
            return
        }
        guard let ni = nextQueueIndex() else { return }
        if playMode == .shuffle { shufflePos += 1 }
        queueIndex = ni
        updateNavFlags()
        playEpisode(queue[queueIndex])
    }

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
        // 起点有三个来源,优先级就按写的这个顺序:
        // ① 调用方明确指定的那一秒(批注)—— 消费掉 override,只生效一次;
        // ② 引导音频永远从头;③ 否则才是续播进度。
        let resumeMs: Int
        if startMsOverride >= 0 {
            resumeMs = startMsOverride
            startMsOverride = -1
            pendingSeekExplicit = true
        } else if isGuide {
            resumeMs = 0
            pendingSeekExplicit = false
        } else {
            resumeMs = history?.positionFor(episode.id) ?? 0
            pendingSeekExplicit = false
        }
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
        // **明确跳转与续播是两套容差,不能共用一个 `if`**:
        // 续播只看「>3 秒才回跳」(macOS 从来没有另两端"距片尾 10 秒内不如从头播"那条启发式,
        // 这次也不给它加);而用户指定的一秒必须跳得进去 —— 写在片尾 8 秒处的批注若吃续播那条
        // 规则就永远点不开,而那恰恰是用户要的位置。它只受「别跳出片尾」约束,上限用 RSS 元数据
        // 时长减 2 秒:此刻 `durationMs` 还没被 `onTick` 填上(AVPlayer 的时长要等 item 加载),
        // 而元数据缺失(0)时**不设上限** —— 让 AVPlayer 自己收在末尾,好过把合法跳点判死。
        let metaMs = episode.durationSec * 1000
        let ceiling = metaMs > 0 ? metaMs - 2000 : Int.max
        let explicit = pendingSeekExplicit
        pendingSeekExplicit = false
        let ok = explicit ? resumeMs < ceiling : resumeMs > 3000
        if ok {
            player.seek(to: CMTime(value: Int64(resumeMs), timescale: 1000))
        } else {
            Log.i("Player", "跳点落空 seek=\(resumeMs) metaDur=\(metaMs) explicit=\(explicit) id=\(episode.id)")
        }
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

    /// 批量追加到队尾,返回**真正加进去的条数**(与 Android `enqueueAll` 同口径)。
    ///
    /// 一次去重、一次 `updateNavFlags`,不循环单条 `enqueue`:
    /// 逐条调用会让「已存在」那几条各打一行日志,批量按了 30 条时日志里看不出整体结果
    /// (`added=? of=?` 这一行才是装机判据)。也照 Android 的做法**无条件打这行日志** ——
    /// `added=0` 正是「全选的这一列都已在待播里」那一轮,提前 return 之后再打就成了静默路径。
    @discardableResult
    func enqueueAll(_ eps: [Episode]) -> Int {
        let before = userQueue.count
        var seen = Set(userQueue.map(\.id))
        var fresh: [Episode] = []
        for ep in eps where seen.insert(ep.id).inserted { fresh.append(ep) }
        Log.i("Queue", "enqueueAll added=\(fresh.count) of=\(eps.count) 队列=\(before + fresh.count)")
        guard !fresh.isEmpty else { return 0 }
        userQueue.append(contentsOf: fresh)
        updateNavFlags()
        return fresh.count
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
        Log.i("Player", "next radio=\(radioMode) index=\(queueIndex) radioPos=\(radioPos) userQueue=\(userQueue.count) mode=\(playMode.logName)")
        // 用户队列优先
        if !userQueue.isEmpty { consumeUserQueue(at: 0, reason: "next"); return }
        if radioMode {
            if radioPos >= 0 && radioPos < radioHistory.count - 1 {
                radioPos += 1; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio: true)
            } else { advanceRadio() }
        } else {
            advanceQueue()
        }
    }

    func previous() {
        loadRetries = 0
        Log.i("Player", "previous radio=\(radioMode) index=\(queueIndex) radioPos=\(radioPos) mode=\(playMode.logName)")
        if radioMode {
            if radioPos > 0 { radioPos -= 1; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio: true) }
        } else if let pi = prevQueueIndex() {
            if playMode == .shuffle { shufflePos -= 1 }
            queueIndex = pi
            updateNavFlags()
            playEpisode(queue[queueIndex])
        }
    }

    private func updateNavFlags() {
        if radioMode { hasPrev = radioPos > 0; hasNext = true }
        else {
            // 用户队列非空,或上下文队列在**当前播放模式**下还有后续,都算「有下一集」。
            // 这里必须走 nextQueueIndex() 而不是自己算 +1:随机模式看的是表指针而不是列表下标,
            // 而单曲循环**不影响这个判据**(它只改自动续播那条路)——
            // 手动「下一集」播到列表末尾就是没有下一集,按钮该灰。
            hasPrev = prevQueueIndex() != nil
            hasNext = !userQueue.isEmpty || nextQueueIndex() != nil
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
                } else {
                    // 上下文队列(点某一集起播的):按播放模式接下一集。
                    // 这条分支是移植播放模式这轮补上的 —— 之前 macOS 列表播完一集就停在这里,
                    // 只有手动按下一集会走;而**单曲循环与随机两档全靠这条自动路径成立**
                    // (单曲循环就是这里的 auto 路径,见 advanceQueue)。
                    self.advanceQueue(auto: true)
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
