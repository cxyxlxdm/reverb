import Foundation

/// 把逐字稿拼成可以交给系统分享的两种文本:纯文本 / Markdown。
///
/// 这是 Android `util/TranscriptExport.kt` 的逐条移植,**输出必须逐字节一致** ——
/// 同一个用户在两台设备上导同一集,拿到的文件应该能互相 diff,而不是两种排版。
///
/// **每句都带时间轴**:`[12:03]` 是点一下就能跳回去的位置。用户在笔记、邮件或聊天里
/// 读到这一句时能凭它找回原处 —— 去掉时间戳的"干净版"反而没有用处。
///
/// 时间戳的位数按**整篇时长**决定:一小时以内写 `12:03`,超过一小时才写 `1:12:03`。
/// 逐句各判一次会让同一份文件里两种形状混排(前面 `12:03`、后面 `1:02:03`),
/// 看着像两份稿拼起来的。
enum TranscriptExport {

    enum Format: String, CaseIterable {
        case text
        case markdown

        var fileExtension: String { self == .text ? "txt" : "md" }
        var mime: String { self == .text ? "text/plain" : "text/markdown" }
    }

    static func build(episode: Episode, segments: [TranscribedSegment], format: Format) -> String {
        let withHours = (segments.last?.endMs ?? 0) >= hourMs
        let title = oneLine(episode.title).isEmpty ? "Transcript" : oneLine(episode.title)
        let channel = oneLine(episode.podcastTitle)
        var out = ""
        switch format {
        case .text:
            out += title + "\n"
            if !channel.isEmpty { out += channel + "\n" }
            out += "\n"
            for seg in segments {
                out += "[" + stamp(ms: seg.startMs, withHours: withHours) + "] " + oneLine(seg.text) + "\n"
            }
        case .markdown:
            out += "# " + title + "\n\n"
            if !channel.isEmpty { out += "_" + channel + "_\n\n" }
            for seg in segments {
                out += "- [" + stamp(ms: seg.startMs, withHours: withHours) + "] " + oneLine(seg.text) + "\n"
            }
        }
        return out
    }

    /// `12:03` 或 `1:12:03`;负数按 0 处理(时间轴上游保证过,但导出不该被一条脏数据带崩)。
    static func stamp(ms: Int, withHours: Bool) -> String {
        let total = max(ms, 0) / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if withHours {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// 分享到别的 App 的文件名。去掉路径分隔符与控制字符 —— 一集标题里出现 `/` 或换行
    /// 并不罕见(尤其发布方把"第 3 期 / 上"直接当标题),原样落盘会多一层目录或直接抛异常。
    static func fileName(episode: Episode, format: Format) -> String {
        var base = oneLine(episode.title)
        base = String(base.map { invalidFileChars.contains($0) || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 })
        base = base.trimmingCharacters(in: .whitespaces)
        base = String(base.prefix(maxNameChars)).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "transcript" }
        return base + "." + format.fileExtension
    }

    private static let invalidFileChars: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
    private static let maxNameChars = 80
    private static let hourMs = 3_600_000

    /// 一行化。逐字稿本身按句切开,理论上不含换行;但导出是**离开 App 之后**的产物,
    /// 一条带 `\n` 的文本会把一批纯文本行拆散、把 Markdown 列表打断,所以在这一道收口。
    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
