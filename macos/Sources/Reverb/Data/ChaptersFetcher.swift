import Foundation

/// 取发布方给的**章节表**(RSS `podcast:chapters`),解析成 `[Chapter]`。
///
/// 与 Android `data/remote/ChaptersFetcher.kt`、鸿蒙 `net/ChaptersFetcher.ets` 同一套规则 ——
/// 同样两种合法形状(Podcasting 2.0 的对象、以及不少源直接吐的裸数组)、同样两种起点写法
/// (`startTime` 秒数 / `start` 时间码)、同样在出口做「≥0 且严格递增」的收敛(硬规矩 10)。
/// 三端各写一份是因为四端不共享代码,判定规则必须逐条对齐,否则同一份章表在两端显示的名字对不上。
///
/// **失败与空必须分开**:`nil` = 取不到/解析不了(界面给重试),`[]` = 章表合法但没有章节
/// (界面说「这一集没有章节」)。混成一个,用户就会对一个永远重试不好的按钮点。
enum ChaptersFetcher {
    /// 1 MiB:章表是几十条标题的小 JSON,超过就是链接指错了东西(与 Android 同值)。
    static let maxBytes = 1024 * 1024

    static func fetch(url: String, authHeader: String? = nil) async -> [Chapter]? {
        guard let data = await download(url, authHeader: authHeader) else { return nil }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            Log.w("Chapters", "章表不是文本 endpoint=\(Log.endpoint(url))")
            return nil
        }
        let parsed = parse(text)
        if let parsed {
            Log.i("Chapters", "章表解析 \(parsed.count) 章 endpoint=\(Log.endpoint(url))")
        } else {
            Log.w("Chapters", "章表解析失败 endpoint=\(Log.endpoint(url))")
        }
        return parsed
    }

    // MARK: - 下载

    /// - Parameter authHeader: 私有订阅源的 `Authorization`。章表通常与 feed 同主机,
    ///   但也可能挂在第三方对象存储上 —— 那种情况调用方已按主机判过,**不会**带过来
    ///   (与 `TranscriptFetcher.download` 同一条)。
    private static func download(_ urlString: String, authHeader: String?) async -> Data? {
        guard let url = URL(string: urlString) else {
            Log.w("Chapters", "非法 URL: \(urlString)")
            return nil
        }
        var req = URLRequest(url: url)
        if let authHeader { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await HTTP.session.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                Log.w("Chapters", "http \(http.statusCode) endpoint=\(Log.endpoint(urlString))")
                return nil
            }
            // **读之前**先看声明长度,免得遇到标错 type 的音频/视频链接把几十 MB 读进内存
            if response.expectedContentLength > Int64(maxBytes) {
                Log.w("Chapters", "章表过大(\(response.expectedContentLength) 字节),跳过 endpoint=\(Log.endpoint(urlString))")
                return nil
            }
            var data = Data()
            data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), 64 * 1024))
            for try await b in bytes {
                data.append(b)
                if data.count > maxBytes {
                    Log.w("Chapters", "章表超过 \(maxBytes) 字节,放弃 endpoint=\(Log.endpoint(urlString))")
                    return nil
                }
            }
            return data
        } catch {
            Log.e("Chapters", "下载失败 endpoint=\(Log.endpoint(urlString))", error: error)
            return nil
        }
    }

    // MARK: - 解析

    /// 解析章表 JSON。返回 `nil` 表示这份内容根本不是章表(JSON 坏了 / 根不是对象或数组);
    /// 返回 `[]` 表示形状合法但里面没有可用章节。
    static func parse(_ raw: String) -> [Chapter]? {
        // 去 BOM,否则 JSONSerialization 直接判非法
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        let items: [[String: Any]]
        if let obj = root as? [String: Any] {
            // `{"version":"1.2.0","chapters":[...]}`;没有 chapters 键 = 合法空表
            guard let arr = obj["chapters"] else { return [] }
            guard let arrList = arr as? [Any] else { return nil }
            items = arrList.compactMap { $0 as? [String: Any] }
        } else if let arr = root as? [Any] {
            // 裸数组:规范外但很常见,收
            items = arr.compactMap { $0 as? [String: Any] }
        } else {
            return nil
        }

        var parsed: [(index: Int, chapter: Chapter)] = []
        parsed.reserveCapacity(items.count)
        for (index, o) in items.enumerated() {
            // 标题是这一章的唯一标识,空标题的条目没有可显示的内容 —— 丢掉,
            // 不留一行只有时间的空行(与 Android / 鸿蒙同一条)
            let title = (o["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            guard let startMs = startMsOf(o) else { continue }
            // 负数起点夹到 0(个别源把片头标成 -1);夹完之后可能与第一章同起点,
            // 由下面的去重收掉
            let start = max(startMs, 0)
            let image = firstNonEmpty(o["img"] as? String, o["image"] as? String)
            let url = (o["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.append((index, Chapter(startMs: start, title: title, imageUrl: image, url: url)))
        }

        // 起点单调是渲染侧「从后往前找第一个 `startMs <= now`」成立的前提(硬规矩 10)。
        // 同起点的条目按原始顺序保留第一条 —— 用 `index` 做次关键字,避免排序不稳定时
        // 每次解析出的"当前章"名字不同。
        parsed.sort {
            $0.chapter.startMs == $1.chapter.startMs
                ? $0.index < $1.index
                : $0.chapter.startMs < $1.chapter.startMs
        }
        var out: [Chapter] = []
        out.reserveCapacity(parsed.count)
        var last = Int.min
        for item in parsed where item.chapter.startMs != last {
            out.append(item.chapter)
            last = item.chapter.startMs
        }
        return out
    }

    /// 起点毫秒。优先 `startTime`(Podcasting 2.0 的秒数,可能是 25 或 25.5),
    /// 退到 `start` 时间码(`HH:MM:SS(.mmm)` / `MM:SS(.mmm)` / 裸秒)。
    private static func startMsOf(_ o: [String: Any]) -> Int? {
        if let v = o["startTime"] {
            if let n = v as? NSNumber { return Int((n.doubleValue * 1000).rounded()) }
            if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                return Int((d * 1000).rounded())
            }
        }
        if let s = o["start"] as? String, let ms = parseTimecode(s) { return ms }
        return nil
    }

    /// 时间码 → 毫秒。秒可以带小数(`01:05.25`)。段数不是 1~3、或某段不是数字就判非法。
    private static func parseTimecode(_ raw: String) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for p in parts {
            guard let v = Double(p.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
            seconds = seconds * 60 + v
        }
        guard seconds.isFinite else { return nil }
        return Int((seconds * 1000).rounded())
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for v in values {
            if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }
}
