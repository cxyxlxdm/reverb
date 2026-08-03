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
    let settings = SettingsStore()
    let player = PlayerController()
    let downloads = DownloadStore()
    let downloadManager: DownloadManager

    init() {
        downloadManager = DownloadManager(store: downloads)
        player.bind(history: history, settings: settings)
        player.localFileProvider = { [downloads] ep in downloads.localURL(ep.id) }

        // 把低频本地存储的变更转发到自身,使观察 env 的视图能即时刷新(订阅/收藏/印记/历史/下载)。
        // 不转发高频的 player(每 0.5s 进度)/settings,以免整树无谓重渲。
        for pub in [subscriptions.objectWillChange, favorites.objectWillChange,
                    history.objectWillChange, stamps.objectWillChange,
                    downloads.objectWillChange, downloadManager.objectWillChange] {
            pub.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    /// 当前生效地区:设置覆盖优先,否则跟随系统区域,再退化为 us。
    var region: String {
        if !settings.regionOverride.isEmpty { return settings.regionOverride }
        let r = Locale.current.region?.identifier ?? "US"
        return r.lowercased()
    }
}
