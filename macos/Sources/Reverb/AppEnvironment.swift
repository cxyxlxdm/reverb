import SwiftUI
import Combine

/// 手写依赖容器:仓库 + 各本地存储 + 播放器,经 SwiftUI environment 注入全局。
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
    // 转录:高频 append,不转发到 env(由 TranscriptPage 直接观察),避免整树重渲。
    let transcripts = TranscriptStore()
    // 收听时长:播放中约每 5s 才刷新一次,单独注入、由相关页面直接观察,不转发到 env。
    let listenStats = ListenStatsStore()
    /// 跨启动的播放态(「正在播哪一集 / 来自哪一列 / 排好的待播」)。
    /// 文件名与字段和 Android / 鸿蒙是**同一份**(`playback_state.json`),三端可互读;
    /// 不转发 objectWillChange —— 它的快照只有播放器自己读,界面看的是 player 那几个 @Published。
    let playbackState: PlaybackStateStore

    init() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        Log.i("App", "启动 余音 Reverb v\(version) (\(build)) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        downloadManager = DownloadManager(store: downloads)
        playbackState = PlaybackStateStore()
        player.bind(history: history, settings: settings)
        player.bindListenStats(listenStats)
        listenStats.seedFromHistory(history.history)   // 首启用历史近似种子(仅当无既有统计)
        player.localFileProvider = { [downloads] ep in downloads.localURL(ep.id) }
        player.bindState(playbackState)
        // 恢复排在**依赖都绑好之后**:预载要能命中本地下载文件(优先本地源),
        // 续播起点要从历史读。它内部只在「当前没有在播的」时执行,重复调用是安全的。
        player.restoreState()

        // 把低频本地存储的变更转发到自身,使观察 env 的视图能即时刷新(订阅/收藏/印记/批注/历史/下载)。
        // 不转发高频的 player(每 0.5s 进度)/settings,以免整树无谓重渲。
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
