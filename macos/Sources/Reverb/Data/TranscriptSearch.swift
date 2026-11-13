import Foundation

/// 逐字稿的全文搜索:找出**哪些句子**命中了,以及每句里**哪些区间**要贴底色。
///
/// 这是 Android `util/TranscriptSearch.kt` 的逐条移植,三端口径必须一致 ——
/// 同一段稿在两端搜同一句得到的高亮位置不同,会让跨端核对失去基本单位。
///
/// 为什么区间要在这里一次算完:渲染侧一句一次 `range(of:)` 看着不贵,但当前句的
/// 逐字高亮每帧都会重建一次 `AttributedString`(见 `TranscriptPage.KaraokeLine`),
/// 那句里的匹配区间就该是现成的。这与硬规矩 6 是同一件事:解析不要在渲染路径里做。
///
/// 区间用**字符下标**(grape offset)而不是 UTF-16 偏移:渲染侧 `AttributedString`
/// 的切片单位是 Character,拿 UTF-16 下标去切,含 emoji 的句子会错位。
/// 大小写折叠交给 `NSString` 的 `.caseInsensitive`,不自己做 `lowercased()` ——
/// 某些语言的大小写折叠会改变长度(土耳其语 İ 之类),拿折叠后的下标切原文会错位。
enum TranscriptSearch {

    /// 一条命中:句子的下标 + 该句内要贴底色的区间(字符下标,左闭右开)。
    struct Hit: Equatable {
        let index: Int
        let ranges: [Range<Int>]
    }

    struct Result: Equatable {
        let hits: [Hit]
        /// 与 `hits` 同源,按句下标索引 —— 渲染侧每行一次字典查找,不再逐行重扫。
        let rangesByIndex: [Int: [Range<Int>]]

        var isEmpty: Bool { hits.isEmpty }
    }

    static let empty = Result(hits: [], rangesByIndex: [:])

    /// - Parameter query: 调用方已经 `trim` 过。空串直接返回 [empty] —— 空白查询不该把整篇涂亮。
    static func find(segments: [TranscribedSegment], query: String) -> Result {
        if query.isEmpty || segments.isEmpty { return empty }
        var hits: [Hit] = []
        var ranges: [Int: [Range<Int>]] = [:]
        for (i, seg) in segments.enumerated() {
            let found = rangesIn(text: seg.text, query: query)
            if !found.isEmpty {
                hits.append(Hit(index: i, ranges: found))
                ranges[i] = found
            }
        }
        return Result(hits: hits, rangesByIndex: ranges)
    }

    /// 一句里的所有命中区间。从上一处命中之后继续找,单字符查询在长句里也不会退化成平方级。
    static func rangesIn(text: String, query: String) -> [Range<Int>] {
        if text.isEmpty || query.isEmpty { return [] }
        let ns = text as NSString
        var from = 0
        var out: [Range<Int>] = []
        while from < ns.length {
            let found = ns.range(
                of: query,
                options: [.caseInsensitive],
                range: NSRange(location: from, length: ns.length - from))
            if found.location == NSNotFound { break }
            // NSRange(UTF-16)→ String.Index → 字符下标,与渲染侧的切片单位对齐
            if let r = Range(found, in: text) {
                let start = text.distance(from: text.startIndex, to: r.lowerBound)
                let end = text.distance(from: text.startIndex, to: r.upperBound)
                if end > start { out.append(start..<end) }
                from = found.location + max(found.length, 1)
            } else {
                from = found.location + max(found.length, 1)
            }
        }
        return out
    }
}
