import Foundation

/// 取发布方**自己提供的逐字稿**(RSS `podcast:transcript`),解析成统一的 `TranscribedSegment`。
///
/// 这条路优先于本机识别:时间轴是发布方给的,准确、免费、瞬间可用,还没有耗电与发热。
/// 与 Android `data/remote/TranscriptFetcher.kt` 同一套规则 —— 嗅探顺序、支持的格式、
/// 断句阈值都逐条对齐,否则同一份稿在三端会断成不同的行数(H150)。
///
/// 支持三种带时间轴的格式:Podcast Index JSON / WebVTT / SRT。HTML 与纯文本稿不收
/// (没有时间轴,做不了跟播放高亮,见 `RssParser.transcriptRank`)。
enum TranscriptFetcher {
    /// 8 MB:再离谱的逐字稿也到不了这个量级,超过就是链接指错了东西
    static let maxBytes = 8 * 1024 * 1024

    static func fetch(url: String, declaredType: String, authHeader: String? = nil) async -> [TranscribedSegment]? {
        guard let data = await download(url, authHeader: authHeader) else { return nil }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            Log.w("Transcript", "稿子不是文本 endpoint=\(Log.endpoint(url))")
            return nil
        }
        if let segs = parse(text, declaredType: declaredType), !segs.isEmpty {
            Log.i("Transcript", "官方稿 \(segs.count) 句 endpoint=\(Log.endpoint(url))")
            return segs
        }
        Log.w("Transcript", "解析不出句子 type=\(declaredType) endpoint=\(Log.endpoint(url))")
        return nil
    }

    // MARK: - 下载

    /// - Parameter authHeader: 私有订阅源的 `Authorization`。官方稿通常与 feed 同主机,
    ///   但也可能挂在第三方对象存储上 —— 那种情况调用方已经按主机判过,**不会**带过来。
    private static func download(_ urlString: String, authHeader: String?) async -> Data? {
        guard let url = URL(string: urlString) else {
            Log.w("Transcript", "非法 URL: \(urlString)")
            return nil
        }
        var req = URLRequest(url: url)
        if let authHeader { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await HTTP.session.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                Log.w("Transcript", "http \(http.statusCode) endpoint=\(Log.endpoint(urlString))")
                return nil
            }
            // **读之前**先看声明长度,免得遇到标错 type 的音频/视频链接把几十 MB 读进内存
            if response.expectedContentLength > Int64(maxBytes) {
                Log.w("Transcript", "稿子过大(\(response.expectedContentLength) 字节),跳过 endpoint=\(Log.endpoint(urlString))")
                return nil
            }
            var data = Data()
            data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), 256 * 1024))
            for try await b in bytes {
                data.append(b)
                if data.count > maxBytes {
                    Log.w("Transcript", "稿子超过 \(maxBytes) 字节,放弃 endpoint=\(Log.endpoint(urlString))")
                    return nil
                }
            }
            return data
        } catch {
            Log.e("Transcript", "下载失败 endpoint=\(Log.endpoint(urlString))", error: error)
            return nil
        }
    }

    // MARK: - 选解析器

    /// **先嗅探内容,再看声明的 type** —— feed 里 type 标错很常见
    /// (把 VTT 标成 `text/plain`、把 JSON 标成 `application/octet-stream` 都见过),
    /// 内容特征比声明可靠。
    static func parse(_ raw: String, declaredType: String) -> [TranscribedSegment]? {
        // 去 BOM,否则 "WEBVTT" 判断会失手
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("WEBVTT") { return parseCues(text, vtt: true) }
        // `[` 也要认:有些转写服务直接把数组当根吐出来(H150)
        if head.hasPrefix("{") || head.hasPrefix("[") { return parseJSON(text) }
        if text.contains("-->") { return parseCues(text, vtt: false) }
        if declaredType.lowercased().contains("json") { return parseJSON(text) }
        return nil
    }

    // MARK: - SRT / WebVTT

    /// SRT 与 VTT 用同一套解析:按空行切块,块里找带 `-->` 的那一行当时间,其余行拼成文本。
    /// 两者的差别只有毫秒分隔符(SRT 用逗号、VTT 用点)与几样附加语法。
    static func parseCues(_ text: String, vtt: Bool) -> [TranscribedSegment] {
        var out: [TranscribedSegment] = []
        for block in splitBlocks(text) {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = lines.first else { continue }
            // VTT 的 NOTE / STYLE / REGION 块不是字幕
            if vtt && (first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION") { continue }
            guard let tIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[tIdx].components(separatedBy: "-->")
            guard parts.count >= 2,
                  let start = parseClock(parts[0]),
                  let end = parseClock(parts[1]) else { continue }
            // 时间行之前那行是序号(SRT)或 cue 标识(VTT),都不是正文;之后各行才是
            let body = lines[(tIdx + 1)...]
                .map(cleanCueText)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }
            out.append(contentsOf: TranscriptLines.split(body, startMs: start, endMs: max(end, start)))
        }
        // 也要并碎片:切长 cue 会剩下尾巴,而最后一条 cue 本身就可能只有一个词(同 Android)
        return TranscriptLines.glueOrphans(out)
    }

    /// 按空行(`\r?\n[ \t]*\r?\n`)切块。逐字符扫而不是用正则,块边界才看得见。
    private static func splitBlocks(_ text: String) -> [Substring] {
        let s = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var out: [Substring] = []
        var start = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\n" {
                var j = s.index(after: i)
                while j < s.endIndex, s[j] == " " || s[j] == "\t" { j = s.index(after: j) }
                if j < s.endIndex, s[j] == "\n" {
                    out.append(s[start..<i])
                    start = s.index(after: j)
                    i = start
                    continue
                }
            }
            i = s.index(after: i)
        }
        out.append(s[start...])
        return out
    }

    private static let tagRegex = try? NSRegularExpression(pattern: "<[^>]*>")
    private static let speakerRegex = try? NSRegularExpression(pattern: "(?i)^\\s*speaker[_ ]?\\d+\\s*:\\s*")

    /// 去掉 VTT 的说话人标签与内联样式(`<v Alice>`、`<c.loud>`、`<00:00:01.000>`),
    /// 以及 SRT 正文里**机器编号的说话人前缀**。人名前缀保留 —— 「James Cridland:」是有用信息。
    private static func cleanCueText(_ line: String) -> String {
        var s = line
        if let r = tagRegex {
            s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let r = speakerRegex {
            s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `HH:MM:SS,mmm` / `HH:MM:SS.mmm` / `MM:SS.mmm`(VTT 允许省略小时)→ 毫秒。
    /// 时间行两侧可能带空格和排版设置(`align:start position:0%`),故先按空白切出第一段。
    static func parseClock(_ s: String) -> Int? {
        guard let token = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first
            .map(String.init)?
            .replacingOccurrences(of: ",", with: ".") else { return nil }
        let seg = token.split(separator: ":", omittingEmptySubsequences: false)
        // 只认 `HH:MM:SS` / `MM:SS`:原先允许单段数字,于是正文里混进的一行 "5"
        // 会被当成 5 秒造出一个假 cue(H150)
        guard seg.count == 2 || seg.count == 3 else { return nil }
        var ms = 0.0
        for p in seg {
            guard let v = Double(p) else { return nil }
            ms = ms * 60 + v   // 从高位往低位累乘,兼容 2 段与 3 段
        }
        return Int((ms * 1000).rounded())
    }

    // MARK: - Podcast Index JSON

    /// `{"segments":[{"startTime":0.0,"endTime":1.5,"body":"…"}]}`
    /// (`startTime`/`endTime` 单位是**秒的浮点**)。粒度很不统一:有的一条一整句,
    /// 有的一条只有一两个词 —— 一律先合成"能读的一行",原始条目留在 `words` 里。
    private static func parseJSON(_ text: String) -> [TranscribedSegment]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            Log.w("Transcript", "JSON 稿格式不认")
            return nil
        }
        let arr: [Any]
        if let a = root as? [Any] {
            arr = a                                        // 根就是数组的稿
        } else if let o = root as? [String: Any], let a = o["segments"] as? [Any] {
            arr = a                                        // Podcast Index 标准形
        } else {
            return nil
        }
        var words: [TranscribedWord] = []
        words.reserveCapacity(arr.count)
        for item in arr {
            guard let o = item as? [String: Any] else { continue }
            let body = pickString(o, ["body", "text", "word"])
            if body.isEmpty { continue }
            let s = pickMs(o, ["startTime", "start", "startMs"])
            let e = pickMs(o, ["endTime", "end", "endMs"])
            if s < 0 { continue }
            words.append(TranscribedWord(text: body, startMs: s, endMs: e > s ? e : s))
        }
        // JSON 稿是纯词,条目不自带空格 ⇒ spaced = true
        return words.isEmpty ? nil : TranscriptLines.mergeWords(words, spaced: true)
    }

    private static func pickString(_ o: [String: Any], _ keys: [String]) -> String {
        for k in keys {
            if let v = o[k] as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }

    /// 键名以 `Ms` 结尾的当毫秒,其它当**秒(浮点)**;取不到返回 -1。
    /// 用四舍五入而不是截断 —— 断句门是 400 / 900 这种整数阈值,一端截断一端进位,
    /// 同一份稿就会在临界值上分叉(鸿蒙一直是 `Math.round`)。
    private static func pickMs(_ o: [String: Any], _ keys: [String]) -> Int {
        for k in keys {
            var n: Double?
            if let num = o[k] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                n = num.doubleValue
            } else if let s = o[k] as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                n = d
            }
            if let n {
                return k.hasSuffix("Ms") ? Int(n.rounded()) : Int((n * 1000).rounded())
            }
        }
        return -1
    }
}
