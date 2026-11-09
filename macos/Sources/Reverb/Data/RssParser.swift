import Foundation

/// RSS/Atom 播客源解析器。下载 feed 并用 XMLParser 解析为频道 + 分集。
final class RssParser {

    /// 取回结果。**401 必须与"传输/解析失败"分开**:前者要弹用户名密码输入框,
    /// 后者只该显示加载失败 —— 混成一个 nil 的话,用户看到的永远是「加载失败」,
    /// 以为链接坏了(见 H253)。
    enum Outcome {
        case success(FeedResult)
        case unauthorized
        case failed
    }

    /// 拉取并解析 feed。频道 id 与 feedUrl 均记为传入的 feedUrl。
    /// - Parameter auth: 已存 / 用户刚输入的凭据。nil = 这个源还没有凭据。
    func fetch(_ feedUrl: String, auth: FeedCredential? = nil) async -> Outcome {
        let t0 = Date()
        Log.d("RSS", "fetch \(feedUrl)")
        let fetched = await download(feedUrl, auth: auth)
        if case .unauthorized = fetched { return .unauthorized }
        guard case .data(let data) = fetched, !data.isEmpty else {
            Log.w("RSS", "fetch 空数据 \(feedUrl) \(Log.ms(t0))")
            return .failed
        }

        let delegate = RssDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            Log.e("RSS", "fetch 解析失败 \(feedUrl) \(Log.ms(t0))", error: parser.parserError)
            return .failed
        }

        let channelTitle = delegate.channelTitle.trimmed
        guard !channelTitle.isEmpty || !delegate.items.isEmpty else {
            Log.w("RSS", "fetch 空频道 \(feedUrl) \(Log.ms(t0))")
            return .failed
        }

        let channelImage = firstNonEmpty(delegate.channelImageHref, delegate.channelImageUrl)
        let author = firstNonEmpty(delegate.channelAuthor, delegate.channelManagingEditor)
        let channelDesc = firstNonEmpty(delegate.channelDescription, delegate.channelSummary)

        let podcast = Podcast(
            id: feedUrl,
            title: channelTitle,
            author: author,
            artworkUrl: channelImage,
            feedUrl: feedUrl,
            description: channelDesc,
            genre: delegate.channelGenre.trimmed,
            isPaid: false,
            fundingUrl: delegate.channelFundingUrl.trimmed,
            fundingLabel: delegate.channelFundingLabel.trimmed
        )

        let episodes: [Episode] = delegate.items.compactMap { item in
            let audioUrl = (item["audioUrl"] ?? "").trimmed
            guard !audioUrl.isEmpty else { return nil }
            let guid = (item["guid"] ?? "").trimmed
            let desc = firstNonEmpty(item["description"], item["itunes:summary"], item["content:encoded"])
            let art = firstNonEmpty(item["itunesImage"], channelImage)
            let duration = parseDuration(item["itunes:duration"])
            return Episode(
                id: guid.isEmpty ? audioUrl : guid,
                title: (item["title"] ?? "").trimmed,
                description: desc,
                audioUrl: audioUrl,
                artworkUrl: art,
                podcastTitle: channelTitle,
                durationSec: duration,
                pubDate: (item["pubDate"] ?? "").trimmed,
                feedUrl: feedUrl,
                transcriptUrl: (item["transcriptUrl"] ?? "").trimmed,
                transcriptType: (item["transcriptType"] ?? "").trimmed
            )
        }

        guard !episodes.isEmpty || !channelTitle.isEmpty else {
            Log.w("RSS", "fetch 无有效内容 \(feedUrl) \(Log.ms(t0))")
            return .failed
        }
        Log.i("RSS", "fetch \"\(channelTitle)\" → \(episodes.count) 单集 \(Log.ms(t0))")
        return .success(FeedResult(podcast: podcast, episodes: episodes))
    }

    // MARK: - 下载

    private enum Download {
        case data(Data)
        case unauthorized
        case failed
    }

    /// 下载 feed 原文。**先 ISO-8859-1、401 再 UTF-8**(与 Android `RssParser` /
    /// AntennaPod `BasicAuthorizationInterceptor` 同一条兜底):RFC 7617 没有规定字符集,
    /// 两种服务器都真实存在。
    ///
    /// 401 只有两种可能:没带凭据,或凭据不对 —— 两种都要交给界面问一次。
    /// 静默失败在这里是最坏的结果,用户只会看到「加载失败」,然后以为链接坏了。
    private func download(_ feedUrl: String, auth: FeedCredential?) async -> Download {
        let first = await attempt(feedUrl, authorization: auth?.header(utf8: false))
        guard let first else { return .failed }
        if (200...299).contains(first.code) { return .data(first.data) }
        guard first.code == 401 else { return .failed }
        guard let auth, auth.encodingDiffers else { return .unauthorized }
        // 门槛是「两串字节真的不同」而不是「有非 Latin-1 字符」:`é` / `ß` 这类
        // Latin-1 表示得了的字符两串就不同,服务器按 UTF-8 解时只有第二发能过。
        // 纯 ASCII 与中文口令两串相同(中文在 Swift 里 ISO 编码失败、直接落成 UTF-8),
        // 不重复发同一个头。
        let second = await attempt(feedUrl, authorization: auth.header(utf8: true))
        guard let second else { return .failed }
        if (200...299).contains(second.code) { return .data(second.data) }
        return second.code == 401 ? .unauthorized : .failed
    }

    private func attempt(_ feedUrl: String, authorization: String?) async -> (data: Data, code: Int)? {
        var headers: [String: String] = [:]
        if let authorization { headers["Authorization"] = authorization }
        guard let r = await HTTP.fetch(feedUrl, headers: headers) else { return nil }
        if !(200...299).contains(r.code) {
            Log.w("RSS", "http \(r.code) endpoint=\(Log.endpoint(feedUrl))")
        }
        return r
    }

    // MARK: - 工具

    private func firstNonEmpty(_ values: String?...) -> String {
        for v in values {
            if let v = v?.trimmed, !v.isEmpty { return v }
        }
        return ""
    }

    /// 解析 itunes:duration:支持 "HH:MM:SS"、"MM:SS" 或纯秒数,返回秒。
    private func parseDuration(_ raw: String?) -> Int {
        guard let raw = raw?.trimmed, !raw.isEmpty else { return 0 }
        if raw.contains(":") {
            let parts = raw.split(separator: ":").map { Int($0) ?? 0 }
            switch parts.count {
            case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 2: return parts[0] * 60 + parts[1]
            case 1: return parts[0]
            default: return 0
            }
        }
        // 纯秒数,可能带小数。
        if let i = Int(raw) { return i }
        if let d = Double(raw) { return Int(d) }
        return 0
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// XMLParser 委托:逐元素累积文本,区分频道级与 item 级字段。
private final class RssDelegate: NSObject, XMLParserDelegate {
    // 频道级
    var channelTitle = ""
    var channelAuthor = ""
    var channelManagingEditor = ""
    var channelDescription = ""
    var channelSummary = ""
    var channelImageHref = ""     // itunes:image href
    var channelImageUrl = ""      // <image><url>
    var channelGenre = ""
    var channelFundingUrl = ""
    var channelFundingLabel = ""

    // item 级
    var items: [[String: String]] = []
    private var currentItem: [String: String]?

    // 解析状态
    private var buffer = ""
    private var inItem = false
    private var inImage = false
    private var pendingFundingUrl = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        buffer = ""
        switch elementName {
        case "item":
            inItem = true
            currentItem = [:]
        case "image":
            inImage = true
        case "enclosure":
            if inItem, let url = attributeDict["url"], !url.isEmpty {
                currentItem?["audioUrl"] = url
            }
        case "itunes:image":
            if let href = attributeDict["href"], !href.isEmpty {
                if inItem {
                    if currentItem?["itunesImage"]?.isEmpty ?? true { currentItem?["itunesImage"] = href }
                } else if channelImageHref.isEmpty {
                    channelImageHref = href
                }
            }
        case "itunes:category":
            if !inItem, channelGenre.isEmpty, let t = attributeDict["text"], !t.isEmpty {
                channelGenre = t
            }
        case "podcast:funding":
            if !inItem { pendingFundingUrl = attributeDict["url"] ?? "" }
        case "podcast:transcript":
            // 发布方自己的逐字稿(Podcasting 2.0)。**空元素、信息全在属性里**,
            // 所以和 `podcast:funding` / `itunes:image` 一样只能在 START_TAG 取。
            // 一集常有多条(同一稿的不同格式,外加 `rel="captions"` 的字幕版),
            // 按 transcriptRank 取最优,不是"取第一条" —— 与 Android `RssParser` 同一规则。
            if inItem, let url = attributeDict["url"], !url.isEmpty {
                let type = attributeDict["type"] ?? ""
                let rank = Self.transcriptRank(type)
                let best = Int(currentItem?["transcriptRank"] ?? "") ?? -1
                if rank > best {
                    currentItem?["transcriptUrl"] = url
                    currentItem?["transcriptType"] = type
                    currentItem?["transcriptRank"] = String(rank)
                }
            }
        default:
            break
        }
    }

    /// 只收带时间轴的格式:JSON(Podcast Index 那套,可能带词级时间)> VTT > SRT。
    /// HTML / 纯文本稿常见但没有时间轴,拿来做不了跟读高亮,直接排除(同 Android)。
    private static func transcriptRank(_ type: String) -> Int {
        let t = type.lowercased()
        if t.contains("json") { return 3 }
        if t.contains("vtt") { return 2 }
        if t.contains("srt") || t.contains("subrip") { return 1 }
        return -1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            buffer += s
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "item":
            if let item = currentItem { items.append(item) }
            currentItem = nil
            inItem = false

        case "image":
            inImage = false

        case "title":
            if inItem {
                setItem("title", value)
            } else if !inImage {
                if channelTitle.isEmpty { channelTitle = value }
            }

        case "url":
            // <image><url>...</url></image> 的频道封面。
            if inImage, !inItem, channelImageUrl.isEmpty { channelImageUrl = value }

        case "description":
            if inItem {
                setItem("description", value)
            } else if channelDescription.isEmpty {
                channelDescription = value
            }

        case "itunes:summary":
            if inItem {
                setItem("itunes:summary", value)
            } else if channelSummary.isEmpty {
                channelSummary = value
            }

        case "content:encoded":
            if inItem { setItem("content:encoded", value) }

        case "itunes:author":
            if !inItem, channelAuthor.isEmpty { channelAuthor = value }

        case "managingEditor":
            if !inItem, channelManagingEditor.isEmpty { channelManagingEditor = value }

        case "itunes:category":
            // 部分源以文本形式给出分类。
            if !inItem, channelGenre.isEmpty, !value.isEmpty { channelGenre = value }

        case "guid":
            if inItem { setItem("guid", value) }

        case "itunes:duration":
            if inItem { setItem("itunes:duration", value) }

        case "pubDate":
            if inItem { setItem("pubDate", value) }

        case "podcast:funding":
            if !inItem, channelFundingUrl.isEmpty {
                channelFundingUrl = pendingFundingUrl
                channelFundingLabel = value
            }

        default:
            break
        }

        buffer = ""
    }

    /// 仅在字段尚为空时写入,避免嵌套元素覆盖首个有效值。
    private func setItem(_ key: String, _ value: String) {
        guard currentItem != nil else { return }
        if (currentItem?[key]?.isEmpty ?? true), !value.isEmpty {
            currentItem?[key] = value
        }
    }
}
