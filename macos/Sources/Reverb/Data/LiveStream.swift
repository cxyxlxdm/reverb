import Foundation

/// 直播流(A 档):用户把一路音频流的地址直接粘进搜索框。
///
/// 这一档**不做目录、不做收录、不需要后端**:用户给什么地址就放什么地址,
/// 与「粘 RSS」「粘视频链接」同一性质 —— 用户点名的那一条,不是下拉就能翻到的目录。
///
/// 判据只有一条:**响应必须自己表明它是音频流**。收三种信号:
///  ① `Content-Type` 落在 `audio` 大类下(或 `application/ogg`)—— 绝大多数 Icecast/Shoutcast 的 MP3/AAC 流;
///  ② `Content-Type` 是 HLS 的 MIME 或路径以 `.m3u8` 结尾 —— 那是播放列表,不是网页;
///  ③ 带 `icy-` 响应头 —— ICY 协议自己的身份,有的电台 Content-Type 写得很随意,这条兜住。
/// `text/html` 一律拒绝:粘一个普通网页或一条失效的 RSS 地址,不该被当成直播播出去。
///
/// 返回的 `Episode` 是**合成出来的**,`isLive = true` 是它唯一的特殊之处 ——
/// 播放侧据此关掉历史/缓存/收听时长/断点续播/播完续播(见 `PlayerController` 里以 isLive 为闸的几处)。
enum LiveStream {
    private static let hlsTypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl"
    ]

    /// 只用来给界面做"这可能是直播"的廉价预判(不发请求);真正的判据在 `resolve` 的探测。
    static func looksLikeStream(_ raw: String) -> Bool {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return u.scheme == "http" || u.scheme == "https"
    }

    static func resolve(_ raw: String) async -> Episode? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: url),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        req.setValue("Reverb/1.0 (macOS podcast client)", forHTTPHeaderField: "User-Agent")
        // `bytes=0-0` 只要一个字节:能拿到响应头就够判断,不必把整路音频拖下来。
        // `Icy-MetaData: 1` 让支持 ICY 的服务器把 `icy-*` 头带回来(尤其是 icy-name,拿它当标题)。
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let probe = LiveHeadProbe()
        let session = URLSession(configuration: cfg, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // ⚠️ 必须 `dataTask(with:)` 驱动(与 `HTTP.probeCode` 同一条 H225 教训):
        // `session.data(for:)` 建的任务自带 completion handler,URLSession 就不再回调
        // delegate 的 `didReceive response` —— 响应头永远拿不到,探测恒失败。
        session.dataTask(with: req).resume()
        let head = await probe.wait()

        let type = head.contentType.lowercased()
        let isHls = hlsTypes.contains(type) || u.path.lowercased().hasSuffix(".m3u8")
        let isAudio = type.hasPrefix("audio/") || type == "application/ogg"
        // 416 = 服务器认 Range 但一个字节也取不到(空流/地址尾正好在末尾),响应头仍然有效
        let okStatus = (200...299).contains(head.code) || head.code == 416
        guard okStatus, isHls || isAudio || head.hasIcy else {
            Log.i("Live", "不是直播流 code=\(head.code) type=\(type.isEmpty ? "-" : type) icy=\(head.hasIcy) host=\(u.host ?? "-")")
            return nil
        }
        let name = head.icyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = u.host ?? ""
        Log.i("Live", "直播流确认 type=\(type) icy=\(head.hasIcy) hls=\(isHls) host=\(host) name=\(name)")
        return Episode(
            // id 带上地址:同一路流的两次粘贴视为同一集,重复点不会在队列里堆两条
            id: "live:\(url)",
            title: name.isEmpty ? host : name,
            description: "",
            audioUrl: url,
            artworkUrl: "",
            // 有台名时把主机名放到副标题,不然两行写的是同一句话
            podcastTitle: name.isEmpty ? "" : host,
            durationSec: 0,
            pubDate: "",
            feedUrl: "",
            isLive: true
        )
    }
}

/// 只收响应头、拿到就取消。与 `HTTP.HeaderProbe` 同一形状(H225),多记三样东西:
/// Content-Type(判音频/HLS)、是否带 `icy-*`、以及 `icy-name`(当标题用)。
private final class LiveHeadProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Head {
        var code: Int = 0
        var contentType: String = ""
        var hasIcy: Bool = false
        var icyName: String = ""
    }

    private let lock = NSLock()
    private var stored = Head()
    private var finished = false
    private var continuation: CheckedContinuation<Head, Never>?

    func wait() async -> Head {
        await withCheckedContinuation { c in
            lock.lock()
            if finished {
                let v = stored
                lock.unlock()
                c.resume(returning: v)
                return
            }
            continuation = c
            lock.unlock()
        }
    }

    private func finish(_ head: Head) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        if head.code != 0 { stored = head }
        let v = stored
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: v)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 先取消再交结果:取消会触发 didComplete,那里会撞上 finished 判重。
        completionHandler(.cancel)
        guard let http = response as? HTTPURLResponse else {
            finish(Head())
            return
        }
        var head = Head(code: http.statusCode,
                        contentType: http.value(forHTTPHeaderField: "Content-Type")?
                            .components(separatedBy: ";").first?
                            .trimmingCharacters(in: .whitespaces) ?? "")
        head.hasIcy = http.allHeaderFields.keys.contains {
            String(describing: $0).lowercased().hasPrefix("icy-")
        }
        head.icyName = (http.value(forHTTPHeaderField: "icy-name") ?? "")
        finish(head)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(Head())
    }
}
