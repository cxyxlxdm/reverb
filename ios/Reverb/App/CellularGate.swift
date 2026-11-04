import Foundation
import Network

/// 「这次 App 擅自发起的大流量该不该被计费链路拦下」的 iOS 判据。
///
/// 与 Android `util/CellularGate.kt` / 鸿蒙 `util/CellularGate.ets` 是**同一条规则**:
/// 设置里的「仅在 Wi-Fi 下载」开着(即 `allow_cellular_download == false`)时,
/// 计费链路上不放行。三条大流量路径共用这一份 ——
/// 点名下载(`DownloadManager`)、首播落缓存(`AudioCacheManager`)、转录前下载整集
/// (`TranscriptStore`)。判据抄成两份时漏掉第三个调用点是必然的(REVIEW-2026-10-25 中-3),
/// 所以这里**只允许有一个入口**。
///
/// 口径:
///  - 用 `NWPath.isExpensive || isConstrained`。iOS 上蜂窝与个人热点都标 `isExpensive`,
///    低数据模式标 `isConstrained` —— 与 Android 的 `isActiveNetworkMetered` 一样,
///    拦的是「按量计费」而不是「链路名字里有没有 Wi-Fi」。
///  - 开关**从 UserDefaults 直读**、不走 `SettingsStore`:下载与缓存两条调用点在非主 actor
///    的路径上,为了一个布尔跳一次 actor 既贵又容易写出死锁。键名与 `SettingsStore` 是同一个
///    (`allow_cellular_download`),这里是读它、不是另存一份。
///  - 取不到网络状态时**放行**(宁可少拦一次,也不把功能整个钉死)—— 与 Android 那条
///    `cm == null → false` 同向。`NWPathMonitor` 是异步投递,App 启动后最初的一小段时间里
///    还没有读数,那期间也按放行处理。
enum CellularGate {
    private static let monitor = NWPathMonitor()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var metered = false
    nonisolated(unsafe) private static var started = false

    /// 开始监听链路。App 启动时调一次;`blocked()` 里也会兜底调一次。
    static func start() {
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        guard !already else { return }
        monitor.pathUpdateHandler = { path in
            lock.lock()
            metered = path.isExpensive || path.isConstrained
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.yuyin.reverb.cellular-gate"))
    }

    /// 这一次大流量该不该被拦下。**同步**,任何线程都能调。
    static func blocked() -> Bool {
        let allow = UserDefaults.standard.object(forKey: "allow_cellular_download") as? Bool ?? false
        if allow { return false }
        start()
        lock.lock()
        defer { lock.unlock() }
        return metered
    }
}
