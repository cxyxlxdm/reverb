import Foundation

/// 在线电台目录:radio-browser.info(公共社区数据库,数据 CC0,无需 Key)。
///
/// 这一路只解决「找得到」:用户搜一个台名、或先看一屏热门,点「+」收藏进本机账本。
/// 播放与收藏之后的地址校验仍走 `LiveStream.resolve` 的探针 —— 目录里的 `lastcheckok`
/// 是别人最近一次的结果,不是此刻的保证。
///
/// 两个镜像按序尝试:`de1` 与 `de2`(2026-11-22 本机实测可达)。`at1`/`nl1` 当时不可达,
/// 不放进表里 —— 放进去只会让每次失败多等一轮超时。
///
/// **只记结果条数与镜像名,不记用户输入的原词**(隐私政策第二节:日志不落完整 URL 与检索词)。
/// 因此这里不用 `HTTP.data/jsonArray`:那几个入口在失败时会打整条 URL,而搜索 URL 里带着 `name=…`。
enum RadioBrowserSource {
    private static let mirrors = ["de1.api.radio-browser.info", "de2.api.radio-browser.info"]

    /// 热门:按中国区的累计点击排序。空列表表示「没结果或全镜像失败」,界面不区分这两种。
    /// limit 压到 30/20:目录耗时随 limit 超线性增长(2026-11-22 本机实测同一关键词
    /// limit=50 要 31.8 s、20 只要 2.5 s;热门 40 要 9.4 s、30 只要 2.6 s)。
    static func popular(limit: Int = 30) async -> [Station] {
        await fetch(params: [
            ("countrycode", "CN"),
            ("limit", String(limit)),
            ("hidebroken", "true"),
            ("order", "clickcount"),
            ("reverse", "true")
        ])
    }

    static func search(_ query: String, limit: Int = 20) async -> [Station] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return await fetch(params: [
            ("name", q),
            ("limit", String(limit)),
            ("hidebroken", "true"),
            ("order", "clickcount"),
            ("reverse", "true")
        ])
    }

    /// 按序试镜像。成功(HTTP 2xx 且能解析)就返回,不必再试下一个。
    private static func fetch(params: [(String, String)]) async -> [Station] {
        for host in mirrors {
            guard let url = endpoint(host: host, params: params) else { continue }
            var req = URLRequest(url: url)
            // 与 limit 压小后的实际耗时留足余量(目录通常 2~6 s;2026-11-22 实测 50 条要 31.8 s)
            req.timeoutInterval = 20
            req.setValue("Reverb/1.0 (Apple podcast client)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await HTTP.session.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    Log.w("RadioDir", "mirror http \(http.statusCode) host=\(host)")
                    continue
                }
                let list = parse(data)
                Log.i("RadioDir", "ok host=\(host) n=\(list.count)")
                return list
            } catch {
                Log.w("RadioDir", "mirror failed host=\(host) \(type(of: error))")
            }
        }
        return []
    }

    static func endpoint(host: String, params: [(String, String)]) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/json/stations/search"
        c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url
    }

    /// 解析 `/json/stations/search` 的数组。抽成纯函数是为了单测:
    /// - `url_resolved` 优先,空则退 `url`(老记录里后者才有值);
    /// - `lastcheckok == 0` 的条目丢掉 —— 收藏下来也是一个点了没反应的按钮;
    /// - 同一 URL 在结果里重复出现时只留第一条(目录里同名同流的多条记录很常见)。
    static func parse(_ data: Data) -> [Station] {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            Log.w("RadioDir", "parse failed bytes=\(data.count)")
            return []
        }
        var seen = Set<String>()
        var out: [Station] = []
        for item in raw {
            guard let o = item as? [String: Any] else { continue }
            if intValue(o["lastcheckok"]) == 0 { continue }
            let resolved = string(o["url_resolved"])
            let url = resolved.isEmpty ? string(o["url"]) : resolved
            let name = string(o["name"])
            guard !url.isEmpty, !name.isEmpty, seen.insert(url).inserted else { continue }
            let uuid = string(o["stationuuid"])
            out.append(Station(
                id: uuid.isEmpty ? "rb:\(url)" : "rb:\(uuid)",
                name: name,
                url: url,
                logo: string(o["favicon"]),
                group: "",
                country: string(o["country"]),
                source: Station.sourceDirectory
            ))
        }
        return out
    }

    private static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    private static func intValue(_ v: Any?) -> Int {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }
}
