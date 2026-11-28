import Foundation
import Combine

/// 一次「这个源要用户名密码」的挑战。由 `PodcastRepository.feed/search` 在收到 401 时发出,
/// 界面收到后弹输入框(见 H253)。
struct FeedAuthChallenge: Identifiable, Equatable {
    /// 已去掉 userinfo 的 feedUrl,与订阅/缓存里那份是同一个键。
    let feedUrl: String
    /// true = 本机已经存着这个源的凭据,但这次仍是 401(输错了 / 服务器改了口令)。
    /// 输入框据此显示错误行,并把用户名预填出来。
    let failed: Bool
    var id: String { feedUrl }
}

/// 一次 feed 抓取的结局。界面据此区分「源被限制」与「这个节目确实没有单集」
/// (见 H308)。类本身 @MainActor,这张表只在主actor读写,不需要额外加锁。
enum FeedFetchStatus {
    case ok
    case unauthorized
    /// 平台级拦截(302→HTML / 非 XML 响应)。文案用「数据源暂不可用」。
    case unavailable
    case failed
}

/// 播客数据仓库:聚合各数据源,提供搜索、榜单、订阅源解析与随机一集。
/// 镜像 Android 版行为。标记 @MainActor 便于 SwiftUI 直接调用。
@MainActor
final class PodcastRepository {
    private let itunes = ITunesSource()
    private let charts: AppleChartsSource
    private let fyyd = FyydSource()
    private let gpodder = GpodderSource()
    private let rss = RssParser()
    private let cache = PopularCacheStore()
    /// 私有订阅源的凭据账本。与 `feedCache` 一样由仓库持有 —— 但**只在本机**,
    /// 不随订阅列表导出,也不进系统备份(见 `FeedAuthStore` 类注释)。
    let authStore = FeedAuthStore()
    /// 401 挑战。用 `PassthroughSubject` 而不是 `@Published` 状态:同一时刻可能有多个页面
    /// 在场(搜索页 / 频道详情),而**只有发起这次请求的那一个该弹框** ——
    /// 由各页面自己按 feedUrl 认领(见 H253)。
    let authRequired = PassthroughSubject<FeedAuthChallenge, Never>()
    // 随包内置的精选清单:缓存为空(首启/清缓存/无网)时给发现页兜底,避免首屏空白
    private let seed = SeedCatalog()
    // 频道详情(解析后的 RSS)缓存:详情页秒开,且断网时仍能看已访问过的频道
    let feedCache = FeedCacheStore()
    /// 视频当播客听。播放前解析也走它(见 `PlayerController.resolvePseudoUrl`)——
    /// 播放层与检索**共用这一个实例**,候选流缓存与探活游标才有意义。
    let bilibili = BilibiliSource()

    /// 每个 feed 最近一次的抓取结局。只给详情页选文案用,不落盘 ——
    /// 进程重启后按「没有记录」走通用文案即可,不该把一次网络失败带过重启。
    private var feedStatuses: [String: FeedFetchStatus] = [:]

    func feedStatus(_ feedUrl: String) -> FeedFetchStatus {
        feedStatuses[cleanUrl(feedUrl)] ?? .failed
    }

    private func setFeedStatus(_ status: FeedFetchStatus, for feedUrl: String) {
        feedStatuses[cleanUrl(feedUrl)] = status
    }

    init() {
        charts = AppleChartsSource(itunes: itunes)
    }

    // MARK: - 缓存维护(设置页「清除缓存」)

    /// 榜单与频道两类磁盘缓存的总字节数。
    ///
    /// 刻意**不含**图片与音频:那两份各自有独立预算与清空入口(`ArtworkCache` 是 actor、
    /// `AudioCacheManager` 要抬代号),设置页分头去要,这里只管仓库自己写的那两份文件。
    func cacheSizeBytes() -> Int64 {
        cache.sizeBytes() + feedCache.sizeBytes()
    }

    /// 清空仓库写的那两份缓存。**不动订阅/历史/下载** —— 它们的文件在同一个目录里,
    /// 只按各自的文件名处理(见 `PopularCacheStore.clear()` 与 `FeedCacheStore.clear()`)。
    func clearCaches() {
        let popular = cache.clear()
        feedCache.clear()
        Log.i("Repo", "清除缓存 popular=\(popular) 份")
    }

    // MARK: - 搜索

    /// 搜索频道。URL 直接走 RSS 导入;否则依次尝试 Apple / fyyd / gpodder,取首个非空。
    /// 返回结果列表与来源名。
    func search(_ query: String, region: String = "") async -> (podcasts: [Podcast], source: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], "") }

        // 只记词数,不记原文:已发布的隐私政策第二节承诺「日志不记录搜索词」,
        // 而这份日志用户可在设置里一键导出。与 Android util/Logger 那条同一口径。
        // 词数算法收在 `Log.wordCount`(见 REVIEW-2026-10-25 高-1):原先这一行是唯一的正确范式,
        // 三个 Source 层各抄一份必然各抄各的,现在它们与这里共用同一个函数。
        let words = Log.wordCount(q)
        Log.i("Repo", "search queryWords=\(words) region=\(region.isEmpty ? "-" : region)")
        // 视频页地址(BV 号本体 / 完整 URL / 短链)排在最前:它既是「用户点名的那一条」,
        // 也永远解析不出 RSS —— 先跑 RSS 只会白等一次超时。粘链接不是「下拉就能翻到的目录」,
        // 与关键词检索不是一回事(Android / 鸿蒙同一支、同一口径)。
        if BilibiliSource.looksLikeVideo(q) {
            if let result = await bilibili.resolveInput(q) {
                Log.i("Repo", "搜索经视频站直连命中 parts=\(result.episodes.count)")
                return ([result.podcast], "Bilibili")
            }
            Log.w("Repo", "视频链接解析失败")
            return ([], "")
        }
        if q.hasPrefix("http://") || q.hasPrefix("https://") {
            // 凭据要从 URL 里拆出来:它不该进订阅、备份与日志,只该进本机凭据账本。
            let (url, inline) = FeedCredential.splitUrl(q)
            switch await rss.fetch(url, auth: inline ?? authStore.get(url)) {
            case .success(let result):
                // 只在**确实读到了内容**之后才落盘:401 的那对错凭据不该覆盖原有的
                if let inline { authStore.save(url, inline) }
                return ([result.podcast], "RSS")
            case .unauthorized:
                challenge(url)
                return ([], "")
            case .unavailable:
                // 平台拦截的源不该在搜索里显示成「没搜到」,但仍不能假装命中。
                Log.w("Repo", "搜索的 RSS 源被平台限制 endpoint=\(Log.endpoint(url))")
                setFeedStatus(.unavailable, for: url)
                return ([], "")
            case .failed:
                return ([], "")
            }
        }

        let apple = await itunes.search(q, country: region)
        if !apple.isEmpty { return (apple, "Apple Podcasts") }

        let fy = await fyyd.search(q)
        if !fy.isEmpty { return (fy, "fyyd.de") }

        let gp = await gpodder.search(q)
        if !gp.isEmpty { return (gp, "gpodder.net") }

        Log.w("Repo", "search queryWords=\(words) 所有数据源均无结果")
        return ([], "")
    }

    /// 搜索单集。空查询或 URL 直接返回空。
    func searchEpisodes(_ query: String, region: String = "") async -> [Episode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if q.hasPrefix("http://") || q.hasPrefix("https://") { return [] }
        let apple = await itunes.searchEpisodes(q, country: region)
        // 视频的「一条视频」与「一集」是同一粒度,直接并进这一路。视频站搜寻失败不拖垮整列 ——
        // 上面的 Apple 结果照常返回。完整 URL 那支在上面已提前返回,所以这里不会拿地址当关键词。
        let video = await bilibili.searchEpisodes(q)
        Log.i("Repo", "searchEpisodes 命中 \(apple.count + video.count) 条 (视频 \(video.count))")
        return apple + video
    }

    // MARK: - 榜单缓存

    /// 榜单缓存 key。
    func cacheKey(_ genreId: Int?, _ region: String) -> String {
        "\(region):\(genreId.map(String.init) ?? "default")"
    }

    /// 立即返回可展示的榜单。优先真实缓存;缓存为空(首启/清过缓存/一直无网)则回退到随包
    /// 内置清单,保证首屏不空。种子**只读不写缓存**,联网刷新成功即被真数据取代。
    func cachedPopular(genreId: Int?, region: String) -> [Podcast] {
        let real = cache.get(cacheKey(genreId, region))
        if !real.isEmpty { return real }
        return seed.get(genreId: genreId, region: region)
    }

    /// 当前展示的是内置清单(而非联网取回的真榜单)——UI 据此把标题标成「内置精选」。
    func isSeedList(genreId: Int?, region: String) -> Bool {
        cache.get(cacheKey(genreId, region)).isEmpty && !seed.get(genreId: genreId, region: region).isEmpty
    }

    /// 内置清单的生成日期(yyyy-MM-dd)。
    func seedGeneratedAt() -> String { seed.generatedAt() }

    /// 拉取并刷新榜单。综合榜为空时依次回退到 us 综合榜、fyyd 热门。非空即写入缓存。
    func refreshPopular(genreId: Int?, region: String) async -> [Podcast] {
        let t0 = Date()
        Log.i("Repo", "refreshPopular region=\(region) genre=\(genreId.map(String.init) ?? "综合")")
        var list: [Podcast]
        if let genreId = genreId {
            list = await charts.topByGenre(region: region, genreId: genreId, limit: 30)
        } else {
            list = await charts.top(region: region, limit: 30)
        }

        if list.isEmpty && genreId == nil {
            Log.w("Repo", "refreshPopular region=\(region) 综合榜为空,回退 us 综合榜")
            list = await charts.top(region: "us", limit: 30)
            if list.isEmpty {
                Log.w("Repo", "refreshPopular us 综合榜仍为空,回退 fyyd 热门")
                list = await fyyd.hot(30)
            }
        }

        if !list.isEmpty {
            cache.put(cacheKey(genreId, region), list)
        }
        Log.i("Repo", "refreshPopular region=\(region) genre=\(genreId.map(String.init) ?? "综合") → \(list.count) 频道 \(Log.ms(t0))")
        return list
    }

    // MARK: - 订阅源

    /// 解析订阅源。成功则回写磁盘缓存;失败返回 nil(旧缓存保留,由调用方决定是否用)。
    /// 与 cachedFeed 配合成「先缓存秒开、再后台刷新、刷新失败退回缓存」。
    func feed(_ feedUrl: String) async -> FeedResult? {
        // 凭据/网址从同一处拆分:搜索页粘进来的带 userinfo 的地址,与订阅里存的那份
        // 必须收敛到同一个键 —— 否则缓存、凭据、备份会各认一个。
        let (url, inline) = FeedCredential.splitUrl(feedUrl)
        // 视频源的 feedUrl 是 `bilibili://video/<bvid>` 这种伪地址:RSS 解析器拿它会当场失败,
        // 所以在这里分叉。落盘缓存照写 —— 存的同样只有伪地址,不含会过期的直链。
        if BilibiliSource.isPseudo(url) {
            let result = await bilibili.feedOf(url)
            setFeedStatus(result?.episodes.isEmpty == false ? .ok : .failed, for: url)
            if let result, !result.episodes.isEmpty { feedCache.put(url, result) }
            return result
        }
        // 候选顺序:主源在前,其后是种子清单里同一节目的备用源(可达优先、小宇宙垫底,见 H311)。
        // 只有**主源**被判平台拦截才换源 —— 网络失败/解析失败不换,那是另一类问题,换源只会
        // 白等一次超时;401 也不换,那是用户凭据问题。
        let candidates = [url] + seed.altFeeds(for: url)
        for (index, candidate) in candidates.enumerated() {
            switch await rss.fetch(candidate, auth: inline ?? authStore.get(candidate)) {
            case .success(let result):
                setFeedStatus(.ok, for: url)
                if let inline { authStore.save(candidate, inline) }
                if !result.episodes.isEmpty { feedCache.put(url, result) }
                if index > 0 {
                    Log.i("Repo", "feed 主源被拦,换用备用源 #\(index) 成功 episodes=\(result.episodes.count) endpoint=\(Log.endpoint(candidate))")
                }
                return result
            case .unauthorized:
                setFeedStatus(.unauthorized, for: url)
                challenge(candidate)
                return nil
            case .unavailable:
                // 平台拦截:试下一个候选;全都不行才落 .unavailable。
                Log.w("Repo", "feed 备用源 #\(index) 被平台限制 endpoint=\(Log.endpoint(candidate))")
                continue
            case .failed:
                // 主源失败不换源;备用源失败则继续试下一个。
                if index == 0 {
                    setFeedStatus(.failed, for: url)
                    return nil
                }
                continue
            }
        }
        setFeedStatus(.unavailable, for: url)
        return nil
    }

    /// 界面在 401 弹框里点「保存」之后调用,然后自己重新拉一次。
    func saveAuth(_ feedUrl: String, username: String, password: String) {
        authStore.save(cleanUrl(feedUrl), FeedCredential(username: username, password: password))
    }

    /// 取消订阅时清掉这个源的凭据(AppEnvironment 把它接在 `SubscriptionStore.onRemoved` 上)。
    func forgetAuth(_ feedUrl: String) { authStore.forget(cleanUrl(feedUrl)) }

    /// 输入框预填用。
    func credential(for feedUrl: String) -> FeedCredential? { authStore.get(cleanUrl(feedUrl)) }

    /// 音频 / 逐字稿取流时用的头:只有与已存源同主机(或互为子域)才给。
    func authHeader(for url: String) -> String? { authStore.headerForUrl(url) }

    func cleanUrl(_ raw: String) -> String { FeedCredential.splitUrl(raw).url }

    /// 401 → 交给界面。`failed` 只有一种来源:本机对这个源已经存着凭据 ——
    /// 那说明这次是**凭据不对**,输入框要显示错误行并预填用户名。
    private func challenge(_ feedUrl: String) {
        let clean = cleanUrl(feedUrl)
        let failed = authStore.get(clean) != nil
        Log.w("Repo", "feed 需要认证 feed=\(Log.endpoint(clean)) failed=\(failed)")
        authRequired.send(FeedAuthChallenge(feedUrl: clean, failed: failed))
    }

    /// 立即返回上次解析结果(可能过时,可能为 nil),供进入详情页时秒开、断网时兜底。
    func cachedFeed(_ feedUrl: String) -> FeedResult? {
        guard let e = feedCache.get(cleanUrl(feedUrl)) else { return nil }
        return FeedResult(podcast: e.podcast, episodes: e.episodes)
    }

    /// 该 feed 缓存的落盘时刻;无缓存返回 nil。用于「上次更新于 X」提示。
    func feedCachedAt(_ feedUrl: String) -> Date? { feedCache.get(cleanUrl(feedUrl))?.fetchedAt }

    // MARK: - 随机一集

    /// 从各分类的热门频道里随机抽取一集可播放的内容。
    /// exclude 中的 episode id 会被排除。抽不到时返回 nil。
    func randomEpisode(region: String, genreIds: [Int?], exclude: Set<String> = []) async -> Episode? {
        // 组池:遍历各分类榜单,按 feedUrl 去重。cachedPopular 在缓存为空时给出内置清单,
        // 所以首次启动点「随机」也能直接组出池子,省掉一次榜单往返。
        var pool: [Podcast] = []
        var seenFeeds = Set<String>()
        for genreId in genreIds {
            for p in cachedPopular(genreId: genreId, region: region) where !p.feedUrl.isEmpty {
                if seenFeeds.insert(p.feedUrl).inserted { pool.append(p) }
            }
        }

        // 池不足时补充综合榜。
        if pool.count < 10 {
            for p in await refreshPopular(genreId: nil, region: region) where !p.feedUrl.isEmpty {
                if seenFeeds.insert(p.feedUrl).inserted { pool.append(p) }
            }
        }

        guard !pool.isEmpty else {
            Log.w("Radio", "randomEpisode region=\(region) 频道池为空")
            return nil
        }

        // 过滤付费频道;若全部付费则保留原池。
        let free = pool.filter { !$0.isPaid }
        let candidates = free.isEmpty ? pool : free

        Log.i("Radio", "randomEpisode region=\(region) 池=\(pool.count) 候选=\(candidates.count) 排除=\(exclude.count)")
        let picks = candidates.shuffled().prefix(6)
        for podcast in picks {
            guard let result = await feed(podcast.feedUrl) else { continue }
            let playable = result.episodes.filter { !$0.audioUrl.isEmpty && !exclude.contains($0.id) }
            if let chosen = playable.randomElement() {
                Log.i("Radio", "randomEpisode 选中 频道=\"\(podcast.title)\" 单集=\"\(chosen.title)\" id=\(chosen.id)")
                return chosen
            }
        }
        Log.w("Radio", "randomEpisode region=\(region) 无可播放单集")
        return nil
    }
}
