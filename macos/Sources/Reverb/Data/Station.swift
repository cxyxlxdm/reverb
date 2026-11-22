import Foundation

/// 一台用户可管理的直播电台。
///
/// 与 `Episode.isLive` 的两层关系:这里是**账本里的一条**(可增删改、可备份),
/// 那里是**此刻合成出来的播放条目**(id `live:<url>`)。两者不共用类型,也不互相引用。
///
/// 四端备份契约:`id / name / url / logo / group / country / source` 七个键
/// 在 `reverb-backup.json` 的 `stations` 段里逐键对齐(Android `Station.kt` /
/// 鸿蒙 `Station.ets` 同名字段)。**新增字段要四端同改**,否则换机恢复会静默丢那一项。
///
/// `group` 是稳定代码(`news|music|talk|retro`),由界面按语种本地化;空串 = 未分组
/// (目录收藏进来的条目通常没有分组)。
///
/// `source` 只用于界面提示与去重口径,恢复时照原样保留:
///  - `manual`    —— 用户手输地址;
///  - `directory` —— 从在线目录收藏,id 为 `rb:<stationuuid>`;
///  - `seed`      —— 随包精选里复制一份,id 为 `seed:<url>`。
struct Station: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var logo: String = ""
    var group: String = ""
    var country: String = ""
    var source: String = Station.sourceManual

    static let sourceManual = "manual"
    static let sourceDirectory = "directory"
    static let sourceSeed = "seed"
    static let groups = ["news", "music", "talk", "retro"]

    static func normalizeGroup(_ raw: String) -> String {
        let g = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return groups.contains(g) ? g : ""
    }

    /// 去重判据只用 url(trim 后逐字):同一路流从目录收藏一次、再手输一次,id 会不同,
    /// 只有地址是共同身份。**不做路径归一化** —— 尾斜杠对某些 Icecast 服务是两条不同的流。
    var key: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    enum CodingKeys: String, CodingKey {
        case id, name, url, logo, group, country, source
    }
}

// 自定义解码放在 extension:写在类型体内会吞掉成员初始化器(H86 同一个坑)。
extension Station {
    /// 逐键兜底,与 Android `StationJson.fromJson` 同一口径:缺键不算坏条目,
    /// 只有「没有 URL」才没有播放价值 —— 那种条目由列表解码那层丢掉(见 `StationList`)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let url = ((try? c.decode(String.self, forKey: .url)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ((try? c.decode(String.self, forKey: .name)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ((try? c.decode(String.self, forKey: .id)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = url
        self.name = name.isEmpty ? url : name
        self.id = id.isEmpty ? "local:\(url)" : id
        logo = ((try? c.decode(String.self, forKey: .logo)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        group = Station.normalizeGroup((try? c.decode(String.self, forKey: .group)) ?? "")
        country = ((try? c.decode(String.self, forKey: .country)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let src = ((try? c.decode(String.self, forKey: .source)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        source = src.isEmpty ? Station.sourceManual : src
    }

    /// 只写七键,键序与另两端一致。合成编码会把默认值字段也算进去,形状本身没错,
    /// 但显式写死可以让「加字段时忘了四端同步」在 diff 里显形。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(logo, forKey: .logo)
        try c.encode(group, forKey: .group)
        try c.encode(country, forKey: .country)
        try c.encode(source, forKey: .source)
    }
}

/// 备份载荷里的 `stations` 段。
///
/// 单独包一层而不是直接用 `[Station]`:备份是外部输入,一条不是对象的坏元素
/// (手改过、另一端版本的 bug)不该让**整份备份**解码失败(H86 的同类)。
/// 做法与 Kotlin 的 `optJSONObject(i) ?: continue` 一致:逐条 `try?`,坏的跳过。
struct StationList: Codable {
    var items: [Station]

    init(items: [Station]) { self.items = items }

    /// 本地账本 / 测试用:整份解码,坏一条只丢那一条。
    static func decodeLossy(_ data: Data) -> [Station] {
        (try? JSONDecoder().decode(StationList.self, from: data))?.items ?? []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode([AnyJSON].self)
        items = raw.compactMap { StationJson.from($0.value) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(items)
    }
}

/// 本地账本文件与精选清单的解析。网络那一层只负责取字节,字段口径全在这里(可单测)。
enum StationJson {
    /// 一个 JSON 对象 → Station;没有可用 URL 返回 nil。
    static func from(_ any: Any) -> Station? {
        guard let o = any as? [String: Any] else { return nil }
        let url = string(o["url"])
        guard !url.isEmpty else { return nil }
        let name = string(o["name"])
        let id = string(o["id"])
        let source = string(o["source"])
        return Station(
            id: id.isEmpty ? "local:\(url)" : id,
            name: name.isEmpty ? url : name,
            url: url,
            logo: string(o["logo"]),
            group: Station.normalizeGroup(string(o["group"])),
            country: string(o["country"]),
            source: source.isEmpty ? Station.sourceManual : source
        )
    }

    /// `stations.json` 整份读取:坏一条只丢那一条。
    static func list(from data: Data) -> [Station] {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return raw.compactMap { from($0) }
    }

    /// 随包精选(`{version, note, stations:[…]}`)。id 用 `seed:<url>` 是确定值 ——
    /// 两次启动得到同一批 id,点「+」复制进账本后不会因来源消失而变成孤儿。
    static func seed(from data: Data) -> [Station] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["stations"] as? [Any] else { return [] }
        var seen = Set<String>()
        var out: [Station] = []
        for item in raw {
            guard let o = item as? [String: Any] else { continue }
            let url = string(o["url"])
            let name = string(o["name"])
            guard !url.isEmpty, !name.isEmpty, seen.insert(url).inserted else { continue }
            let country = string(o["country"])
            out.append(Station(
                id: "seed:\(url)",
                name: name,
                url: url,
                logo: string(o["logo"]),
                group: Station.normalizeGroup(string(o["group"])),
                country: country.isEmpty ? "CN" : country,
                source: Station.sourceSeed
            ))
        }
        return out
    }

    /// 字符串取值:容器里偶尔会有数字/布尔(另一端手误),按文本化读,不因类型不符丢整条。
    private static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}

/// 只用于「把任意 JSON 元素喂进 JSONDecoder 再原样取出来」。
/// 目的是让 `StationList` 能逐条判断类型,而不是让一个坏元素炸掉整份文件。
private struct AnyJSON: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = NSNull()
        } else if let v = try? c.decode(Bool.self) {
            value = v
        } else if let v = try? c.decode(Double.self) {
            value = v
        } else if let v = try? c.decode(String.self) {
            value = v
        } else if let v = try? c.decode([AnyJSON].self) {
            value = v.map { $0.value }
        } else if let v = try? c.decode([String: AnyJSON].self) {
            value = v.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "无法识别的 JSON 元素"))
        }
    }
}
