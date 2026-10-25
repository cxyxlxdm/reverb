import Foundation

/// 共享网络层:统一 URLSession 与 User-Agent,并提供健壮的 JSON 拉取工具。
/// 所有方法在任何错误下都返回 nil,绝不抛出到调用方。
enum HTTP {
    /// 全局共享会话,附带余音的 User-Agent。
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Reverb/1.0 (macOS podcast client)"]
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 拉取原始数据。任何错误(URL 非法、网络失败、非 2xx)均返回 nil。
    static func data(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else {
            Log.w("HTTP", "非法 URL: \(urlString)")
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                Log.w("HTTP", "状态 \(http.statusCode) \(urlString)")
                return nil
            }
            return data
        } catch {
            Log.e("HTTP", "传输失败 \(urlString)", error: error)
            return nil
        }
    }

    /// 拉取并解析为 JSON 字典。失败返回 nil。
    static func json(_ urlString: String) async -> [String: Any]? {
        guard let data = await data(urlString) else { return nil }
        let obj = try? JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any]
    }

    /// 拉取并解析为 JSON 数组。失败返回 nil。
    static func jsonArray(_ urlString: String) async -> [Any]? {
        guard let data = await data(urlString) else { return nil }
        let obj = try? JSONSerialization.jsonObject(with: data)
        return obj as? [Any]
    }

    /// 查询参数**值**的百分号编码。
    ///
    /// ⚠️ **不能用 `.urlQueryAllowed`**(见 REVIEW-2026-10-25 中-5)。那个集合的名字说的是
    /// 「在 query 里合法」,而 `& = + ? : @ ; $ ,` 这些字符在 query 里确实合法 —— 但它们是
    /// **分隔符**,出现在参数值里就把一条 URL 切成两条参数。搜「AT&T」时
    /// `term=AT&T&limit=50` 被服务端读成 `term=AT` 加一个莫名的 `T`,命中结果整个不对,
    /// 而且不报错( iTunes / fyyd / gpodder 三条链一起中)。
    /// 所以这里只放行 RFC 3986 的 unreserved 集(字母数字 + `-._~`),其余一律百分号编码 ——
    /// `+` 也编掉:query 里 `+` 按惯例是空格的另一种写法,交给各家服务的解析差异去猜不值。
    ///
    /// **只对参数值调用,不要拿它编整拼好的 URL**(那会把 `?` `&` `:` `/` 一起编码掉)。
    /// 三个调用点:`ITunesSource`(两处)、`FyydSource`、`GpodderSource`。
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? s
    }

    /// unreserved 集:字母 + 数字 + `-._~`(按 Unicode 取,中文等非 ASCII 一律编掉)。
    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}
