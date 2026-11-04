import Foundation
import BackgroundTasks
import UserNotifications

/// 订阅更新提醒(手机端)的巡检与本地通知。与 Android `update/FeedUpdateWorker.kt`
/// 同一口径:
///  - **首次见到某个源只记录、不发通知** —— 装完 App 那一刻不应该被几十条「新一期」轰炸;
///  - 每个源只认「最新一集 id」变了没变(不比发布时间,也不看整列);
///  - 抓取限并发 + 单源超时,慢源跳过、`lastSeen` 不推进 ⇒ 最坏晚一轮提醒,不丢提醒;
///  - 有更新时只发**一条**汇总通知(固定 identifier,新的替换旧的)。
///
/// 与 Android 的差别只有两处,都是平台决定的:
///  - 调度用 `BGAppRefreshTask` 而不是 WorkManager,iOS 不承诺准点,只承诺「大概 6 小时后有机会」;
///  - `lastSeen` 落在 UserDefaults 的字典里(键就是 feedUrl)。Android 那边因为 SharedPreferences
///    键必须短、用了 32 位 hash,还为此加了「值里带 feedUrl 复核」的补丁(见 `UpdateStore.kt`);
///    iOS 直接拿 URL 当键,不存在那个撞键问题,**不要照抄那套补丁**。
@MainActor
final class UpdateReminders {
    /// 必须与 `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 逐字一致,
    /// 否则 `register` 会直接抛异常(不是静默失败)。
    static let taskIdentifier = "com.yuyin.reverb.feed-refresh"

    /// 巡检间隔。Android WorkManager 是 6 小时,iOS 也取 6 小时 —— 系统可以更晚,但不会更早。
    private static let intervalSec: TimeInterval = 6 * 3600
    /// 与 `InboxStore.maxConcurrent`(8)相比让一档:后台别和前台追更刷新抢同一条链路。
    private static let maxConcurrent = 6
    /// 与 `InboxStore.feedTimeoutSec` 同一档(Android 后台那份也是 8 秒)。
    private static let feedTimeoutSec: Double = 8

    private let repository: PodcastRepository
    private let subscriptions: SubscriptionStore
    private var running = false

    init(repository: PodcastRepository, subscriptions: SubscriptionStore) {
        self.repository = repository
        self.subscriptions = subscriptions
    }

    // MARK: - 调度

    /// 在 App 启动早期调一次。重复注册没有害处,但只应注册一次。
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                guard let self else { refresh.setTaskCompleted(success: false); return }
                // 先把下一次排上:本次失败也要继续排,否则一次异常就永久停摆。
                self.scheduleNext()
                let work = Task { await self.run() }
                refresh.expirationHandler = { work.cancel() }
                await work.value
                refresh.setTaskCompleted(success: !work.isCancelled)
            }
        }
        scheduleNext()
    }

    /// 按开关决定是否排下一次。「未开启」时顺手撤销已排的请求。
    func scheduleNext() {
        guard updatesEnabled else {
            cancelScheduled()
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.intervalSec)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.d("Updates", "已排下一次订阅巡检 earliest=+\(Int(Self.intervalSec / 3600))h")
        } catch {
            // 模拟器 / 未在 plist 申报时这里会失败;不致命,前台刷新照常。
            Log.w("Updates", "后台巡检排期失败 \(error.localizedDescription)")
        }
    }

    func cancelScheduled() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    /// 请求通知权限。已授权返回 true;被拒返回 false(界面据此把开关拨回去并说明)。
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    // MARK: - 巡检

    /// 跑一轮。开关关着、没有订阅、上一轮还没收尾都直接返回。
    func run() async {
        guard updatesEnabled else { return }
        guard !running else { Log.d("Updates", "上一轮还在跑,忽略"); return }
        let subs = subscriptions.subscriptions.filter { !$0.feedUrl.isEmpty }
        guard !subs.isEmpty else { Log.d("Updates", "没有订阅,跳过"); return }

        running = true
        defer { running = false }
        let t0 = Date()
        var seen = lastSeen
        var fresh: [String] = []
        let timeout = Self.feedTimeoutSec

        await withTaskGroup(of: (String, [Episode]).self) { group in
            var index = 0
            func addNext() {
                guard index < subs.count else { return }
                let p = subs[index]; index += 1
                let url = p.feedUrl
                group.addTask {
                    let eps = await InboxStore.loadAll(url, repository: self.repository, timeoutSec: timeout)
                    return (url, eps)
                }
            }
            for _ in 0..<min(Self.maxConcurrent, subs.count) { addNext() }
            while let (url, eps) = await group.next() {
                if let latest = eps.first {
                    if let prev = seen[url], prev != latest.id {
                        Log.i("Updates", "发现更新 feed=\(Log.endpoint(url)) latest=\(latest.id)")
                        fresh.append(latest.podcastTitle.isEmpty ? latest.title : latest.podcastTitle)
                    }
                    // 首次见到 = 只记录,不发通知(与 Android FeedUpdateWorker 同一条)。
                    seen[url] = latest.id
                }
                if Task.isCancelled { break }
                addNext()
            }
        }

        // 退订的源不再留记录,免得字典无限长。
        let alive = Set(subs.map { $0.feedUrl })
        seen = seen.filter { alive.contains($0.key) }
        lastSeen = seen

        Log.i("Updates", "巡检结束 订阅=\(subs.count) 更新=\(fresh.count) \(Log.ms(t0))")
        if !fresh.isEmpty { await post(titles: fresh) }
    }

    private func post(titles: [String]) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("余音 · 订阅更新", comment: "订阅更新通知标题")
        if titles.count == 1 {
            content.body = String(format: NSLocalizedString("《%@》更新了新一期", comment: "单频道更新"), titles[0])
        } else {
            let head = titles.prefix(3).joined(separator: "、")
            let more = titles.count > 3 ? " " + NSLocalizedString("等", comment: "通知里省略其余频道") : ""
            content.body = String(format: NSLocalizedString("%lld 档播客有更新：%@", comment: "多频道更新"),
                                  Int64(titles.count), head) + more
        }
        content.sound = .default
        // 固定 identifier:新的汇总替换旧的,不在通知中心堆一列。
        let request = UNNotificationRequest(identifier: "reverb-subscription-updates",
                                            content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            Log.i("Updates", "已发订阅更新通知 count=\(titles.count)")
        } catch {
            Log.e("Updates", "通知发送失败", error: error)
        }
    }

    // MARK: - 存储

    /// 开关从 UserDefaults 直读:后台回调可能早于界面构建,而且这里只要一个布尔。
    /// 键名与 `SettingsStore` 的 `updates_enabled` 是同一个。
    private var updatesEnabled: Bool {
        UserDefaults.standard.object(forKey: "updates_enabled") as? Bool ?? false
    }

    /// feedUrl → 上次见过的最新一集 id。键直接用 URL(见类注释)。
    private var lastSeen: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "update_last_seen") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "update_last_seen") }
    }
}
