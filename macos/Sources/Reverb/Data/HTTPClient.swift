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

    /// URL 查询参数编码。
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
