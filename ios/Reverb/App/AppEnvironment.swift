import SwiftUI
import Combine

/// 手写依赖容器:仓库 + 各本地存储 + 播放器,经 SwiftUI environment 注入全局。
/// 与 macOS 版同一套组件、同一批落盘文件;差别只有「没有桌面自更新」这一项。
@MainActor
final class AppEnvironment: ObservableObject {
    private var bag = Set<AnyCancellable>()
    let repository = PodcastRepository()
    let subscriptions = SubscriptionStore()
    let favorites = FavoriteStore()
    let history = HistoryStore()
    let stamps = StampStore()
    let notes = NoteStore()
    let inbox = InboxStore()
    let settings = SettingsStore()
    let player = PlayerController()
    let downloads = DownloadStore()
    let downloadManager: DownloadManager
    let audioCache = AudioCacheManager()
    let transcripts = TranscriptStore()
    /// 章表:只在用户点开弹层时变一次,频率极低 —— 转发到 env,播放页直接观察 env 即可。
    let chapters = ChapterStore()
    let listenStats = ListenStatsStore()
    /// 跨启动的播放态。文件名与字段和 Android / 鸿蒙 / macOS 是**同一份**
    /// (`playback_state.json`),四端可互读。
    let playbackState: PlaybackStateStore
    /// 订阅更新提醒的巡检(后台任务 + 本地通知)。macOS 没有这一套:桌面是拉取式,
    /// 打开追更才刷,见 `SettingsStore.updatesEnabled` 的注释。
    let updates: UpdateReminders
    /// 全局轻提示。下载被计费链路拦下这类「用户点了但什么都没发生」的事件必须说出来。
    let toast = ToastCenter()

    init() {
        updates = UpdateReminders(repository: repository, subscriptions: subscriptions)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        Log.i("App", "启动 余音 Reverb v\(version) (\(build)) iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        downloadManager = DownloadManager(store: downloads, feedAuth: repository.authStore)
        playbackState = PlaybackStateStore()
        // 「仅在 Wi-Fi 下载」的闸门:iOS 有三条大流量路径(点名下载 / 首播落缓存 / 转录前下整集),
        // 判据只有 `CellularGate` 一份,这里把它接到三个入口上。macOS 的三处闭包保持 nil(不拦)。
        CellularGate.start()
        downloadManager.allowsTransfer = { !CellularGate.blocked() }
        downloadManager.onBlocked = { [weak self] ep in
            self?.toast.show(NSLocalizedString("仅 Wi-Fi 下载已开启，连接到 Wi-Fi 后再试", comment: "下载被闸门拦下"))
            Log.i("Download", "界面提示已拦下 id=\(ep.id)")
        }
        audioCache.allowsTransfer = { !CellularGate.blocked() }
        transcripts.allowsTransfer = { !CellularGate.blocked() }
        player.bind(history: history, settings: settings)
        player.bindListenStats(listenStats)
        listenStats.seedFromHistory(history.history)
        player.localFileProvider = { [downloads] ep in downloads.localURL(ep.id) }
        player.bindAudioCache(audioCache)
        // 私有订阅源:401 要弹输入框、音频直链与官方稿要带同一个 `Authorization`。
        player.bindFeedAuth(repository.authStore)
        transcripts.authHeaderProvider = { [repository] url in repository.authHeader(for: url) }
        // 章表与 feed / 音频 / 官方稿走同一个凭据判据(见 H253),不另写主机匹配。
        chapters.authHeaderProvider = { [repository] url in repository.authHeader(for: url) }
        subscriptions.onRemoved = { [repository] p in repository.forgetAuth(p.feedUrl) }
        let repo = repository
        player.resolvePseudoUrl = { url in await repo.bilibili.resolvePlayback(url) }
        player.bindState(playbackState)
        // 依赖都绑好之后再恢复:预载要能命中本地下载文件,续播起点要读历史。
        player.restoreState()
        // 桌面卡片是**另一个进程**:这里只把「上次听到哪」写进 App Group 容器,
        // 由扩展自己去读。没签名到组容器时它只记一行日志,App 照常可用。
        WidgetBridge.shared.start(player: player, history: history, settings: settings)

        // 卡片上的播放 / 暂停 / 切集:AudioPlaybackIntent 把动作交回 App 执行(不拉界面)。
        // 进程被系统从后台拉起时 AppEnvironment 也会照常构建,所以注册一次就够。
        // 未同意隐私时一个动作都不做 —— 与主界面那条启动门同一条(连播放器都会读网络状态)。
        WidgetCommandCenter.handler = { [weak self] command in
            guard let self else { return }
            Task { @MainActor in
                guard self.settings.privacyAccepted else { return }
                switch command {
                case .toggle: self.player.togglePlayPause()
                case .previous: self.player.previous()
                case .next: self.player.next()
                }
            }
        }

        #if DEBUG
        // 模拟器没有可用的点击注入工具时,用启动参数验证整条播放链:
        // `simctl launch … com.yuyin.reverb -autoplay-guide`。
        // 只在 Debug 编译,Release / TestFlight 包里不存在这段。
        let launchArgs = ProcessInfo.processInfo.arguments
        if launchArgs.contains("-autoplay-guide"), var guide = GuideEpisode.make() {
            // 章节态验收要一集"有章表"的节目,而引导音频本身没有 —— 允许启动参数临时挂一份:
            // `-autoplay-guide -chapters-url http://127.0.0.1:8099/chapters.json`。
            // 走的仍是界面上的同一条链(入口 → 弹层 → 请求 → 跳转),只有数据来源是夹具。
            if let i = launchArgs.firstIndex(of: "-chapters-url"), i + 1 < launchArgs.count {
                guide.chaptersUrl = launchArgs[i + 1]
                guide.chaptersType = "application/json"
            }
            player.playQueue([guide], startIndex: 0)
        }
        // 同类第二条:直播流要**点一下结果行**才开始,而模拟器没有点击注入。
        // `simctl launch … -play-live <流地址>` 直接走 `LiveStream.resolve` 再入队,
        // 用来验收播放页的直播态(无进度条 / 无倍速 / 快进快退与上下集禁用 / 不记历史)。
        // 判据与用户粘贴同一条路径 —— 这里一个分支都不绕过,否则验的就不是那条链。
        let liveArgs = ProcessInfo.processInfo.arguments
        if let i = liveArgs.firstIndex(of: "-play-live"), i + 1 < liveArgs.count {
            let raw = liveArgs[i + 1]
            Task { @MainActor in
                if let live = await LiveStream.resolve(raw) {
                    player.playQueue([live], startIndex: 0)
                }
            }
        }
        #endif

        for pub in [subscriptions.objectWillChange, favorites.objectWillChange,
                    history.objectWillChange, stamps.objectWillChange, notes.objectWillChange,
                    inbox.objectWillChange,
                    chapters.objectWillChange,
                    downloads.objectWillChange, downloadManager.objectWillChange] {
            pub.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        }

        let lang = settings.language.isEmpty ? "auto(\(Locale.preferredLanguages.first ?? "?"))" : settings.language
        Log.i("App", "本地数据就绪 region=\(region) language=\(lang) 订阅=\(subscriptions.subscriptions.count) 收藏=\(favorites.favorites.count) 历史=\(history.history.count) 印记=\(stamps.stamps.count) 批注=\(notes.notes.count) 下载=\(downloads.downloads.count)")

        // 后台任务注册必须在启动早期完成(Info.plist 里已申报同一个 identifier)。
        // `updatesEnabled` 关着时它只撤销排期,不发通知。
        updates.registerBackgroundTask()
    }

    /// 当前生效地区:设置覆盖优先,否则跟随系统区域,再退化为 us。
    var region: String {
        if !settings.regionOverride.isEmpty { return settings.regionOverride }
        let r = Locale.current.region?.identifier ?? "US"
        return r.lowercased()
    }
}

/// 全局轻提示。手机上只活两秒多,不阻塞任何操作 —— 用来回答「我点了,怎么没反应?」。
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var text: String?
    private var token = 0

    func show(_ value: String) {
        token += 1
        let mine = token
        text = value
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if token == mine { text = nil }
        }
    }
}