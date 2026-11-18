import Foundation
import ActivityKit

/// 把播放器状态推成 **Live Activity**(锁屏 / 灵动岛)。
///
/// 为什么与主屏卡片共用 `WidgetBridge` 的那一拍:两者要的是同一组字段(集名、频道名、
/// 进度、是否在播、深浅色),再起一条 5 秒定时器只会让两处读数错开。`WidgetBridge.flush()`
/// 在算完 `WidgetState` 之后调这里,本类只负责"起 / 更新 / 撤"这一个生命周期。
///
/// 三条产品口径:
///  - **只在真的在播时起**。暂停不算 —— 否则每次启动 App 都会因为历史里有一条"听到一半"
///    的记录而常驻一条锁屏卡片;
///  - **暂停后保留**(可以就地续播),15 分钟没有恢复就视为不再听(`staleDate` + 到时撤下);
///  - **换集 / 结束播放立即撤旧的**:同一时刻只允许一条,避免锁屏上叠两张。
///
/// 进度用绝对时间锚点外推(见 `PlaybackActivityAttributes`):稳态播放时**不按秒 update**,
/// 只有暂停 / 续播 / 拖动 / 换集 / 换主题这类事件才写一次 —— 与"不把播放器变成 1 Hz 网络进程"
/// 是同一条资源口径。
@MainActor
final class PlaybackLiveActivityBridge {
    static let shared = PlaybackLiveActivityBridge()

    private var activity: Activity<PlaybackActivityAttributes>?
    private var lastSignature = ""
    /// 上一次写入时的进度与时刻,用来判断"这是不是一次 seek"。
    private var lastPositionMs = 0
    private var lastAnchor = Date()
    private var pausedSince: Date?

    private let pausedKeepAlive: TimeInterval = 15 * 60

    private init() {}

    /// 由 `WidgetBridge.flush()` 每拍调用。`state` 是已经算好的卡片数据。
    func sync(state: WidgetState, player: PlayerController) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // 没有当前集:把遗留的活动收掉(强退 / 播完后重新启动都会走到这里)
        guard !state.empty, !state.id.isEmpty, let episode = player.current else {
            endAll(reason: "没有在听")
            return
        }

        let playing = player.isPlaying
        if !playing, activity == nil, pausedSince == nil {
            // 冷启动时历史里有一条暂停记录,不代表用户现在在听
            return
        }

        let now = Date()
        if playing {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = now
        }
        if let since = pausedSince, now.timeIntervalSince(since) > pausedKeepAlive {
            endAll(reason: "暂停超过 15 分钟")
            return
        }

        // 播放中每 5 秒一拍都会进来;只有"事件"才值得 update。进度靠 anchor 外推,
        // 偏离预期 3 秒以上说明用户拖了进度,必须重锚。
        let signature = [
            state.id, state.title, state.podcast,
            playing ? "1" : "0", state.dark ? "1" : "0",
            String(format: "%.2f", player.speed)
        ].joined(separator: "\u{1F}")
        // 进度是毫秒,dt 是秒 —— 乘 1000 之后再比。少了这个 1000 不会崩,
        // 只会让"每拍都偏离 ≥3 秒"这条件恒真,于是每次 flush 都 update(2026-11-15 实测:每 5 秒一次)。
        let dt = now.timeIntervalSince(lastAnchor)
        let expected = Double(lastPositionMs) + dt * player.speed * 1000
        let drift = abs(Double(player.positionMs) - expected)
        let seeked = playing && drift > 3_000
        let same = activity?.attributes.episodeId == state.id

        guard signature != lastSignature || seeked || !same else { return }

        let duration = max(player.durationMs, 0)
        let content = PlaybackActivityAttributes.ContentState(
            title: state.title,
            podcast: state.podcast,
            playing: playing,
            live: episode.isLive,
            positionMs: max(player.positionMs, 0),
            durationMs: episode.isLive ? 0 : duration,
            rate: max(player.speed, 0.5),
            dark: state.dark,
            anchor: now
        )
        let staleDate: Date? = playing ? nil : now.addingTimeInterval(pausedKeepAlive)
        let wrapped = ActivityContent(state: content, staleDate: staleDate)
        let attrs = PlaybackActivityAttributes(episodeId: state.id)

        if same, let current = activity {
            Task { await current.update(wrapped) }
        } else {
            endAll(reason: "换集")
            do {
                activity = try Activity.request(attributes: attrs, content: wrapped, pushType: nil)
                Log.i("LiveActivity", "已开始 id=\(state.id) playing=\(playing)")
            } catch {
                // 最常见的原因是用户在系统设置里关掉了「实时活动」;
                // 这类失败只影响锁屏卡片,不能打断播放。
                Log.w("LiveActivity", "启动失败:\(error.localizedDescription)")
                activity = nil
                lastSignature = ""
                return
            }
        }
        lastSignature = signature
        lastPositionMs = content.positionMs
        lastAnchor = now
    }

    private func endAll(reason: String) {
        let list = Activity<PlaybackActivityAttributes>.activities
        guard !list.isEmpty || activity != nil else { return }
        for a in list {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        if !list.isEmpty { Log.i("LiveActivity", "已结束:\(reason)") }
        activity = nil
        lastSignature = ""
        lastPositionMs = 0
        pausedSince = nil
    }
}
