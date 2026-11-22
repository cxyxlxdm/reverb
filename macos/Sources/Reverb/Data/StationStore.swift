import Foundation

/// 用户自己的直播电台账本:`Application Support/Reverb/stations.json`。
///
/// 与 `SubscriptionStore` 同一形状(单文件 JSON、内存态 `@Published`、去抖异步落盘),
/// **不参与局域网同步**:电台是"这台设备上的快捷方式",而同步的删除传播靠墓碑账本;
/// 给电台也开一套墓碑会跨进同步协议与两端 UI。当前口径是**只进手动备份**
/// (`BackupManager` 的 `stations` 段),换机靠恢复 JSON。
///
/// 随包精选([seedStations])是**只读**的:界面点「+」时复制一条进本账本,
/// 用户随后改名字/删掉都不影响清单本身。
@MainActor final class StationStore: ObservableObject {
    @Published private(set) var stations: [Station]

    private var seedCache: [Station]?

    init() {
        let url = AppSupport.dir.appendingPathComponent("stations.json")
        let data = try? Data(contentsOf: url)
        stations = data.map(StationJson.list(from:)) ?? []
        Log.i("Station", "电台加载 \(stations.count) 条")
    }

    func containsUrl(_ url: String, exceptId: String = "") -> Bool {
        let key = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return stations.contains { $0.key == key && (exceptId.isEmpty || $0.id != exceptId) }
    }

    /// 新增一条;id 或地址已存在时返回 false(调用方据此提示"已在列表里")。
    @discardableResult
    func add(_ s: Station) -> Bool {
        guard !stations.contains(where: { $0.id == s.id || $0.key == s.key }) else { return false }
        stations.insert(s, at: 0)
        Log.i("Station", "add id=\(s.id) total=\(stations.count)")
        persist()
        return true
    }

    /// 按 id 原位替换。id 不存在、或新地址与**另一条**冲突时返回 false。
    @discardableResult
    func update(_ s: Station) -> Bool {
        guard let i = stations.firstIndex(where: { $0.id == s.id }) else { return false }
        guard !stations.contains(where: { $0.id != s.id && $0.key == s.key }) else { return false }
        stations[i] = s
        Log.i("Station", "update id=\(s.id) total=\(stations.count)")
        persist()
        return true
    }

    func remove(id: String) {
        let before = stations.count
        stations.removeAll { $0.id == id }
        guard stations.count != before else { return }
        Log.i("Station", "remove id=\(id) total=\(stations.count)")
        persist()
    }

    /// 备份恢复:按 id 或 url 去重,本端已有的保留;返回新增条数。
    /// 不做删除传播 —— stations 分区不在 `LanSyncMerge.SECTIONS` 里(见类注释)。
    @discardableResult
    func addAll(_ list: [Station]) -> Int {
        var ids = Set(stations.map(\.id))
        var urls = Set(stations.map(\.key))
        let before = stations.count
        for s in list where !s.key.isEmpty {
            guard !ids.contains(s.id), !urls.contains(s.key) else { continue }
            ids.insert(s.id)
            urls.insert(s.key)
            stations.append(s)
        }
        let added = stations.count - before
        if added > 0 {
            Log.i("Station", "addAll +\(added) total=\(stations.count)")
            persist()
        }
        return added
    }

    /// 随包精选(`Resources/radio_stations.json`,由 `shared/radio/sync.sh` 分发)。
    /// 解析一次、进程内复用;文件缺失或损坏退化为空(等同没有这个区块)。
    func seedStations() -> [Station] {
        if let seedCache { return seedCache }
        let out = Self.loadSeed()
        seedCache = out
        Log.i("Station", "内置精选就绪 \(out.count) 台")
        return out
    }

    private func persist() { AppSupport.save("stations.json", stations) }

    private static func loadSeed() -> [Station] {
        guard let url = resourceURL(), let data = try? Data(contentsOf: url) else {
            Log.w("Station", "内置电台清单缺失,电台页退化为目录 + 手动添加")
            return []
        }
        return StationJson.seed(from: data)
    }

    /// 打包后在 `Reverb.app/Contents/Resources/`(见 package.sh)或 iOS bundle;
    /// `swift run` 调试时 Bundle.main 是 .build 目录、里面没有资源,故再回落到源码树。
    private static func resourceURL() -> URL? {
        if let u = Bundle.main.url(forResource: "radio_stations", withExtension: "json") {
            return u
        }
        #if DEBUG
        // #filePath = <repo>/macos/Sources/Reverb/Data/StationStore.swift → 上溯 4 层到 macos/
        let macosDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Data
            .deletingLastPathComponent()   // Reverb
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // macos
        let dev = macosDir.appendingPathComponent("Resources/radio_stations.json")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }
}
