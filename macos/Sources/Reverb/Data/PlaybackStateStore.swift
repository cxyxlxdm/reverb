import Foundation

/// 一份「正在播什么」的跨启动快照(`playback_state.json`),与 Android
/// `data/local/PlaybackStateStore.kt` / 鸿蒙 `store/PlaybackStateStore.ets`
/// **同名、同文件名、同字段**(2026-10-25 补上桌面这一端,见 docs/MACOS-GAPS.md M7)。
///
/// 存三样东西,缺一样就会露出用户报的那种症状:
///  - `current`:正在播(或上次在播)的那一集 —— 没有它,底部播放条在冷启动后整条不出现,
///    用户只能回历史里凭标题把那集再点一次;
///  - `context` + `contextIndex`:**这一集来自哪一列** —— 没有它,重启后「上一集/下一集」
///    与「播完自动接下一集」全部失效,而系列节目恰恰靠这两条连着听;
///  - `upNext`:用户手动排的队列 —— 就是那条反馈的本体(此前只在内存里,进程结束即丢)。
///
/// 为什么不进任何备份(与两端同判据):队列与「正在播哪一集」是**这台机器上的一次性排程**,
/// 换机/恢复后大概率已经过期;而里面每一集都能从历史或订阅里找回,没有任何东西会永久丢失。
/// (批注 `notes.json` 正相反 —— 那是用户写出来的字,所以它进白名单。)
/// 也不占手动备份的分区:那是三端 `reverb-backup.json` 的互通契约,不为临时态动它。
@MainActor
final class PlaybackStateStore {
    /// 读回来的原样快照;字段含义见 `save`。
    struct Snapshot {
        var current: Episode?
        var listTag: String = ""
        var context: [Episode] = []
        var contextIndex: Int = 0
        var upNext: [Episode] = []

        var isEmpty: Bool { current == nil && upNext.isEmpty }
    }

    private(set) var snapshot: Snapshot

    private static let fileName = "playback_state.json"
    /// 口径变了要让旧数据作废时改这里(硬规矩 11)。目前只有一版,与两端同号。
    private static let version = 1
    /// 上下文窗口:当前集前后各留这么多集。
    private static let contextHalf = 40
    /// up next 的条数上限:超出截断队尾(没人真会排 300 集,留这个数是防文件无限长)。
    private static let upNextCap = 300

    init() {
        snapshot = Self.readFromDisk()
        let s = snapshot
        Log.i("State", "启动读回播放态 cur=\(s.current?.id ?? "-") ctx=\(s.context.count)@\(s.contextIndex) " +
                       "upNext=\(s.upNext.count) tag='\(s.listTag)'")
    }

    /// 落一份当前播放态。**同步写**(不经 `AppSupport.save` 那条去抖路径):
    /// 去抖的代价正是「进程被杀时丢掉窗口内那一次」,而这条要防的就是
    /// "排好队、关掉再打开就没了" —— 用去抖写会把同一个症状留在原地。
    /// 体量由下面两道裁剪兜住,且只在用户动作/换集时写,不在渲染路径里。
    ///
    /// - Parameter context: 收**整条**列上下文,裁剪在这里做(硬规矩 10:不变式在数据出口保证):
    ///   只保留以 `contextIndex` 为中心的 ±40 集。一份 RSS 常有上千集,整列落盘就是每次动作
    ///   同步写几 MB。代价:重启后连续按「上一集/下一集」超出窗口会到边界(按钮置灰),
    ///   用户重新点一下列表即拿回全量上下文。
    func save(current: Episode?, listTag: String, context: [Episode],
              contextIndex: Int, upNext: [Episode]) {
        let cur = current.flatMap { $0.audioUrl.isEmpty ? nil : $0 }
        if cur == nil && upNext.isEmpty {
            clear()
            return
        }
        let full = context.filter { !$0.audioUrl.isEmpty }
        var idx = -1
        if let cur { idx = full.firstIndex { $0.id == cur.id } ?? -1 }
        if idx < 0 {
            // 上下文里找不到正在播的那一集(例如「下一个播放」摘出来单播,上下文只有它自己)
            // 时才走这里;此时以传入的下标为准,别硬把 0 当答案。
            idx = full.indices.contains(contextIndex) ? contextIndex : 0
        }
        let from = max(0, idx - Self.contextHalf)
        let to = min(full.count - 1, idx + Self.contextHalf)
        let window = (from > 0 || to < full.count - 1) ? Array(full[from...to]) : full
        let queued = upNext.count > Self.upNextCap ? Array(upNext.prefix(Self.upNextCap)) : upNext
        let localIndex = idx - from

        let body = Body(version: Self.version,
                        listTag: listTag,
                        contextIndex: localIndex,
                        context: window.map { StoredEpisode($0, slim: true) },
                        upNext: queued.map { StoredEpisode($0, slim: true) },
                        // 只有 current 带完整字段(含简介):播放页要画节目简介,
                        // 而列表行与队列页不读它。
                        current: cur.map { StoredEpisode($0, slim: false) })
        snapshot = Snapshot(current: cur, listTag: listTag, context: window,
                            contextIndex: localIndex, upNext: queued)
        do {
            let data = try JSONEncoder().encode(body)
            try data.write(to: AppSupport.dir.appendingPathComponent(Self.fileName), options: .atomic)
        } catch {
            Log.e("State", "播放态写入失败", error: error)
        }
        Log.i("State", "落盘播放态 cur=\(cur?.id ?? "-") ctx=\(window.count)@\(localIndex)" +
                       "(全列 \(full.count)) upNext=\(queued.count) tag='\(listTag)'")
    }

    /// 清空:退电台、播完、数据无效时都落到「没有可恢复的东西」这个状态,而不是留一份半成品。
    func clear() {
        snapshot = Snapshot()
        try? FileManager.default.removeItem(at: AppSupport.dir.appendingPathComponent(Self.fileName))
    }

    // MARK: - 落盘格式

    private struct Body: Codable {
        var version: Int
        var listTag: String
        var contextIndex: Int
        var context: [StoredEpisode]
        var upNext: [StoredEpisode]
        var current: StoredEpisode?

        enum CodingKeys: String, CodingKey {
            case version, listTag, contextIndex, context, upNext, current
        }

        /// 逐键宽容解析:这是跨版本边界,任何一键坏掉都不该让整份读不出来
        /// (H86 的同一形状 —— 只是这里失败的方向是"重启后没有播放条")。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 1
            listTag = (try? c.decode(String.self, forKey: .listTag)) ?? ""
            contextIndex = (try? c.decode(Int.self, forKey: .contextIndex)) ?? 0
            context = (try? c.decode([StoredEpisode].self, forKey: .context)) ?? []
            upNext = (try? c.decode([StoredEpisode].self, forKey: .upNext)) ?? []
            current = try? c.decodeIfPresent(StoredEpisode.self, forKey: .current)
        }

        init(version: Int, listTag: String, contextIndex: Int,
             context: [StoredEpisode], upNext: [StoredEpisode], current: StoredEpisode?) {
            self.version = version
            self.listTag = listTag
            self.contextIndex = contextIndex
            self.context = context
            self.upNext = upNext
            self.current = current
        }
    }

    /// 条目序列化的本地形状。与 Android 的 `EpisodeJson` / 鸿蒙的 `Codec.episodeToJson`
    /// 逐键对齐(`description` 在这里叫 `summary`,只为了让「列表条目不带简介」这件事在类型上可见);
    /// 两端多写的 `transcriptUrl` / `transcriptType` 桌面没有对应字段,读的时候忽略即可。
    private struct StoredEpisode: Codable {
        var id: String
        var title: String
        var summary: String?
        var audioUrl: String
        var artworkUrl: String
        var podcastTitle: String
        var durationSec: Int
        var pubDate: String
        var feedUrl: String

        enum CodingKeys: String, CodingKey {
            case id, title, audioUrl, artworkUrl, podcastTitle, durationSec, pubDate, feedUrl
            case summary = "description"
        }

        init(_ e: Episode, slim: Bool) {
            id = e.id
            title = e.title
            summary = slim ? nil : e.description
            audioUrl = e.audioUrl
            artworkUrl = e.artworkUrl
            podcastTitle = e.podcastTitle
            durationSec = e.durationSec
            pubDate = e.pubDate
            feedUrl = e.feedUrl
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            summary = try? c.decodeIfPresent(String.self, forKey: .summary)
            audioUrl = (try? c.decode(String.self, forKey: .audioUrl)) ?? ""
            artworkUrl = (try? c.decode(String.self, forKey: .artworkUrl)) ?? ""
            podcastTitle = (try? c.decode(String.self, forKey: .podcastTitle)) ?? ""
            durationSec = (try? c.decode(Int.self, forKey: .durationSec)) ?? 0
            pubDate = (try? c.decode(String.self, forKey: .pubDate)) ?? ""
            feedUrl = (try? c.decode(String.self, forKey: .feedUrl)) ?? ""
        }

        var episode: Episode {
            Episode(id: id, title: title, description: summary ?? "", audioUrl: audioUrl,
                    artworkUrl: artworkUrl, podcastTitle: podcastTitle,
                    durationSec: durationSec, pubDate: pubDate, feedUrl: feedUrl)
        }
    }

    private static func readFromDisk() -> Snapshot {
        let url = AppSupport.dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return Snapshot() }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            Log.w("State", "播放态解析失败,按空处理")
            return Snapshot()
        }
        if body.version > version {
            // 新格式被老版本读到:整份作废,别拿半懂不懂的字段去恢复播放态
            Log.w("State", "播放态 version=\(body.version) > \(version),忽略")
            return Snapshot()
        }
        let cur = body.current?.episode
        let current = (cur?.audioUrl.isEmpty == false) ? cur : nil
        let upNext = body.upNext.map(\.episode).filter { !$0.audioUrl.isEmpty }
        let context = body.context.map(\.episode).filter { !$0.audioUrl.isEmpty }
        var idx = body.contextIndex
        // 位置以「current 在上下文里的那一格」为准自我纠正:窗口裁剪与版本升级都可能让存的
        // 下标对不上,而对不上的后果是上一集/下一集整条错位在另一列里跳。
        if let current, let found = context.firstIndex(where: { $0.id == current.id }) {
            idx = found
        }
        if context.isEmpty && current != nil { idx = 0 }
        else if !context.indices.contains(idx) { idx = 0 }
        return Snapshot(current: current, listTag: body.listTag, context: context,
                        contextIndex: idx, upNext: upNext)
    }
}
