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
    let listenStats = ListenStatsStore()
    /// 跨启动的播放态。文件名与字段和 Android / 鸿蒙 / macOS 是**同一份**
    /// (`playback_state.json`),四端可互读。
    let playbackState: PlaybackStateStore

    init() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        Log.i("App", "启动 余音 Reverb v\(version) (\(build)) iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        downloadManager = DownloadManager(store: downloads)
        playbackState = PlaybackStateStore()
        player.bind(history: history, settings: settings)
        player.bindListenStats(listenStats)
        listenStats.seedFromHistory(history.history)
        player.localFileProvider = { [downloads] ep in downloads.localURL(ep.id) }
        player.bindAudioCache(audioCache)
        let repo = repository
        player.resolvePseudoUrl = { url in await repo.bilibili.resolvePlayback(url) }
        player.bindState(playbackState)
        // 依赖都绑好之后再恢复:预载要能命中本地下载文件,续播起点要读历史。
        player.restoreState()

        #if DEBUG
        // 模拟器没有可用的点击注入工具时,用启动参数验证整条播放链:
        // `simctl launch … com.yuyin.reverb -autoplay-guide`。
        // 只在 Debug 编译,Release / TestFlight 包里不存在这段。
        if ProcessInfo.processInfo.arguments.contains("-autoplay-guide"),
           let guide = GuideEpisode.make() {
            player.playQueue([guide], startIndex: 0)
        }
        #endif

        for pub in [subscriptions.objectWillChange, favorites.objectWillChange,
                    history.objectWillChange, stamps.objectWillChange, notes.objectWillChange,
                    inbox.objectWillChange,
                    downloads.objectWillChange, downloadManager.objectWillChange] {
            pub.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        }

        let lang = settings.language.isEmpty ? "auto(\(Locale.preferredLanguages.first ?? "?"))" : settings.language
        Log.i("App", "本地数据就绪 region=\(region) language=\(lang) 订阅=\(subscriptions.subscriptions.count) 收藏=\(favorites.favorites.count) 历史=\(history.history.count) 印记=\(stamps.stamps.count) 批注=\(notes.notes.count) 下载=\(downloads.downloads.count)")
    }

    /// 当前生效地区:设置覆盖优先,否则跟随系统区域,再退化为 us。
    var region: String {
        if !settings.regionOverride.isEmpty { return settings.regionOverride }
        let r = Locale.current.region?.identifier ?? "US"
        return r.lowercased()
    }
}