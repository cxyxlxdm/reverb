import Foundation

/// 私有订阅源的 HTTP Basic 凭据。与 Android `data/model/FeedCredential.kt` 逐条对齐。
///
/// **为什么有这个东西**:一部分 RSS 源(自建 / WordPress 会员站 / 有声书服务器)在
/// feed 与音频上都要求用户名密码,不带就一律 401。这类源与"URL 里带 token"的私密源
/// (Patreon 那一类)不是一回事 —— 后者不需要认证逻辑,我们的粘贴订阅本来就能用。
///
/// 凭据只用于**用户点名的那一个源**:feed 请求,以及同一主机(或互为子域)上的音频 /
/// 逐字稿请求。刻意不做"任何地址都带上" —— 音频经常放在第三方 CDN 上,那样等于
/// 把用户口令交给一个与他无关的主机(见 `FeedAuthStore.headerForUrl` 与 H253)。
struct FeedCredential: Codable, Equatable {
    let username: String
    let password: String

    /// `Authorization` 头。
    ///
    /// - Parameter utf8: true = 按 UTF-8 编;false = 按 RFC 7617 的默认字节语义(ISO-8859-1)。
    ///
    /// 不传参数时按内容自动选:含非 Latin-1 字符(中文口令)用 UTF-8,否则 ISO。
    /// 这条规则只适用于**不能重试**的调用点(音频 / 逐字稿)。feed 请求走的是
    /// `RssParser` 那套「先 ISO、401 再 UTF-8」,与 AntennaPod 同一条兜底 —— 因为
    /// RFC 7617 没有规定字符集,两种服务器都真实存在。
    func header(utf8: Bool) -> String {
        let raw = "\(username):\(password)"
        let bytes = utf8 ? Data(raw.utf8) : (raw.data(using: .isoLatin1) ?? Data(raw.utf8))
        return "Basic " + bytes.base64EncodedString()
    }

    var defaultHeader: String { header(utf8: needsUtf8) }

    /// 默认按 UTF-8 编:含 ISO-8859-1 表示不了的字符(中文口令)。
    ///
    /// ⚠️ 它**不是**「两种编码是否不同」。`é` 这类 Latin-1 表示得了的字符,ISO 与 UTF-8
    /// 编出来的字节并不一样(0xE9 vs 0xC3 0xA9),可这里仍是 false —— 拿它当重试门槛,
    /// 服务器按 UTF-8 解口令时就永远试不到第二发。重试的门槛是 [`encodingDiffers`]。
    var needsUtf8: Bool {
        (username + password).unicodeScalars.contains { $0.value > 255 }
    }

    /// 两种编码出来的头是否**真的不同** —— 只有不同才值得在 401 之后重试一次。
    ///
    /// 纯 ASCII 两串完全一样,重试等于重发同一个头;中文口令在 Swift 里 ISO 编码直接
    /// 失败、两串也都落成 UTF-8,同样不必重试;而 `é` / `ß` 这类字符两串不同 ——
    /// 服务器按 UTF-8 解时,第一发必然失败,这一发才是救回来的那发(见 H253)。
    var encodingDiffers: Bool { header(utf8: false) != header(utf8: true) }

    /// 把 `https://user:pass@host/feed.xml` 拆成(去掉 userinfo 的 URL, 凭据)。
    ///
    /// **必须把 userinfo 从 URL 里拿掉**,它有三个不该去的地方:
    ///  - 订阅列表与导出备份(口令会跟着 JSON 走);
    ///  - 运行日志(`url=…` 是全仓库通用的日志写法);
    ///  - 频道/单集的持久字段(分享卡片、widget 快照都可能再读一次)。
    /// 没有 userinfo 时原样返回(trim 之后),凭据为 nil。
    static func splitUrl(_ raw: String) -> (url: String, credential: FeedCredential?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed),
              let user = comps.user, !user.isEmpty else {
            return (trimmed, nil)
        }
        let pass = comps.password ?? ""
        comps.user = nil
        comps.password = nil
        return (comps.string ?? trimmed, FeedCredential(username: user, password: pass))
    }
}
