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

    /// 带自定义请求头的 GET(原始字节)。
    ///
    /// 只有视频源那一族接口用得上:它要浏览器 UA 与 `Referer`,缺了 `Referer` 时搜索
    /// 会被**软拦** —— 回 `code=0` + `data:{"v_voucher":…}` + 零条,看起来完全像「没搜到」
    /// (见 `BilibiliSource` 类注释)。别把这个重载当成第二套网络层:它只是给现有会话加头。
    static func data(_ urlString: String, headers: [String: String],
                     timeout: TimeInterval = 20) async -> Data? {
        guard let url = URL(string: urlString) else {
            Log.w("HTTP", "非法 URL: \(urlString)")
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: req)
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

    /// 带请求头的 JSON 拉取。失败返回 nil。
    static func json(_ urlString: String, headers: [String: String],
                     timeout: TimeInterval = 20) async -> [String: Any]? {
        guard let data = await data(urlString, headers: headers, timeout: timeout) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 带请求头的下载:回系统临时文件与响应,调用方负责把文件搬走或删掉。
    ///
    /// 只有视频源的整集缓存用得上 —— CDN 按 UA + `Referer` 拦,缺一个就 403
    /// (见 `BilibiliSource.uaBrowser` 那条注释),而 `HTTP.session.download(from:)`
    /// 发的是会话默认 UA、且一个自定义头都带不进去。
    ///
    /// 用 `HTTP.session` 而不是临时会话:临时会话一旦 invalidate,它返回的那个临时文件
    /// 就可能随会话一起被清掉,而调用方是在本函数返回之后才去 rename —— 那正是
    /// 「下完了却搬不走」的形状。
    static func download(_ urlString: String, headers: [String: String],
                         timeout: TimeInterval = 60) async -> (url: URL, response: URLResponse)? {
        guard let req = request(urlString, headers: headers, timeout: timeout) else { return nil }
        do {
            return try await session.download(for: req)
        } catch is CancellationError {
            // 换集 / 「清除缓存」都会取消这次下载。那是正常路径,不该记成错误 ——
            // 调用方靠 `Task.isCancelled` 自己认领这条日志。
            return nil
        } catch {
            Log.e("HTTP", "下载失败 \(urlString)", error: error)
            return nil
        }
    }

    /// 1 字节 `Range` 探活:只认 200/206(503/403 都说明这个节点这会儿不给流)。
    ///
    /// 拿到响应头就取消,不读 body:有些 CDN 无视 Range 回 200 + 整段音频,
    /// 读下去等于为了探活用一次探针付掉整集流量(Android 侧也是拿到响应就 close)。
    static func probeOk(_ urlString: String, headers: [String: String],
                        timeout: TimeInterval = 8) async -> Bool {
        guard var req = request(urlString, headers: headers, timeout: timeout) else { return false }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let probe = HeaderProbe()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let probeSession = URLSession(configuration: cfg, delegate: probe, delegateQueue: nil)
        defer { probeSession.invalidateAndCancel() }
        _ = try? await probeSession.data(for: req)
        let code = probe.code
        return code == 200 || code == 206
    }

    /// 短链跟随探查:**不跟随**,只把 `Location` 与正文各兜一遍。
    ///
    /// 与 Android 读 `Location` / 鸿蒙 `Http.redirectProbe` 同一条口径。不跟随的理由:
    /// 跳过去那一页有几十 KB(内嵌 JSON-LD),而我们只要 BV 号;若对方干脆不跳(直接 200),
    /// 那 BV 就写在正文里 —— 两种系统行为都兜住,调用方两处都找一遍。
    static func redirectProbe(_ urlString: String, headers: [String: String],
                              timeout: TimeInterval = 10) async -> RedirectProbe {
        guard let req = request(urlString, headers: headers, timeout: timeout) else {
            return RedirectProbe(code: -1, location: "", body: "", finalUrl: "")
        }
        let capture = RedirectCapture()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let probeSession = URLSession(configuration: cfg, delegate: capture, delegateQueue: nil)
        defer { probeSession.invalidateAndCancel() }
        do {
            let (data, response) = try await probeSession.data(for: req)
            let http = response as? HTTPURLResponse
            let body = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? ""
            return RedirectProbe(code: http?.statusCode ?? -1, location: capture.location,
                                 body: body, finalUrl: http?.url?.absoluteString ?? "")
        } catch {
            // 3xx 之后我们主动不跟随,这里可能拿到空响应体甚至报错;已经抓到的头照样有用。
            return RedirectProbe(code: capture.code, location: capture.location,
                                 body: "", finalUrl: "")
        }
    }

    private static func request(_ urlString: String, headers: [String: String],
                                timeout: TimeInterval) -> URLRequest? {
        guard let url = URL(string: urlString) else {
            Log.w("HTTP", "非法 URL: \(urlString)")
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
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

/// 短链探查的读数:`location` 来自 3xx 的响应头,`body` 是没跳转时那一页的开头。
/// 两者都可能有、也可能都空,调用方各找一遍即可。
struct RedirectProbe {
    let code: Int
    let location: String
    let body: String
    let finalUrl: String
}

/// 只收响应头、拿到就取消。放在文件级是因为 `URLSessionDelegate` 不能是嵌套类型里的
/// 静态实例(会话会把 delegate 强持有到 invalidate),每次调用各建一个最省心。
private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var code: Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        stored = (response as? HTTPURLResponse)?.statusCode ?? -1
        lock.unlock()
        completionHandler(.cancel)
    }
}

/// 记下 `Location` 并**拒绝跟随**。
private final class RedirectCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLocation = ""
    private var storedCode = 0
    var location: String {
        lock.lock(); defer { lock.unlock() }
        return storedLocation
    }
    var code: Int {
        lock.lock(); defer { lock.unlock() }
        return storedCode
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        storedLocation = response.value(forHTTPHeaderField: "Location") ?? ""
        storedCode = response.statusCode
        lock.unlock()
        completionHandler(nil)
    }
}
