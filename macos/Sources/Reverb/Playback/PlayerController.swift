import Foundation
import AVFoundation
import Combine
import MediaPlayer
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
    /**
     一次性「这一集暂时播不了」提示,由 `RootView` 顶部的 `TopToast` 显示(桌面没有 Toast)。

     为什么不能复用 [playbackError]:那条提示挂的是「**当前这一集**」,而视频源解析失败时
     `current` 还是上一集(见 H232 的「先解析、后提交」)—— 写成它会被播放页按 id 挡掉,
     等于静默失败。这一条与当前一集无关,只说明「刚才点的那一集起不来」。
     */
    @Published private(set) var notice: String?
    /// 自动清空 [notice] 的代次:连着点两次播不了时,前一条的定时器不能把后一条提前抹掉。
    private var noticeToken = 0

    let speedSteps: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: AnyCancellable?
    private var itemStatusObserver: AnyCancellable?
    /// settings 里快进/快退两档秒数的订阅:变了就把声明给系统的档位重刷一次
    /// (为什么需要它见 `refreshRemoteCommandIntervals`,REVIEW-2026-10-25 族 E)。
    private var skipIntervalObserver: AnyCancellable?
    private var loadRetries = 0
    private var lastIsRadio = false
    /// 上一次装载是「起播」还是「预载」。自动重试要沿用它:
    /// 冷启动恢复的那一次若加载失败,重试完就自己出声 —— 那正是「恢复现场不恢复意图」要防的事。
    private var lastAutoplay = true
    /// 批注「跳回那一秒」用的一次性起点覆盖。`-1` = 没有覆盖(所以入口不能写 0)。
    private var startMsOverride = -1
    /// 本次起播的起点是**用户明确指定的那一秒**还是一条**续播进度**。
    /// 两者容差不同,见 `playAt(_:startMs:)` 与 `playEpisode` 里取 resumeMs 的那一段。
    private var pendingSeekExplicit = false

    private var history: HistoryStore?
    private var settings: SettingsStore?
    private var listenStats: ListenStatsStore?
    /// 跨启动的播放态存储(「正在播哪一集 / 它来自哪一列 / 排好的 up next」)。
    /// 没绑上时持久化与恢复都静默跳过 —— 无界面自检(`--selftest`)不需要它。
    private var stateStore: PlaybackStateStore?
    // 累计收听时长的基线:仅统计"同一集、播放中、合理正向增量"的内容毫秒
    private var lastCountedPosMs = 0
    private var lastCountedEpId = ""
    /// 下载模块注入:给定单集,若已离线下载则返回本地文件 URL,优先本地播放。
    var localFileProvider: ((Episode) -> URL?)?
    /// 播放缓存:流式起播之后由它把整集落到本机,下次直接本地起播。
    /// 与 `localFileProvider`(用户点名下载的那份)是两条独立的路,见 `AudioCacheManager` 顶部。
    private var audioCache: AudioCacheManager?
    /// 视频源(伪地址)的最后一跳是**现取直链**。注入的是仓库里那**同一个** `BilibiliSource` ——
    /// 候选流缓存与探活游标都在它身上,换实例等于每次起播重新摸一遍 PCDN。
    var resolvePseudoUrl: ((String) async -> BilibiliSource.ResolvedStream?)?
    /// 起播代号:伪地址解析要一次网络往返,等待期间用户可能换了集 —— 旧结果回来必须自弃。
    private var playGeneration = 0

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
    /// 随机电台去重窗口:抽下一集时排除**最近这么多集**。
    /// 数字与 Android `playback/RadioStation.kt` 的 `RECENT_CAP` 逐项相同 ——
    /// 三端「随机」撞车的概率该是同一个,不该这端 40 那端 100。
    private let radioRecentCap = 40

    // 淡入淡出 / 睡眠
    private var fadeTimer: Timer?
    private var sleepTimer: Timer?
    private let sleepFadeMs = 8_000
    private var tickCount = 0

    #if os(iOS)
    /// iOS 的音频会话由本类唯一负责:`.playback` 让静音键拨下也照常出声,
    /// 也是 Info.plist 里 `UIBackgroundModes=audio` 真正生效的前提。
    /// macOS 没有会话概念,这一整段只在 iOS 编译。
    private var interruptionObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    #endif

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    // 来电/闹钟/其他 App 抢会话:先记住意图,再暂停。
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.player.pause()
                case .ended:
                    let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                        AVAudioSession.InterruptionOptions(rawValue: $0)
                    }
                    if opts?.contains(.shouldResume) == true, self.wasPlayingBeforeInterruption {
                        self.player.play()
                    }
                @unknown default:
                    break
                }
            }
        }
        #endif
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
        refreshRemoteCommandIntervals()
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skipForward(); return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skipBackward(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(toMs: Int(e.positionTime * 1000)); return .success
        }
    }

    /// 把「快进 / 快退」两档**声明**给系统(控制中心、触控栏、锁屏上那两颗按钮显示的秒数)。
    ///
    /// ⚠️ 这只影响**系统侧显示的提示值**,不影响实际跳过步长:命令 handler
    /// (`skipForward()` / `skipBackward()`,本文件下面那两行)忽略 `event.interval`、
    /// 每次实时读 settings,所以真按下去跳的秒数一直是对的。
    ///
    /// 为什么要单独成函数并在 settings 到位之后再调一次(见 REVIEW-2026-10-25 族 E):
    /// `init()` 里的 `setupRemoteCommands()` 跑在 `AppEnvironment` 调
    /// `bind(history:settings:)` **之前**,那一刻 `settings` 还是 nil,
    /// `settings?.skipForwardSec ?? 30` 恒取到兜底值 —— 于是设置页把快退改成 15 秒,
    /// 控制中心仍然写着 10 秒,而且**永远是 30/10**,声明等于没声明。
    /// 现在 bind 里调一次、两格再变时由 Combine 订阅各调一次。
    private func refreshRemoteCommandIntervals() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Double(settings?.skipForwardSec ?? 30))]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Double(settings?.skipBackSec ?? 10))]
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
        guard !url.isEmpty, url != artworkCacheURL, URL(string: url) != nil else { return }
        artworkCacheURL = url
        Task { [weak self] in
            // 走与列表同一份封面磁盘缓存:断网时「正在播放」那张也还在,
            // 且不会再往系统 URLCache 里另存一份看不见的副本(见 ArtworkCache 顶部)。
            guard let data = await ArtworkCache.shared.data(for: url) else {
                Log.w("NowPlaying", "封面加载失败 \(Log.endpoint(url))")
                return
            }
            #if os(macOS)
            guard let img = NSImage(data: data) else {
                Log.w("NowPlaying", "封面解码失败 \(Log.endpoint(url))")
                return
            }
            let size = img.size
            #else
            guard let img = UIImage(data: data) else {
                Log.w("NowPlaying", "封面解码失败 \(Log.endpoint(url))")
                return
            }
            let size = img.size
            #endif
            let art = MPMediaItemArtwork(boundsSize: size) { _ in img }
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
        // init() 里那次 setupRemoteCommands 跑在本方法之前,那一刻 settings 还是 nil,
        // 于是给系统声明的快进/快退档位恒为兜底的 30/10(见 REVIEW-2026-10-25 族 E)。
        // 设置到位了:先补声明一次,再跟着两格后续每次改动重刷。
        refreshRemoteCommandIntervals()
        skipIntervalObserver = Publishers
            .Merge(settings.$skipBackSec.map { _ in }, settings.$skipForwardSec.map { _ in })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRemoteCommandIntervals() }
    }

    func bindListenStats(_ s: ListenStatsStore) { self.listenStats = s }

    func bindAudioCache(_ c: AudioCacheManager) { audioCache = c }

    // MARK: - 播放态跨启动(playback_state.json)

    func bindState(_ s: PlaybackStateStore) { stateStore = s }

    /// 把「正在播什么 / 它来自哪一列 / 排好的 up next」落一次盘。
    /// 每个**用户动作**改完队列或起播之后都调一次(`enqueue` / `playNext` / `removeFromQueue` /
    /// `moveInQueue` / `clearQueue` / `consumeUserQueue` / `playEpisode`)。
    ///
    /// 电台模式只落 upNext(`current=nil`):两端同口径 —— 随机电台的上下文是**一次性的**,
    /// 重启后没有"下一条随机"的种子,硬恢复那一集会让用户从电台掉回单集播放。
    private func persistState() {
        guard let st = stateStore else { return }
        // 直播流与电台同属「没有可恢复的身份」:流地址隔天多半已经失效,恢复出来只会是
        // 一个点了没反应的迷你条。up next 是用户自己排的,照旧保留。
        if radioMode || current?.isLive == true {
            st.save(current: nil, listTag: "", context: [], contextIndex: 0, upNext: userQueue)
        } else {
            st.save(current: current, listTag: activeListTag, context: queue,
                    contextIndex: queueIndex, upNext: userQueue)
        }
    }

    /// 冷启动恢复**现场**,不恢复**意图**:预载暂停态(与 Android / 鸿蒙同口径),
    /// 用户按播放才出声。理由与两端注释同一条 —— 启动即响是用户没要求的动作,
    /// 而"上次听到哪一集"这条信息本身在迷你条上已经给回来了。
    ///
    /// 只在 `current == nil` 时执行:重复启动、或 UI 已经自己起播之后再调都不该把正在播的换掉。
    func restoreState() {
        guard let st = stateStore, current == nil else { return }
        let snap = st.snapshot
        if snap.isEmpty { return }
        if !snap.upNext.isEmpty {
            userQueue = snap.upNext
            Log.i("Player", "restore upNext=\(snap.upNext.count)")
        }
        let saved = snap.current
        // 引导音频不进历史也不该跨启动恢复:两端都在这里过滤掉
        let cur = saved.flatMap { GuideEpisode.isGuide($0.id) ? nil : $0 }
        guard let cur else {
            if saved != nil { Log.i("Player", "restore 忽略引导音频,重写播放态"); persistState() }
            updateNavFlags()
            return
        }
        // 上下文窗口里找不到这一集(极端:落盘那份被手改过)时退化成只有它自己的单集队列,
        // 而不是丢掉 cur —— 迷你条必须出现,那是这条恢复的主要目的。
        queue = snap.context.contains { $0.id == cur.id } ? snap.context : [cur]
        queueIndex = queue.firstIndex { $0.id == cur.id } ?? 0
        activeListTag = snap.listTag
        applyPlayMode(mode(for: snap.listTag))
        updateNavFlags()
        Log.i("Player", "restore cur='\(cur.title)' ctx=\(queue.count)@\(queueIndex) tag='\(snap.listTag)' mode=\(playMode.logName)")
        playEpisode(cur, autoplay: false)
    }

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

    /// - Parameter autoplay: `false` = 预载(冷启动恢复用)。装上 item、跳到续播点、把进度与
    ///   Now Playing 画出来,但**不 play()** —— 启动即出声是用户没要求的动作(见 `restoreState()`)。
    /// **先解析、后提交**(2026-10-31,见 H232;Android `PlayerController.kt` 同序):
    /// 视频源的伪地址要先联网换直链,而这一步会失败。原先的写法是先 `current = episode` 再解析,
    /// 一旦失败,播放条与播放页已经切到新的一集、声音却还是原来那一集,而且没有任何失败提示的
    /// 落点 —— `playbackError` 按「当前这一集」挂,当前集恰好就是那一集错的(见 H232)。
    /// 现在起播的一切可见后果(`current` / 历史 / 播放态快照 / 播放器 item)都在**直链到手之后**
    /// 才发生;解析失败只弹一条提示,当前一集与它的声音原样不动。
    private func playEpisode(_ episode: Episode, isRadio: Bool = false, autoplay: Bool = true) {
        // 每次起播都换代号:伪地址要先解析直链,而解析回来时用户可能已经点了别的集。
        // **判据只能是代号** —— 提交已经挪到解析之后,解析期间 `current` 还是上一集,
        // 拿 `current?.id` 比对会把每一次解析结果都判成"作废"。
        playGeneration += 1
        let generation = playGeneration

        // 选源三级,与 Android `PlayerController.kt` 同序:**下载 > 缓存 > 流式**。
        // 下载是用户点名留的那份;缓存是本类上一条流式播完之后自己攒的。
        // 缓存命中要记一次访问 —— 淘汰只看「最后一次从缓存起播」,不记的话常听的那集会
        // 因为写入时间太早而被先挤掉,预算就白设了(见 AudioCacheStore.touch)。
        let downloaded = localFileProvider?(episode)
        let cached = downloaded == nil ? audioCache?.localURL(episode.id) : nil
        let local = downloaded ?? cached

        // **视频源的最后一步是「现取直链」**,而它要联网 —— 所以只在流式这一路分叉:
        // 本地有下载件或缓存件时,它与普通单集没有任何区别(缓存里存的是当次解析出的直链)。
        //
        // 为什么不能把直链在检索时就算好存进 Episode:那条链的 `deadline` 是取链时刻
        // **+2 小时**(实测),而 Episode 会进历史、进待播、进播放态快照,甚至进备份 ——
        // 存直链等于第二天点开必然「这一集播不了」,且用户没有任何线索知道要重新搜一次。
        // 所以模型里存的是 `bilibili://audio/<bvid>/<cid>` 这个坐标,见 `BilibiliSource`。
        if local == nil && BilibiliSource.isPseudo(episode.audioUrl) {
            guard let resolve = resolvePseudoUrl else {
                Log.e("Player", "bilibili 解析器未绑定 id=\(episode.id)")
                notifyUnplayable(episode, userInitiated: autoplay)
                return
            }
            Log.i("Player", "解析直链开始 id=\(episode.id)")
            Task { @MainActor [weak self] in
                let resolved = await resolve(episode.audioUrl)
                guard let self else { return }
                // 解析期间用户点了别的集:这次作废。不能省 —— 起播只差一次网络往返,
                // 而「点一下看看、随即划走」正好落在这个时长里,不拦就会把前一集的声音抢回来。
                guard self.playGeneration == generation else {
                    Log.i("Player", "解析结果作废 id=\(episode.id)")
                    return
                }
                guard let resolved, let stream = URL(string: resolved.url) else {
                    Log.w("Player", "解析直链失败,保持当前一集 id=\(episode.id)")
                    self.notifyUnplayable(episode, userInitiated: autoplay)
                    return
                }
                Log.i("Player", "解析直链成功 id=\(episode.id) 时长=\(resolved.durationSec)s")
                self.commitAndPlay(episode, url: stream, source: "网络", isRadio: isRadio,
                                   autoplay: autoplay, downloaded: nil, cached: nil, resolved: resolved)
            }
            return
        }

        guard let url = local ?? URL(string: episode.audioUrl) else {
            Log.e("Player", "playEpisode 无效音频 URL id=\(episode.id) title=\"\(episode.title)\" audioUrl=\(episode.audioUrl)")
            notifyUnplayable(episode, userInitiated: autoplay)
            return
        }
        commitAndPlay(episode, url: url,
                      source: downloaded != nil ? "本地" : (cached != nil ? "缓存" : "网络"),
                      isRadio: isRadio, autoplay: autoplay,
                      downloaded: downloaded, cached: cached, resolved: nil)
    }

    /// 可播放的地址到手之后**提交这次起播**,再做剩下的装载。
    /// 抽出来是因为视频源的直链要异步现取(见 `playEpisode`),取回来之后的步骤与普通单集
    /// 一模一样 —— 复制一份就意味着以后改起播逻辑要改两处。
    ///
    /// - Parameter url: 本地文件地址(下载件 / 缓存件)或流式地址,交给 `attach` 统一成 `AVPlayerItem`
    /// - Parameter resolved: 非空 = 这一集是视频源、地址刚解析出来(时长更正与缓存走这条)
    private func commitAndPlay(_ episode: Episode, url: URL, source: String,
                               isRadio: Bool, autoplay: Bool,
                               downloaded: URL?, cached: URL?,
                               resolved: BilibiliSource.ResolvedStream?) {
        // 电台的退出放在**提交之后**:解析失败时用户听着的那一台不该被顺手停掉
        if !isRadio && radioMode { stopRadio() }
        lastIsRadio = isRadio
        lastAutoplay = autoplay
        playbackError = nil
        notice = nil   // 新一集真的起播了,上一条「播不了」就该收掉
        current = episode
        // 与 Android 同位置:**换集就落一次盘**,不等播放器就绪 —— 冷启动要恢复的是
        // 「上次在播哪一集」,而那一集恰恰可能是这次没加载成功的那一集。
        persistState()
        positionMs = 0
        durationMs = 0
        listenStats?.flush()   // 结算上一集残余
        // 内置引导音频不是一集真正的播客:不进历史、不计收听时长,
        // 否则"收听时长"榜首会是引导音频,「继续收听」里也会挂着它。
        let isGuide = GuideEpisode.isGuide(episode.id)
        // 直播流不是"一集节目":没有起止,也就没有"听到哪了"可记。进度、历史、统计三样全关
        // (见 `saveProgress` / `countListening` / `observeEnd` 三处同一条闸)。
        if !isGuide && !episode.isLive { history?.record(episode, at: Date().timeIntervalSince1970) }
        // 起点有三个来源,优先级就按写的这个顺序:
        // ① 调用方明确指定的那一秒(批注)—— 消费掉 override,只生效一次;
        // ② 引导音频与直播流永远从头;③ 否则才是续播进度。
        let resumeMs: Int
        if startMsOverride >= 0 {
            resumeMs = startMsOverride
            startMsOverride = -1
            pendingSeekExplicit = true
        } else if isGuide || episode.isLive {
            resumeMs = 0
            pendingSeekExplicit = false
        } else {
            resumeMs = history?.positionFor(episode.id) ?? 0
            pendingSeekExplicit = false
        }
        // 统计基线对齐到续播起点,避免把 resume 跳转记成收听
        lastCountedEpId = episode.id
        lastCountedPosMs = resumeMs

        let local = downloaded ?? cached
        if cached != nil { audioCache?.touch(episode.id) }

        if let resolved {
            // 解析结果里还带着**这一 P 的真实时长**:搜索给多 P 视频的是整条总和
            // (见 `BilibiliSource.ResolvedStream`)。它必须在起播前落进这一集的元数据,
            // 否则 `attach` 里那个「显式跳转上限」和历史行都建立在一个人为放大的数上。
            var ep = episode
            if resolved.durationSec > 0 && resolved.durationSec != episode.durationSec {
                ep.durationSec = resolved.durationSec
                current = ep
                // **队列与待播里那两份也得换掉**。`persistState` 写的是 `queue` / `userQueue`,
                // 只改 `current` 会留下「快照里 current=1127s、context=27426s」——
                // 冷启动恢复队列、队列面板里那条错数会重新冒出来(Android 先验出来的,见 H228)。
                // 用 id 守一道:解析是一次网络往返,期间用户可能已经切走。
                if queueIndex >= 0, queueIndex < queue.count, queue[queueIndex].id == ep.id {
                    queue[queueIndex] = ep
                }
                if let i = userQueue.firstIndex(where: { $0.id == ep.id }) {
                    userQueue[i] = ep
                }
                // 上面那次 record 写的是旧元数据。同 id 再记一次 = 原地换掉那份载荷、
                // 进度与顺序都不动(HistoryStore.record 保留既有 position)。
                if !GuideEpisode.isGuide(ep.id) {
                    history?.record(ep, at: Date().timeIntervalSince1970)
                }
                persistState()
                Log.i("Player", "时长更正 \(episode.durationSec)s -> \(ep.durationSec)s id=\(episode.id)")
            }
            // 缓存必须在解析之后:缓存模块拿的是 `audioUrl`,伪地址它拉不下来
            // (会当成畸形 URL 立刻失败,而账本里留一条永远下不完的条目)。
            // 头也要一起给:CDN 认 UA + `Referer`,缺一个 403(见 `BilibiliSource.uaBrowser`)。
            if !isRadio {
                var cachedCopy = ep
                cachedCopy.audioUrl = resolved.url
                audioCache?.cache(cachedCopy, headers: BilibiliSource.streamHeaders)
            }
            attach(ep, url: url, source: source, resumeMs: resumeMs,
                   autoplay: autoplay, isRadio: isRadio,
                   assetHeaders: BilibiliSource.streamHeaders,
                   assetMime: BilibiliSource.streamMime)
            return
        }

        // 只有真正在走流式时才排一次整集落缓存。电台那一路不缓存 —— 它是漫游,
        // 下一集由随机推荐决定;把每一集都留在盘上等于用 300 MB 换一份听不回去的清单。
        if local == nil && !isRadio && !episode.isLive { audioCache?.cache(episode) }
        attach(episode, url: url, source: source, resumeMs: resumeMs, autoplay: autoplay, isRadio: isRadio)
    }

    /**
     「刚才点的那一集起不来」——只说不做:当前一集、播放器、历史、快照全都不动。

     - Parameter userInitiated: 是否用户主动点播。冷启动恢复(`autoplay == false`)失败不提示:
       那时用户没做任何动作,弹一条只会莫名其妙;而 `lastAutoplay` 那条"恢复现场不恢复意图"
       的口径在这里同样适用。
     */
    private func notifyUnplayable(_ episode: Episode, userInitiated: Bool) {
        Log.w("Player", "播不了,保持当前一集 id=\(episode.id) title=\"\(episode.title)\" user=\(userInitiated)")
        guard userInitiated else { return }
        noticeToken += 1
        let token = noticeToken
        notice = String(localized: "这一集暂时播不了")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }

    /// 装载并起播。抽出来是因为视频源的直链要**异步**现取(见 `playEpisode` 那条分支):
    /// 取回来之后剩下的步骤与普通单集一模一样 —— 复制一份就意味着以后改起播逻辑要改两处。
    ///
    /// - Parameter url: 本地文件地址(下载件 / 缓存件)或流式地址,在这里统一成 `AVPlayerItem`
    /// - Parameter assetHeaders: 取流要带的请求头。空 = 普通 RSS 单集,走默认 item
    /// - Parameter assetMime: 出带 MIME(视频源的 `.m4s` 必需,见下)
    private func attach(_ episode: Episode, url: URL, source: String, resumeMs: Int,
                        autoplay: Bool, isRadio: Bool,
                        assetHeaders: [String: String] = [:], assetMime: String? = nil) {
        Log.i("Player", "playEpisode id=\(episode.id) title=\"\(episode.title)\" feed=\"\(episode.podcastTitle)\" radio=\(isRadio) 源=\(source) resume=\(resumeMs)ms")
        // **视频源的直链只能这样交给 AVPlayer**,三样缺一不可(2026-10-28 本机逐条实测):
        // ① `AVPlayerItem(url:)` 不带头 ⇒ AVPlayer 发自己的 `AppleCoreMedia/…` UA ⇒ CDN 403;
        // ② 只注 `AVURLAssetHTTPHeaderFieldsKey` ⇒ item `failed`(`Cannot Open`)——
        //    直链路径以 `.m4s` 结尾、响应头是 `application/octet-stream`,AVFoundation 认不出容器;
        // ③ 再加 `AVURLAssetOutOfBandMIMETypeKey: "audio/mp4"` ⇒ readyToPlay,dur 正常。
        // 本地文件那一路不要头也不要 MIME(缓存落盘时已改名 `.m4a`,见 `AudioCacheManager.fileName`)。
        let item: AVPlayerItem
        if assetHeaders.isEmpty && assetMime == nil {
            item = AVPlayerItem(url: url)
        } else {
            var options: [String: Any] = [:]
            if !assetHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = assetHeaders }
            if let assetMime { options["AVURLAssetOutOfBandMIMETypeKey"] = assetMime }
            item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        }
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
        if autoplay {
            player.volume = 0
            player.play()
            player.rate = Float(speed)
            fadeVolume(to: 1.0, durationMs: 900)
        } else {
            // 预载:音量直接给 1(下一首按下播放时不该又淡入一次),且**不能**靠 ticker 画进度 ——
            // ticker 只在播放中跑,而预载永远不会播,不在这里画的话进度线停在 0:00。
            player.volume = 1
            if ok { positionMs = resumeMs }
            Log.i("Player", "预载(暂停) id=\(episode.id) resume=\(resumeMs)ms")
        }
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
                if self.current?.id == episode.id { self.playEpisode(episode, isRadio: isRadio, autoplay: self.lastAutoplay) }
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
        persistState()
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
        // 一次落盘,不是每条一次:与 Android 同口径(那边这条注释里量过「全选 1994 集 × 每次全量写盘」
        // 把主线程占满、系统弹无响应,见 H186)。批量入队是唯一会一次改几百条队列的入口。
        persistState()
        return fresh.count
    }

    /// 插入到队首,作为「下一个播放」(已存在则移动到队首)。
    func playNext(_ ep: Episode) {
        userQueue.removeAll { $0.id == ep.id }
        userQueue.insert(ep, at: 0)
        Log.i("Queue", "playNext id=\(ep.id) title=\"\(ep.title)\" 队列=\(userQueue.count)")
        updateNavFlags()
        persistState()
    }

    func removeFromQueue(_ id: String) {
        userQueue.removeAll { $0.id == id }
        Log.i("Queue", "removeFromQueue id=\(id) 队列=\(userQueue.count)")
        updateNavFlags()
        persistState()
    }

    /// 队列内重排。offsets 遵循 SwiftUI onMove 语义。
    func moveInQueue(from: Int, to: Int) {
        guard from >= 0, from < userQueue.count, from != to else { return }
        let ep = userQueue.remove(at: from)
        let dest = to > from ? to - 1 : to
        userQueue.insert(ep, at: min(max(dest, 0), userQueue.count))
        persistState()
    }

    func clearQueue() {
        guard !userQueue.isEmpty else { return }
        Log.i("Queue", "清空播放队列 \(userQueue.count) 条")
        userQueue.removeAll()
        updateNavFlags()
        persistState()
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

    /// 关闭播放条(底部条上那枚 X):停止播放并清掉「正在播」的上下文。
    /// 语义与 Android / 鸿蒙的 `close` 同一条 —— `current` 置空(底部条的显隐门),
    /// 上下文队列清掉,**`userQueue` 保留**(用户排的队是用户数据,持久化写
    /// 「无 current、留 upNext」而不是 `PlaybackStateStore.clear()`),下次起播条子照常回来。
    ///
    /// 顺序上先 `current = nil` 再 `pause()`:pause 触发的 KVO 里 `saveProgress` 有
    /// `guard current` 守卫,先清可保证迟到的回调一律短路;`handleLoadFailure` 的在途
    /// 重试同样按 `current?.id` 守卫自弃。`cancelSleep` 与 `stopRadio` 与两端同口径显式调。
    func close() {
        Log.i("Player", "close id=\(current?.id ?? "-")")
        // 作废在途的直链解析:否则那条 Task 回来时会把用户已经关掉的这一集重新装上(H232)
        playGeneration += 1
        if radioMode { stopRadio() }
        cancelSleep()
        current = nil
        player.pause()
        isPlaying = false
        playbackError = nil
        notice = nil
        loadRetries = 0
        queue = []
        queueIndex = 0
        persistState()
        updateNavFlags()
    }

    /// 随机电台**该排除的最近听过的单集 id**(末尾 `radioRecentCap` 个)。
    ///
    /// 为什么在播放器这里出,而不是让发现页自己攒:这份「最近」只有一个真值,就是电台
    /// 实际播过的那条流水;界面侧另存一份必然和它漂移,而发现页本来也不关心它。
    /// Android 侧同一件事在 `playback/RadioStation.kt` 里由 `recent` 队列提供
    /// (见 REVIEW-2026-10-25 族 E),macOS 原先两处都传 `exclude: []`,
    /// 于是随机抽到的候选池只有 6 个频道 × 各自若干集 —— 连着几首重复播同一集是常态。
    ///
    /// 取的是 `radioHistory` 的**末尾** N 个:那张表是追加式的(超 `radioHistoryCap` 丢最旧),
    /// 末尾就是最近。
    /// ⚠️ 与 Android 有一处**已知差异**,不是漏改:本端 `startRadio` 会把 `radioHistory` 清空
    /// (那张表同时是电台「上一首/下一首」的导航栈,开台必须从头),所以开台后的第一次抽取不排除任何集;
    /// Android 那份 `recent` 是 `RadioStation` 单例里的进程级队列,开关台都不清,第一次抽取就带着上一次的记忆。
    /// 要对齐那条得把「去重用的 recent」和「导航用的 history」拆成两张表,本轮不拆。
    func recentRadioIds() -> Set<String> {
        Set(radioHistory.suffix(radioRecentCap).map { $0.id })
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
        // 直播流没有可跳的时间轴:播放器还没报出时长时,durationMs 是 0,
        // 拖到任何位置都只会把进度线画到一个假坐标上。有进度(点了播客文件)才放行。
        if current?.isLive == true && durationMs <= 0 {
            Log.i("Player", "直播流无时间轴,忽略拖动 \(t)ms")
            return
        }
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
                // 直播流的"结束"只意味着这一路断了或停播了:**不记已播、不接下一集**。
                // 否则用户本来在听电台,流一断就被换成队列里另一集,听感上像被偷换了台。
                if self.current?.isLive == true {
                    Log.i("Player", "直播结束,不续播 id=\(self.current?.id ?? "-")")
                    self.listenStats?.flush()
                    return
                }
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
        // 直播流不写进度:它的"位置"是这一路流自己的时间刻度,与用户听没听过无关,
        // 写进历史还会让「继续收听」横条凭空多出一条永远"听到一半"的电台。
        if ep.isLive { return }
        // 「刚起播、续播点还没落地」那一瞬间不写盘(见 REVIEW-2026-10-25 中-6)。
        //
        // 竞态的来源:`playEpisode` 先把 `positionMs = 0`,再在后面才 `seek(to: resumeMs)`;
        // 而 `statusObserver` 的回调里有一条 `if tickCount % 10 == 0 { saveProgress() }`,
        // 它和 seek 谁先到没有保证。命中时就把 0 写进了 history,下次进这一集从头播 ——
        // 用户感知是"续播丢了",而且只在起播那一下发生,最难复现。
        //
        // 判据取「positionMs == 0 **且** durationMs == 0」这一对,而不是只看 positionMs == 0,
        // 因为下面两路都合法地写着 0,不能误伤:
        // ① 自然播完归零走的是 `observeEnd` 里那条**显式** `updatePosition(positionMs: 0)`,
        //    它根本不经过 saveProgress,所以这道守卫碰不到它;
        // ② 暂停落盘(saveProgress 的另一条触发路径)发生在播了任意时长之后,
        //    此时 `durationMs` 早已被 `onTick` 填上,两个条件不会同时成立。
        // 于是"两个都是 0"只剩一种解释:时长还没被读到、位置也还没被 seek 落过,这一次写盘没有信息量。
        //
        // ⚠️ 体检原文里那句「重试耗尽即确定性归零」**经复核不成立**:
        // `handleLoadFailure` 的耗尽分支只写 `playbackError`,不碰进度;
        // 而且加载失败时 ticker 不再推进,`% 10` 那条本来也不会再触发。
        // 所以本条真正的问题只有上面这个 `%10` 竞态,修的就只是这一道守卫。
        if positionMs == 0 && durationMs == 0 { return }
        history?.updatePosition(ep.id, positionMs: max(0, positionMs), durationMs: max(0, durationMs))
    }

    /// 累计"实际播放过的内容毫秒":仅当同一集、播放中、且增量为合理正向值(1..3000ms)时计入。
    /// 快进/快退的大跳变(越界)与暂停(增量≈0)自然被剔除;倍速下按内容时长计。
    private func countListening() {
        guard let ep = current else { lastCountedEpId = ""; return }
        if GuideEpisode.isGuide(ep.id) { return }   // 引导音频不计时长
        if ep.isLive { return }   // 直播流同样不计:没有"内容长度"这个概念,累计只会是挂机时长
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
