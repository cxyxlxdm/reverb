import Foundation

/// 把一段视频当成一集播客来播。与 Android `BilibiliSource.kt` / 鸿蒙 `BilibiliSource.ets`
/// 同一个口径、同一套伪地址,三端可互相读对方的备份 / 历史 / 待播。
///
/// **不建任何中转**:解析与取流都由设备直连视频站的公开接口完成。这一条是本方案能进本仓库的
/// 前提 —— 它保住「零后端」,也让 `docs/PRIVACY.md` 里「不转存或代理节目内容」继续成立。
///
/// 四条实测结论(2026-10-28,Android 侧匿名请求、无 Cookie;本端接口形状一致):
///  1. `x/web-interface/view` 与 `x/player/playurl` 都不需要签名、不需要 Cookie。
///     `x/web-interface/wbi/search/type` 路径里带 `wbi` 但**也不校验签名**,它要的是 Referer。
///     ⚠️ **`view` 现在要 Cookie**(2026-10-31 复测,见 H236):不带 `buvid3` 会被风控回
///     **HTTP 412**,而用户看到的就是「这一集暂时播不了」。见 `ensureCookie()`。
///     ⚠️ 但**搜索反而不能带**:同一天同一个出口的对照里,带上就从 20 条变成
///     `v_voucher` 零条 ⇒ 风控是**按端点分别判的**,别推成一条通则。
///  2. 直链的 `deadline` 是**请求时刻 + 2 小时** ⇒ **绝不能把直链持久化**。
///     历史、待播、播放态快照、备份里存的都是 `bilibili://` 伪地址,播放前才解析。
///  3. ⚠️ **搜索必须带 `Referer: https://www.bilibili.com/`**,缺了会被风控软拦:
///     回 `code=0` + `data:{"v_voucher": …}` + 零条结果 —— 看起来完全像「没搜到」。
///     view / playurl 带不带 Referer 都通,但这里**一律带**,省掉逐接口分叉。
///  4. `dash.audio` 排第一的那条常落在 PCDN 上,同一视频换一轮取链,三条候选的可用性会**互换**。
///     所以解析后必须**探活**再交给播放器,并按游标轮换起点,否则表现是「点了没反应」。
///  5. ⚠️ **充电专属视频没有 `dash.audio`**:playurl 对它们只回旧的 `durl`(混流
///     `video/mp4`),`fetchCandidates` 拿到空数组 ⇒ 解析必然失败。而**搜索接口不带任何
///     标记**(实测两条确认的充电视频:`is_charge_video=0`、`badgepay` / `corner` 全空),
///     唯一判据是 `view` 的 `data.is_upower_exclusive` ⇒ 只能在搜到之后补一次 view 再筛,
///     见 `isCharging` 与 H231。
///
/// ⚠️ `x/space/<mid>/arc/search`(UP 主投稿列表)是整条链路上唯一被风控挡住的部分
/// (`-352` / `-412` / `-799`),所以**「订阅 UP 主」不做**(2026-10-28 拍板)。
/// 这里没有任何代码去碰它 —— 别再顺手加回来。
///
/// 标 `@MainActor`:候选流缓存与探活游标是两份字典,只在主 actor 上读写才不用锁
/// (网络等待本身是挂起,不占主线程)。这与两端「一个实例被仓库与播放层共用」同形。
@MainActor
final class BilibiliSource {
    private static let scheme = "bilibili"
    private static let api = "https://api.bilibili.com/x"
    private static let referer = "https://www.bilibili.com/"
    /// ⚠️ **这一串是两个相反约束的交点,不是随便挑的。**
    ///
    /// 2026-10-28 在同一台机器上逐组实测(杭州联通出口,非地域问题):
    ///  - **CDN**(`upos-*` / `mcdn` 镜像)按 UA 分档:UA 含 `Android`(不分大小写)、空 UA、
    ///    `AppleCoreMedia/…`(AVPlayer 的默认 UA)一律 **403**;桌面 / iOS UA 才给 200/206。
    ///  - **`wbi/search/type`** 反过来不要桌面 UA:桌面 Chrome 串 ⇒ `code=0` + `v_voucher`
    ///    + **零条**(软拦,看起来像"没搜到",两轮复测都稳定);Android / iOS 串 ⇒ 20 条。
    /// ⇒ **只有 iOS 串两头都过**,所以接口、探活、播放三处统一用这一串。
    /// 缺 `Referer` 同样 403(即使 UA 对)。
    ///
    /// 本端第一版用的是桌面 Chrome 串:CDN 一路全绿、`view`/`playurl` 也 code=0,
    /// 唯独搜索恒零条 —— 而那正好是「用户搜不到东西」,不是报错。
    private static let uaBrowser =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    private static let bvRe = try! NSRegularExpression(pattern: "BV[0-9A-Za-z]{10}")
    private static let hhmmRe = try! NSRegularExpression(pattern: "^([0-9]+):([0-9]+)$")
    /// 接口超时。比 `HTTP.session` 默认的 20 秒短:这一串请求挡在「点播放」与出声之间,
    /// 超时该判失败让用户重试,而不是让播放页转 20 秒。
    private static let apiTimeout: TimeInterval = 10
    private static let probeTimeout: TimeInterval = 8

    /// 见 `getJson`:只有**快于这个数**的失败才补一次。慢失败(真超时)重试等于把等待翻倍。
    private static let retryFast: TimeInterval = 3
    private static let retryDelayNanos: UInt64 = 400_000_000

    private static var headers: [String: String] {
        ["User-Agent": uaBrowser, "Referer": referer]
    }

    /// 播放器取流要带的那一份头。与接口头是**同一个串**(见 `uaBrowser`)——
    /// `AVPlayer` 默认发 `AppleCoreMedia/…`,本机实测被 CDN 403,所以只能由 `AVURLAsset` 注入。
    static var streamHeaders: [String: String] { headers }

    /// 交给 `AVURLAssetOutOfBandMIMETypeKey` 的容器类型。
    ///
    /// 直链的 URL 路径以 `.m4s` 结尾、响应头是 `application/octet-stream`(镜像节点实测),
    /// AVFoundation 自己认不出这是 MP4 ⇒ 不给这一项时 item 直接 `failed`(`Cannot Open`)。
    /// 值取接口里那条流的 `mimeType`(实测恒为 `audio/mp4`)。
    static let streamMime = "audio/mp4"

    /// 一次解析出来的候选流地址 + 它的失效时刻。只在内存里,不落盘。
    private struct Track {
        let urls: [String]
        let expiresAt: Date
        let durationSec: Int
    }

    /// 一次解析的结果:探通的直链 + **这一 P 的真实时长(秒)**。
    ///
    /// 为什么要把时长一起带出来:搜索接口给的 `duration` 对**多 P 视频是整条视频的总和**
    /// (实测 `BV1MN4dewEQZ`:26 个 P,搜索回 `457:6` = 27 426 秒),而播放这一路只解析
    /// **P1**(1 127 秒,缓存下来的音频 `afinfo` 也是 1126 s)。本端那个数还被
    /// `PlayerController.attach` 当成「显式跳转的上限」(`metaMs - 2000`),放大 24 倍等于
    /// 给了一个 7.6 小时的上限 —— 落在真实片尾之外的跳点再也拦不住。
    /// `playurl` 的 `dash.duration`(秒)/ `timelength`(毫秒)给的正是**这个 cid** 的长度。
    /// 见 H226。
    struct ResolvedStream {
        let url: String
        let durationSec: Int
    }

    private var tracks: [String: Track] = [:]
    /// 每集下次从第几个候选开始试。重试(换一个 503 的 PCDN 节点)靠它生效。
    private var cursor: [String: Int] = [:]
    /// bvid → 是不是「充电专属」。只缓存**判定了的**结论(取不到就放行、不落缓存),
    /// 只在内存里、有上限 —— 它是搜索结果过滤的中间结果,不是持久数据。见 H231。
    private var charging: [String: Bool] = [:]
    /// `view` 要带的 `buvid3` / `buvid4`。见 `ensureCookie()` 与 H236。
    ///
    /// 只放内存、不落盘:重启换一个没有任何副作用,而落盘会白白在用户设备上留一个用不上的标识。
    private var cookie: String?
    /// 正在取 Cookie 的那一次请求。搜索一进来就是 20 条并发的 `isCharging`,不合并会发 20 次 spi。
    private var cookieTask: Task<String?, Never>?

    // MARK: - 伪地址

    /// 这一集是不是需要播放前解析。三端同口径(`bilibili://` 前缀)。
    static func isPseudo(_ url: String) -> Bool { url.hasPrefix("\(scheme)://") }

    static func audioUri(_ bvid: String, _ cid: Int) -> String { "\(scheme)://audio/\(bvid)/\(cid)" }

    static func videoUri(_ bvid: String) -> String { "\(scheme)://video/\(bvid)" }

    /// 用户输入看起来是不是「某一条视频」。
    ///
    /// 单认 BV 号就够:分享文案里的完整链接、`?p=` 参数、`b23.tv` 短链后面都藏着它。
    /// 这是**廉价的字符串判断**,所以可以放在搜索框的同步路径上;真正的网络动作在 `resolveInput`。
    static func looksLikeVideo(_ input: String) -> Bool {
        firstBV(input) != nil || input.contains("b23.tv") || input.contains("bili2233.cn")
    }

    /// `bilibili://video/<bvid>` → bvid;不是这个形态就 nil。
    static func videoIdOf(_ feedUrl: String) -> String? {
        let prefix = "\(scheme)://video/"
        guard feedUrl.hasPrefix(prefix) else { return nil }
        let id = feedUrl.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    /// `bilibili://audio/<bvid>/<cid>` → (bvid, cid)。形态不对回 nil。
    static func parseAudioUri(_ url: String) -> (bvid: String, cid: Int)? {
        let prefix = "\(scheme)://audio/"
        guard url.hasPrefix(prefix) else { return nil }
        let parts = url.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let cid = Int(parts[1]), cid > 0 else { return nil }
        return (String(parts[0]), cid)
    }

    // MARK: - 粘链接

    /// 用户在搜索框里贴了一个视频地址(或干脆只贴了 BV 号)。
    ///
    /// 认三种形态:BV 号本体、`bilibili.com/video/BV…`(可带 `?p=`)、`b23.tv` 短链。
    /// 短链要**跟随一次跳转**才能拿到 BV —— 不跟随的话用户看到的是「没搜到」,
    /// 而分享出来最常见的正是短链形态。
    func resolveInput(_ input: String) async -> FeedResult? {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return nil }
        guard let bvid = await bvidOf(q) else { return nil }
        let result = await view(bvid)
        if let result { Log.i("Bilibili", "resolve ok parts=\(result.episodes.count)") }
        return result
    }

    private func bvidOf(_ input: String) async -> String? {
        if let direct = Self.firstBV(input) { return direct }
        // 短链只认 b23.tv / bili2233.cn 这两种;别的短链不猜,免得把无关 URL 当视频解析。
        guard input.contains("b23.tv") || input.contains("bili2233.cn") else { return nil }
        let probe = await HTTP.redirectProbe(input, headers: Self.headers)
        // 头里、正文里、跟随后的最终 URL 三处都找一遍 —— 只有一个会有。
        if let bv = Self.firstBV(probe.location) { return bv }
        if let bv = Self.firstBV(probe.body) { return bv }
        if let bv = Self.firstBV(probe.finalUrl) { return bv }
        Log.w("Bilibili", "短链未取到 BV code=\(probe.code)")
        return nil
    }

    /// 频道页的入口:`bilibili://video/<bvid>` → `FeedResult`。
    ///
    /// 与 `resolveInput` 的唯一区别是入参形态 —— 一个是用户贴的原文,一个是上一次已经归一过的
    /// 伪地址。分 P、封面、作者都重新取一次:标题改了、视频被删了,这里要跟着变。
    func feedOf(_ feedUrl: String) async -> FeedResult? {
        guard let bvid = Self.videoIdOf(feedUrl) else { return nil }
        return await view(bvid)
    }

    /// bvid → 频道元信息 + 全部分 P。
    ///
    /// 单 P 视频就是「一集」;多 P 把每一 P 拆成一集(各有自己的 cid,而 playurl 按 cid 取)。
    /// 合集(season)不做 —— 那要 space 接口,见类注释。
    func view(_ bvid: String) async -> FeedResult? {
        let root = await getJson("\(Self.api)/web-interface/view?bvid=\(bvid)", withCookie: true)
        guard let data = Self.obj(root, "data") else {
            Log.w("Bilibili", "view failed bvid=\(bvid)")
            return nil
        }
        // 充电专属视频没有可播的音频流:playurl 对它们只回旧的 `durl`(混流 video/mp4),
        // `dash.audio` 是空的 ⇒ 播放必然失败。放它进来只会变成「播放条切走了、报错、
        // 重试也不会好」。频道页、粘贴链接、以及搜索结果点播放的兜底(见 `resolvePlayback`)
        // 都从这里过 ⇒ 这是唯一需要设闸的地方。见 H231。
        if Self.bool(data, "is_upower_exclusive") {
            charging[bvid] = true
            Log.w("Bilibili", "view skip charging bvid=\(bvid)")
            return nil
        }
        let title = Self.str(data, "title")
        let owner = Self.obj(data, "owner")
        let upName = Self.str(owner, "name")
        let cover = Self.https(Self.str(data, "pic"))
        let desc = Fmt.plainText(Self.str(data, "desc"))
        let pubDate = Self.dateOf(Self.num(data, "pubdate"))

        // 作者位写 UP 名。列表里同名频道很多,没有这一格用户分不清「这是一集播客」
        // 还是「这是一段视频」;平台标记在应用内可以明写(商店文案那一侧不出现平台名)。
        let podcast = Podcast(id: "\(Self.scheme):\(bvid)", title: title, author: upName,
                              artworkUrl: cover, feedUrl: Self.videoUri(bvid),
                              description: desc)

        var episodes: [Episode] = []
        let pages = Self.arr(data, "pages")
        if pages.isEmpty {
            // 兜底:老接口理论上总给 pages,真没有就按单集处理(cid 取 data.cid)
            let cid = Self.num(data, "cid")
            if cid > 0 {
                episodes.append(makeEpisode(bvid: bvid, cid: cid, title: title, desc: desc,
                                            cover: cover, upName: upName,
                                            durationSec: Self.num(data, "duration"), pubDate: pubDate))
            }
        } else {
            for (i, raw) in pages.enumerated() {
                guard let p = raw as? [String: Any] else { continue }
                let cid = Self.num(p, "cid")
                if cid <= 0 { continue }
                let part = Self.str(p, "part").trimmingCharacters(in: .whitespaces)
                let page = Self.num(p, "page") > 0 ? Self.num(p, "page") : i + 1
                // 单 P 视频不给自己加「P1」前缀:那会让播放页标题与用户在视频站看到的不一样。
                let epTitle = pages.count == 1 ? title : (part.isEmpty ? "P\(page)" : part)
                episodes.append(makeEpisode(bvid: bvid, cid: cid, title: epTitle, desc: desc,
                                            cover: cover, upName: upName,
                                            durationSec: Self.num(p, "duration"), pubDate: pubDate))
            }
        }
        if episodes.isEmpty {
            Log.w("Bilibili", "view no playable cid bvid=\(bvid)")
            return nil
        }
        Log.i("Bilibili", "view ok parts=\(episodes.count)")
        return FeedResult(podcast: podcast, episodes: episodes)
    }

    private func makeEpisode(bvid: String, cid: Int, title: String, desc: String, cover: String,
                             upName: String, durationSec: Int, pubDate: String) -> Episode {
        Episode(id: "\(Self.scheme):\(bvid):\(cid)", title: title, description: desc,
                audioUrl: Self.audioUri(bvid, cid), artworkUrl: cover, podcastTitle: upName,
                durationSec: durationSec, pubDate: pubDate, feedUrl: Self.videoUri(bvid),
                transcriptUrl: "", transcriptType: "")
    }

    // MARK: - 关键词搜单集

    /// 标题强相关过滤用到的停用词。搜「怎么做一个播客」时,「怎么/做一个」这些词
    /// 不承担检索语义,留着会把 2 字片段切碎(见 `isTitleRelevant`)。
    private static let stopWords = [
        "以及", "怎么", "如何", "为什么", "什么", "居然", "竟然", "原来是", "居然是",
        "的", "了", "也", "都", "是", "在", "与", "和", "或", "并", "而", "及", "啊", "呀", "吧", "呢", "吗"
    ]

    /// 去掉停用词、空白、标点与符号,再转小写。比较只在清洗后的串上做。
    private static func relevanceKey(_ raw: String) -> String {
        var s = raw.lowercased()
        for w in stopWords { s = s.replacingOccurrences(of: w, with: "") }
        return String(s.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
    }

    /// 标题是否与关键词强相关。
    ///
    /// 为什么需要这一层:B 站搜索是**模糊匹配**,`title` / `description` / `tag` 任一处命中
    /// 都会返回;短词或泛词(「播客」「美食教程」「学习资料」)的返回里因此混着大量标题
    /// 与关键词无关的视频,用户看起来就是「搜索结果掺了推荐流」。2026-11-04 用真实接口
    /// 复测:20 条里标题命中关键词的只有 8~13 条。
    ///
    /// 规则借自 `houliabc/bilibili-search-purify` 的 strict match,但**只借最保守的一条**:
    /// 清洗后整词包含,或关键词的任意 2 字连续片段出现在标题里,就算相关。
    /// 该项目的黑名单词库(擦边 / 标题党)是主观词表,不适合塞进客户端,没有采用。
    ///
    /// 2 字片段是「美食教程」还能留下「家常菜做法」这类近义标题的折中;整词命中要求
    /// 太严会把语义相近的结果全删掉。**全删空时调用方要退回原列表**(见 `searchEpisodes`),
    /// 宁可留杂音也不要给用户一屏空白。
    private static func isTitleRelevant(_ title: String, keyword: String) -> Bool {
        let k = relevanceKey(keyword)
        guard !k.isEmpty else { return true }
        let t = relevanceKey(title)
        if t.contains(k) { return true }
        let chars = Array(k)
        if chars.count >= 2 {
            for i in 0...(chars.count - 2) where t.contains(String(chars[i...i + 1])) {
                return true
            }
        }
        return false
    }

    /// 搜「单集」,不搜频道。路径带 `wbi` 但实测免签(类注释第 1 条)—— 别看到路径名
    /// 就去实现签名,那是原始调研里最贵的一块,而且并不需要。
    ///
    /// 结果天然是视频粒度,正好对上「单集」;每个视频各自成一个 `bilibili://video/<bvid>`
    /// 频道,进频道页会重新取元信息(见 `PodcastRepository.feed`)。
    func searchEpisodes(_ keyword: String, page: Int = 1) async -> [Episode] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty { return [] }
        let url = "\(Self.api)/web-interface/wbi/search/type?search_type=video"
            + "&keyword=\(HTTP.encode(kw))&page=\(page)&page_size=20"
        let root = await getJson(url)
        let data = Self.obj(root, "data")
        let arr = Self.arr(data, "result")
        if arr.isEmpty {
            // 风控软拦的指纹是 `v_voucher`(code 仍是 0,没有 result)。单独报一句,否则日志里
            // 只剩 "search failed",下一个人会去怀疑关键词或网络(见类注释第 3 条)。
            if data?["v_voucher"] != nil {
                Log.w("Bilibili", "search soft-blocked (v_voucher) — 检查 Referer")
            } else {
                Log.w("Bilibili", "search failed")
            }
            return []
        }
        var out: [(episode: Episode, bvid: String)] = []
        for raw in arr {
            guard let o = raw as? [String: Any] else { continue }
            let bvid = Self.str(o, "bvid")
            if bvid.isEmpty { continue }
            out.append((Episode(
                // 搜索结果是「一个视频」,分 P 要等进频道页才知道 ⇒ id 先用 bvid 占位。
                // 播放路径不靠 id 认视频(它解析 audioUrl);但它与频道页的 `scheme:bvid:cid`
                // 不是同一个 id —— 同一视频两个入口各播一次会留两条历史、两份缓存(见 H226 教训④)。
                id: "\(Self.scheme):search:\(bvid)",
                title: Fmt.plainText(Self.str(o, "title")),
                description: Fmt.plainText(Self.str(o, "description")),
                // 搜索结果里没有 cid,**这里刻意不给可播地址**:构造一个假 cid 会让播放请求打到
                // 别人那一集。用户点进频道页拿到的才是真 cid —— 真在这里点播放,由
                // `resolvePlayback` 自己补一次 view(见那里)。
                audioUrl: Self.videoUri(bvid),
                artworkUrl: Self.https(Self.str(o, "pic")),
                podcastTitle: Fmt.plainText(Self.str(o, "author")),
                // ⚠️ 多 P 视频这个数是**整条视频的总和**(实测 `BV1MN4dewEQZ`:26 个 P,
                // 这里回 `457:6` = 27 426 秒),而点开播放只给 P1(1 127 秒)。搜索接口
                // 没有任何字段能分辨多 P(`episode_count_text` 对它们也是空),所以列表
                // 这一行只能照它显示;真值的纠正发生在解析处(见 `ResolvedStream`)。
                durationSec: Self.hhmmToSec(Self.str(o, "duration")),
                pubDate: Self.dateOf(Self.num(o, "pubdate")),
                feedUrl: Self.videoUri(bvid),
                transcriptUrl: "", transcriptType: ""), bvid))
        }
        // 先按标题相关性剔掉模糊命中的无关条目(见 `isTitleRelevant`)。放在充电判定**之前**:
        // 既让用户看到的列表干净,也把逐条 `view` 请求从 20 个降到实际候选数。
        // 全滤空时退回原列表 —— 语义搜索(标题不含任何关键词片段)宁可留杂音也不白屏。
        let relevant = out.filter { Self.isTitleRelevant($0.episode.title, keyword: kw) }
        let droppedIrrelevant = relevant.isEmpty ? 0 : out.count - relevant.count
        let pool = relevant.isEmpty ? out : relevant
        let bvids = pool.map(\.bvid)
        // 充电专属视频要在这里就剔掉(见类注释第 5 条):用户点它只会看到播放条切走、
        // 然后「播放失败」,而重试永远不会成功 —— 看起来完全是播放器的 bug。
        // 搜索接口不带判据,只能逐条补一次 view(`isCharging` 有内存缓存,同一视频不重复问)。
        // 并发发、按索引收(组里按完成顺序交付,不能直接 append):20 条约 0.5 s,
        // 实测没有触发风控;一条失败就放行,不误删正常视频。
        var flags = [Bool](repeating: false, count: bvids.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, bv) in bvids.enumerated() {
                group.addTask { (i, await self.isCharging(bv)) }
            }
            for await (i, isCharge) in group { flags[i] = isCharge }
        }
        var kept: [Episode] = []
        var dropped = 0
        for (i, pair) in pool.enumerated() {
            if flags[i] { dropped += 1 } else { kept.append(pair.episode) }
        }
        Log.i("Bilibili", "search count=\(kept.count)"
              + (droppedIrrelevant > 0 ? " dropped_irrelevant=\(droppedIrrelevant)" : "")
              + (dropped > 0 ? " dropped_charge=\(dropped)" : ""))
        return kept
    }

    /// 这条视频是不是「充电专属」(UP 主设了付费门槛)。见类注释第 5 条与 H231。
    ///
    /// 只认 `view` 的 `data.is_upower_exclusive`:搜索接口对这类视频**不带任何标记**
    /// (实测 `is_charge_video` 恒 0,`badgepay` / `corner` 全空)。
    ///
    /// 取不到一律返回 false(**放行**):一次超时或风控不该把一条正常视频从结果里抹掉;
    /// 漏过滤的代价只是回到修之前那个「切条 + 报错」,可看见、可重试。只缓存判定出来的结论。
    private func isCharging(_ bvid: String) async -> Bool {
        if let cached = charging[bvid] { return cached }
        guard let data = Self.obj(
            await getJson("\(Self.api)/web-interface/view?bvid=\(bvid)", withCookie: true), "data") else { return false }
        let exclusive = Self.bool(data, "is_upower_exclusive")
        // 条目本身很小(bvid + 一个布尔),但搜索是长期入口:不设上限迟早堆起来。
        if charging.count > 512 { charging.removeAll() }
        charging[bvid] = exclusive
        return exclusive
    }

    // MARK: - 播放前解析

    /// `bilibili://audio/<bvid>/<cid>` → 一条**已经探通**的音频直链 + 这一 P 的真实时长;失败回 nil。
    ///
    /// 失败不在这里重试:播放器的重投由 `PlayerController` 统一管,两处各自重试会变成
    /// 「用户在等,两边都在等」。
    func resolvePlayback(_ audioUrl: String) async -> ResolvedStream? {
        // 搜索结果的 audioUrl 是 `bilibili://video/<bvid>`(那时还拿不到 cid)。用户直接在
        // 搜索结果里点播放走的就是这条 —— 这里必须自己补一次 view,否则表现是
        // 「搜索结果点播放永远失败」,而列表看起来完全正常。
        //
        // 顺带接住 view 里那条**准确的**分 P 时长(搜索给多 P 视频的是整条总和,见
        // `ResolvedStream`)。
        var hint = 0
        var ref = Self.parseAudioUri(audioUrl)
        if ref == nil {
            guard let id = Self.videoIdOf(audioUrl),
                  let feed = await view(id),
                  let first = feed.episodes.first,
                  let parsed = Self.parseAudioUri(first.audioUrl) else { return nil }
            hint = first.durationSec
            ref = parsed
        }
        guard let (bvid, cid) = ref else { return nil }
        let key = "\(bvid):\(cid)"
        let now = Date()
        let urls: [String]
        let fetchedDuration: Int
        if let cached = tracks[key], cached.expiresAt > now {
            urls = cached.urls
            fetchedDuration = cached.durationSec
        } else {
            guard let found = await fetchCandidates(bvid, cid) else {
                Log.w("Bilibili", "resolve failed bvid=\(bvid) cid=\(cid)")
                return nil
            }
            urls = found.urls
            fetchedDuration = found.durationSec
            tracks[key] = Track(urls: found.urls, expiresAt: found.expiresAt, durationSec: found.durationSec)
            // 缓存条数不设上限没有意义:只有正在听的那几集才可能被重试,而条目本身很小。
            if tracks.count > 64 { tracks.removeAll() }
            Log.i("Bilibili", "resolve candidates=\(found.urls.count) ttlMin="
                + "\(Int(found.expiresAt.timeIntervalSince(now) / 60))")
        }
        // 直链接口没给时长时退到 view 那条(同样是「这一 P」的口径);都没有就留 0,
        // 由调用方保留原元数据 —— 不猜。
        let durationSec = fetchedDuration > 0 ? fetchedDuration : hint

        // 从游标处开始**逐个探通**:排第一的 PCDN 节点会回 503(类注释第 4 条)。
        // 探测只用 1 字节 Range,代价一次 RTT;不探的代价是用户点开一集没反应。
        //
        // 每个候选的码都打出来(H225):这条链以前只回 Bool,而 macOS 的探针拿不到码、
        // 恒判失败,日志里「轮换没生效」和「节点真的不给流」是同一句话,查不出来。
        let start = (cursor[key] ?? 0) % urls.count
        cursor[key] = (start + 1) % urls.count
        var codes: [Int] = []
        for i in 0..<urls.count {
            let candidate = urls[(start + i) % urls.count]
            let code = await probe(candidate)
            codes.append(code)
            if code == 200 || code == 206 {
                Log.i("Bilibili", "probe ok #\(i) code=\(code)" + (i > 0 ? " fell back" : ""))
                return ResolvedStream(url: candidate, durationSec: durationSec)
            }
            Log.w("Bilibili", "probe #\(i) code=\(code)")
        }
        // 全部探不通也让第一条去试:探测本身可能被网络抖动误伤,
        // 而播放器至少还会走一次自动重投。
        Log.w("Bilibili", "all candidates probe failed, using #0 codes=\(codes)")
        guard let first = urls.first else { return nil }
        return ResolvedStream(url: first, durationSec: durationSec)
    }

    private func fetchCandidates(_ bvid: String, _ cid: Int)
        async -> (urls: [String], expiresAt: Date, durationSec: Int)? {
        let url = "\(Self.api)/player/playurl?bvid=\(bvid)&cid=\(cid)&fnval=16&fnver=0&fourk=0"
        guard let root = await getJson(url),
              let data = Self.obj(root, "data"),
              let dash = Self.obj(data, "dash") else { return nil }
        let audio = Self.arr(dash, "audio")
        if audio.isEmpty { return nil }
        // 取码率最高的一条。匿名也能拿到全部三档(30216/30232/30280),所以「匿名只有默认码率」
        // 那条调研结论在本端不成立。
        var best: [String: Any]?
        for raw in audio {
            guard let o = raw as? [String: Any] else { continue }
            if best == nil || Self.num(o, "bandwidth") > Self.num(best, "bandwidth") { best = o }
        }
        guard let track = best else { return nil }
        var urls: [String] = []
        let base = Self.str(track, "baseUrl")
        if !base.isEmpty { urls.append(base) }
        for raw in Self.arr(track, "backupUrl") {
            if let b = raw as? String, !b.isEmpty { urls.append(b) }
        }
        guard let first = urls.first else { return nil }
        // 这一段(这个 cid)的真实时长:`dash.duration` 秒 / `timelength` 毫秒,实测一致
        // (`BV1MN4dewEQZ` P1:1127 / 1126143)。优先取秒,免得四舍五入。
        let dashSec = Self.num(dash, "duration")
        let durationSec = dashSec > 0 ? dashSec : Self.num(data, "timelength") / 1000
        return (urls, Self.expiryOf(first), durationSec)
    }

    /// 1 字节 Range 探活。只认 200/206 —— 503/403 都说明这个节点这会儿不给流。
    /// 回状态码而不是 Bool:日志里要能看见码(见 H225)。
    private func probe(_ url: String) async -> Int {
        await HTTP.probeCode(url, headers: Self.headers, timeout: Self.probeTimeout)
    }

    // MARK: - 底层

    /// 取一次 `buvid3` / `buvid4` 并留在 `cookie` 里。**这是 `view` 现在能不能用的前置条件**(H236)。
    ///
    /// 2026-10-31 的现场:装了最新包的手机点开一集,`view` 回 **HTTP 412**,界面上就是
    /// 「这一集暂时播不了」,而同一条视频几秒后又能成功 ⇒ 不是视频坏了,是接口在被风控。
    /// 同一台手机、同一个出口的受控实验(只换请求头):UA 换成 Chrome / iPhone 都不改变结论,
    /// **带不带 `buvid3`/`buvid4` 才改变** —— 不带 412,带上 200。
    /// `x/frontend/finger/spi` 自己不拦匿名请求(实测 200),所以先取它、再拿回下发的值当 Cookie。
    ///
    /// ⚠️ **只给 `view` 带,别给搜索带**:Android 那边的第一版是「一律带」,结果搜索当场变成
    /// `v_voucher` 软拦、零条;同一台手机上的 curl / Chrome 用同一组头却是 20 条。
    /// 判据是**端点**,不是「顺手」。
    ///
    /// 失败(超时 / 接口变了)回 nil,调用方照旧不带 Cookie 发,让真正的失败原因露出来。
    private func ensureCookie() async -> String? {
        if let cached = cookie { return cached }
        if let running = cookieTask { return await running.value }
        let task = Task { await fetchCookie() }
        cookieTask = task
        defer { cookieTask = nil }
        return await task.value
    }

    private func fetchCookie() async -> String? {
        guard let root = await HTTP.json("\(Self.api)/frontend/finger/spi",
                                          headers: Self.headers, timeout: Self.apiTimeout),
              let data = Self.obj(root, "data") else { return nil }
        let b3 = Self.str(data, "b_3")
        let b4 = Self.str(data, "b_4")
        guard !b3.isEmpty else { return nil }
        let value = b4.isEmpty ? "buvid3=\(b3)" : "buvid3=\(b3); buvid4=\(b4)"
        cookie = value
        return value
    }

    /// 接口头。`withCookie` 只在 `view` 打开 —— 搜索带上它反而被软拦(见 `ensureCookie()`）。
    private func apiHeaders(withCookie: Bool) async -> [String: String] {
        var h = Self.headers
        if withCookie, let c = await ensureCookie() { h["Cookie"] = c }
        return h
    }

    /// 接口族的统一 GET。**网络层快速失败补一次**(见 H233)。
    ///
    /// 一次瞬时的拒连不该被判成「这一集播不了」:2026-10-31 的同形现场在鸿蒙那台
    /// (`view` 在 14 / 17ms 里被网络栈拒掉),而 H232 已经把「解析失败」改成不提交、
    /// 只提示一句 ⇒ 用户点几次几次播不了,看起来像功能坏了。
    ///
    /// 三个边界:
    ///  - **只在快失败时补**:超过 `retryFast` 的失败通常是真的超时,再等一轮只会让
    ///    「播放页转圈」翻倍;
    ///  - **`code≠0` 不补**:那是接口在说话(下架 / 风控),再来一次不会变;
    ///  - 重试的这一次也受 `apiTimeout` 约束,失败后照样回 nil,由播放层提示。
    private func getJson(_ url: String, withCookie: Bool = false) async -> [String: Any]? {
        for attempt in 0..<2 {
            let startedAt = Date()
            let headers = await apiHeaders(withCookie: withCookie)
            if let root = await HTTP.json(url, headers: headers, timeout: Self.apiTimeout) {
                let code = Self.num(root, "code")
                if code != 0 {
                    Log.w("Bilibili", "api code=\(code) msg='\(Self.str(root, "message"))'")
                    return nil
                }
                return root
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            if attempt == 1 || elapsed >= Self.retryFast { return nil }
            Log.w("Bilibili", "retry after fast failure elapsed=\(Int(elapsed * 1000))ms"
                  + " endpoint=\(Log.endpoint(url))")
            try? await Task.sleep(nanoseconds: Self.retryDelayNanos)
        }
        return nil
    }

    // MARK: - 取值 / 归一

    private static func obj(_ d: [String: Any]?, _ k: String) -> [String: Any]? { d?[k] as? [String: Any] }

    private static func arr(_ d: [String: Any]?, _ k: String) -> [Any] { d?[k] as? [Any] ?? [] }

    private static func str(_ d: [String: Any]?, _ k: String) -> String { d?[k] as? String ?? "" }

    private static func num(_ d: [String: Any]?, _ k: String) -> Int {
        if let n = d?[k] as? NSNumber { return n.intValue }
        if let s = d?[k] as? String { return Int(s) ?? 0 }
        return 0
    }

    /// 只认真正的布尔。接口偶尔给 0/1 —— 判据必须严格:把「缺字段」猜成 true 会把
    /// 正常视频全删掉(见 BilibiliSource 的充电过滤)。
    private static func bool(_ d: [String: Any]?, _ k: String) -> Bool {
        if let b = d?[k] as? Bool { return b }
        if let n = d?[k] as? NSNumber { return n.boolValue }
        return false
    }

    private static func firstBV(_ s: String) -> String? {
        let full = s as NSString
        guard let m = bvRe.firstMatch(in: s, range: NSRange(location: 0, length: full.length)) else {
            return nil
        }
        return full.substring(with: m.range)
    }

    /// 直链里的 `deadline`(十进制 epoch 秒)就是失效时刻。解析不出来时按「1.5 小时后」保守估;
    /// 解析出来也要**提前 5 分钟作废** —— 拿着一条还剩 20 秒的链接去起播,等于必然失败一次。
    private static func expiryOf(_ url: String) -> Date {
        let now = Date()
        guard let at = url.range(of: "deadline=") else { return now.addingTimeInterval(90 * 60) }
        let raw = url[at.upperBound...].prefix { $0 != "&" }
        guard let sec = Int(raw) else { return now.addingTimeInterval(90 * 60) }
        let expireAt = Date(timeIntervalSince1970: TimeInterval(sec))
        return expireAt.timeIntervalSince(now) > 10 * 60
            ? expireAt.addingTimeInterval(-5 * 60)
            : now.addingTimeInterval(60)
    }

    /// 封面/头像是 `http://` 或协议相对的 `//host/…`,统一升 https:明文在两端都会被拦。
    private static func https(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:\(url)" }
        if url.hasPrefix("http://") { return "https://\(url.dropFirst("http://".count))" }
        return url
    }

    /// 搜索结果里的时长是 `mm:ss`(超过一小时会变成 `hh:mm:ss`,那时直接放弃,回 0)。
    private static func hhmmToSec(_ raw: String) -> Int {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let full = s as NSString
        guard let m = hhmmRe.firstMatch(in: s, range: NSRange(location: 0, length: full.length)),
              m.numberOfRanges == 3,
              let min = Int(full.substring(with: m.range(at: 1))),
              let sec = Int(full.substring(with: m.range(at: 2))) else { return 0 }
        return min * 60 + sec
    }

    /// epoch 秒 → `yyyy-MM-dd`(本机时区)。0 / 非法值回空串。
    private static func dateOf(_ epochSec: Int) -> String {
        guard epochSec > 0 else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }
}
