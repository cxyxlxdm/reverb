import Foundation
import Combine
import AppKit
import CryptoKit

/// 应用内更新(macOS)。
///
/// 与 Android `update/SelfUpdate.kt` 同一套口径,但**落点按桌面改了两处**,理由写在各自的位置:
///
/// ① 检测:读 GitHub 发布页的 release **列表**(不是 `releases/latest`)。列表自带每个资产的
///    `size` 与 `digest`,一次调用就能对上「要下的那份字节」;`latest` 只有一份,也依赖发版时
///    把指针移过来 —— 同版本重出包时指针不动,一旦漏移就永远问的是一版旧的(Android 侧 H203/H234)。
/// ② 安装:下载完**不自己装**,用 `NSWorkspace` 打开磁盘映像,由用户自己把 .app 拖进「应用程序」。
///    桌面没有「安装未知应用」权限这一步,也没有系统安装器可以交接;`.dmg` 被打开之后
///    是否覆盖旧版本是 Finder 的动作,应用无从代劳,也不该代劳。
///
/// ⚠️ **没有「同版本重出包」的检测**:Android 靠比对发布页资产的 sha256 与本机 APK 的 sha256,
/// 而 macOS 装的是 `.app`、发布的是 `.dmg`(压缩镜像),两者字节不可比;`Info.plist` 的
/// `CFBundleVersion` 又不在 tag 里。所以本端只按**版本名**判新旧 —— 同一个版本号重出包
/// (1.0.6 这种一天重打多次的情形)不会主动提示,用户在「设置 → 检查更新」里主动点也不会有新结果。
/// 这是已知残余,不要拿「Linux 上解包 dmg 再比 .app」之类的办法硬凑:那要读已安装包的
/// 全部内容,代价与误报都不划算。
///
/// **它在同意门之后才跑**:入口挂在 `RootView` 的 `.task` 上,而 `RootView` 只在
/// `PrivacyGate` 放行后才会被构建 —— 未同意时一次请求都发不出去,与发现页那批 `.task` 同一道门。
@MainActor
final class SelfUpdate: ObservableObject {

    // MARK: - 状态

    enum State: Equatable {
        case idle
        case checking
        /// 主动检测时「没有更新」的读数。自动那一轮不写它 —— 否则设置页会凭空多一句「已是最新」。
        case upToDate(String)
        /// 主动检测失败。自动那一轮失败回到 `idle`(静默,H235 的落点要求)。
        case checkFailed
        case downloading(Int)
        case ready(Release, URL)
    }

    /// 一次发布的下载信息。`size`/`sha256` 取自发布页资产,用于下载后校验。
    struct Release: Equatable {
        let tag: String
        /// 候选下载地址,按顺序试:先 API 资产端点(302 到文件本体),再发布页直链。
        let urls: [String]
        let size: Int64
        let sha256: String?

        /// 落盘文件名。tag 会被拼进路径,所以先滤掉路径分隔符这类字符 —— tag 来自远端,
        /// 不能假设它只含版本号该有的字符。
        var fileName: String {
            let safe = tag.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            return "Reverb-\(safe.isEmpty ? "update" : safe).dmg"
        }
    }

    @Published private(set) var state: State = .idle

    /// 是否正在检测或下载。设置页据此禁用那一行,并挡住重复点击。
    var busy: Bool {
        if case .checking = state { return true }
        if case .downloading = state { return true }
        return false
    }

    // MARK: - 常量

    /// 发布页的 **release 列表**接口。`per_page=20` 的取法与 Android 同一条理由:
    /// 未带 token 时 GitHub 是**每 IP 每小时 60 次**,检测必须始终只占 1 次,且一次不翻页。
    ///
    /// ⚠️ 2026-11-23 起它**不再是检测主路**:限额用尽时这里回 403,用户侧只看到「检查更新失败」。
    /// 主路改成下面的 Atom 流;这个接口只用来顺手取 digest / 资产端点,以及 Atom 失败时兜底。
    private nonisolated static let releasesURL = "https://api.github.com/repos/cxyxlxdm/revert-cast/releases?per_page=20"
    private nonisolated static let assetAPIURL = "https://api.github.com/repos/cxyxlxdm/revert-cast/releases/assets/"
    /// 发布流(Atom)。不需要 token、不占 REST API 的每 IP 60 次限额,DNS/TLS 也是另一条链路。
    private nonisolated static let releasesAtomURL = "https://github.com/cxyxlxdm/revert-cast/releases.atom"
    /// 发布物按名字挑,不取 `assets[0]`:同一个 release 里还挂着 `reverb.apk`,
    /// 数组顺序不是契约(Android 侧同一条注释)。
    private nonisolated static let dmgAssetName = "Reverb.dmg"

    /// 302 之后允许落地的主机。请求地址是本应用拼的,但**落地主机是远端给的** ——
    /// 下载到的东西会被用户打开,重定向到任意主机不拦就等于把「下什么」交给对方决定。
    private static let trustedHosts: Set<String> = [
        "api.github.com", "github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    private static let skippedKey = "update_skipped_tag"
    private nonisolated static let category = "Update"

    /// 每次进程只自动跑一次。主动点「检查更新」不受它限制。
    private var started = false
    private var running = false

    // MARK: - 入口

    /// 启动后自动检测一次。挂在 `RootView.task` 上(同意门之后),重复调用安全。
    func start() {
        guard !started else { return }
        started = true
        Task { await check(manual: false) }
    }

    /// 设置页「检查更新」。与自动那一轮同一条路径,只差三件事:
    /// 不受「已跳过」静音、不受每进程一次的限制、没有更新或失败都要给个可见读数。
    func checkNow() {
        Task { await check(manual: true) }
    }

    /// 「以后再说」:把**这一版**记成已跳过,下次冷启动不再自动问。
    /// 主动点「检查更新」不看这一格(用户都主动问了,别拿旧决定挡他)。
    func dismiss(_ rel: Release) {
        UserDefaults.standard.set(rel.tag, forKey: Self.skippedKey)
        state = .idle
        Log.i(Self.category, "用户选择以后再说 tag=\(rel.tag)")
    }

    // MARK: - 检测

    private func check(manual: Bool) async {
        guard !running else { return }
        running = true
        defer { running = false }
        state = .checking

        guard let local = Self.localVersion else {
            // 不走 Bundle 的调试运行(或 Info.plist 读不出来)时不判版本 ——
            // 拿一个不是版本号的串去比,只会在开发机上天天弹更新。
            Log.w(Self.category, "读不到本机版本,跳过检查")
            state = manual ? .checkFailed : .idle
            return
        }
        guard let rel = await fetchLatest(local: local) else {
            recordCheckFailure(manual)
            return
        }
        guard Self.isNewer(rel.tag, than: local) else {
            Log.i(Self.category, "update check up-to-date local=\(local) remote=\(rel.tag)")
            state = manual ? .upToDate(rel.tag) : .idle
            return
        }
        if !manual && (UserDefaults.standard.string(forKey: Self.skippedKey) == rel.tag) {
            // 静默,不能写成 upToDate:设置页那一行会跟着显示「已是最新」,
            // 而其实是有更新、只是被跳过的(Android 侧同一条)。
            Log.i(Self.category, "update skipped tag=\(rel.tag)")
            state = .idle
            return
        }
        Log.i(Self.category, "update available remote=\(rel.tag) local=\(local) size=\(rel.size)")
        if let file = existingFile(for: rel) {
            state = .ready(rel, file)
            promptInstall(rel, file)
            return
        }
        state = .downloading(0)
        guard let file = await download(rel) else {
            // 自动那一轮失败静默(原因在日志里);主动点的那一轮必须给个说法。
            Log.w(Self.category, "update download failed tag=\(rel.tag) manual=\(manual)")
            state = .idle
            if manual { promptFailure(rel) }
            return
        }
        state = .ready(rel, file)
        promptInstall(rel, file)
    }

    /// 检测失败的落点。自动那一轮必须回到 `idle` 而不是停在 `checking` —— 停在中间态会让
    /// 设置页那一行一直显示「正在检查…」,而 `busy` 又会把之后所有手动点击吞到进程重启为止(H235)。
    private func recordCheckFailure(_ manual: Bool) {
        Log.w(Self.category, "update check got nothing manual=\(manual)")
        state = manual ? .checkFailed : .idle
    }

    /// 本机版本名。`AppInfo.version` 在非 bundle 运行时给 `"?"`,那种值不能拿去比。
    private static var localVersion: String? {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !v.isEmpty, v != "?" else { return nil }
        return v
    }

    /// 拉发布页信息,挑「有 dmg 资产的、版本最高的」那一条。
    ///
    /// **主路走 Atom 发布流,不走 REST API**(2026-11-23 起):`api.github.com` 未带 token
    /// 每 IP 每小时只有 60 次,用尽后回 403 / `remaining: 0`;而应用内更新在用户侧只表现为
    /// 「检查更新失败」,看不出是限额。Atom 流不占 REST 限额,且与 API 不是同一条网络链路
    /// (2026-11-19 实测 `github.com` 无响应而 `api.github.com` 200),两条互为兜底。
    ///
    /// Atom 只给 tag,不给资产大小与 digest。所以:
    /// ① 先比版本,不是新的就直接返回,一次资产探测都不发;
    /// ② 是新的才摸资产:直链 HEAD 取字节数;REST API 只作为**可选增强**(有配额时顺带拿 digest
    ///    与资产端点),拿不到不影响检测;
    /// ③ Atom 也失败时才退回 REST 列表接口。
    ///
    /// 只对「传输层没拿到响应」重试一次(间隔 1.2 秒),依据是日志里那些瞬时 403/TLS/超时;
    /// 服务端给了非 2xx 是明确答复,不再重试。
    private func fetchLatest(local: String) async -> Release? {
        if let rel = await fetchViaAtom(local: local) { return rel }
        return await fetchViaAPI()
    }

    private func fetchViaAtom(local: String) async -> Release? {
        var response: (data: Data, code: Int)?
        for attempt in 0..<2 {
            response = await HTTP.fetch(Self.releasesAtomURL,
                                        headers: ["Accept": "application/atom+xml"],
                                        timeout: 15)
            if response != nil { break }
            Log.w(Self.category, "update atom transport failed attempt=\(attempt + 1)")
            if attempt == 0 { try? await Task.sleep(for: .seconds(1.2)) }
        }
        guard let (data, code) = response else { return nil }
        guard (200...299).contains(code) else {
            Log.w(Self.category, "update atom http \(code) endpoint=\(Log.endpoint(Self.releasesAtomURL))")
            return nil
        }
        let tags = Self.parseAtomTags(data)
        guard let newest = tags.first else {
            Log.w(Self.category, "update atom no version tags bytes=\(data.count)")
            return nil
        }
        guard Self.isNewer(newest, than: local) else {
            // 没有新版:返回一条不带下载地址的读数就够了。**不能在这里顺手调 API 拿 digest** ——
            // 那样每次冷启动又回到一天 60 次的限额里,而绝大多数启动都属于这一格。
            return Release(tag: newest, urls: [], size: 0, sha256: nil)
        }
        // 有新版时才值得摸一次资产。REST 元数据是可选的:配额用尽时返回空表,直链 HEAD 照常工作。
        let metadata = await fetchAtomMetadata()
        for tag in tags.prefix(5) where Self.isNewer(tag, than: local) {
            let direct = Self.directDMGURL(tag: tag)
            if let meta = metadata[tag], meta.size > 0 {
                var urls = meta.urls
                if !urls.contains(direct) { urls.append(direct) }
                return Release(tag: tag, urls: urls, size: meta.size, sha256: meta.sha256)
            }
            if let size = await headSize(direct) {
                return Release(tag: tag, urls: [direct], size: size, sha256: nil)
            }
            Log.w(Self.category, "update atom asset unavailable tag=\(tag)")
        }
        return nil
    }

    /// Atom 之外只再摸一次 REST 列表,用来给下载补上 digest 与 API 资产端点。
    /// 失败(403 / 超时)是**正常降级**,不当成检测失败 —— 直链那条路已经能下。
    private func fetchAtomMetadata() async -> [String: AssetMeta] {
        guard let (data, code) = await HTTP.fetch(
            Self.releasesURL, headers: ["Accept": "application/vnd.github+json"]) else {
            Log.i(Self.category, "update atom metadata unavailable; continue without digest")
            return [:]
        }
        guard (200...299).contains(code) else {
            Log.i(Self.category, "update atom metadata http \(code); continue without digest")
            return [:]
        }
        return Self.parseAssetMap(data)
    }

    /// 直链 HEAD:确认资产存在并拿到字节数。只发 HEAD,不读正文。
    /// 302 的落地主机同样要在名单里 —— 最终读到的长度是远端给的,不能无限信任。
    private func headSize(_ urlString: String) async -> Int64? {
        guard let url = URL(string: urlString) else { return nil }
        for attempt in 0..<2 {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 15
            req.setValue("Reverb/1.0 (macOS podcast client)", forHTTPHeaderField: "User-Agent")
            do {
                let (_, response) = try await HTTP.session.data(for: req)
                guard let http = response as? HTTPURLResponse else { return nil }
                let landed = http.url?.host ?? ""
                guard Self.trustedHosts.contains(landed) else {
                    Log.w(Self.category, "update head untrusted host \(landed)")
                    return nil
                }
                guard (200...299).contains(http.statusCode) else { return nil }
                return http.expectedContentLength > 0 ? http.expectedContentLength : nil
            } catch {
                Log.w(Self.category, "update head failed attempt=\(attempt + 1) \(error.localizedDescription)")
                if attempt == 0 { try? await Task.sleep(for: .seconds(1.2)) }
            }
        }
        return nil
    }

    /// Atom 走不通时退回原来的 REST 列表路径。
    private func fetchViaAPI() async -> Release? {
        for attempt in 0..<2 {
            guard let (data, code) = await HTTP.fetch(
                Self.releasesURL, headers: ["Accept": "application/vnd.github+json"]) else {
                Log.w(Self.category, "update check transport failed attempt=\(attempt + 1)")
                if attempt == 0 {
                    try? await Task.sleep(for: .seconds(1.2))
                    continue
                }
                return nil
            }
            guard (200...299).contains(code) else {
                Log.w(Self.category, "update check http \(code) endpoint=\(Log.endpoint(Self.releasesURL))")
                return nil
            }
            return Self.parseReleases(data)
        }
        return nil
    }

    nonisolated static func directDMGURL(tag: String) -> String {
        let safe = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        return "https://github.com/cxyxlxdm/revert-cast/releases/download/\(safe)/\(dmgAssetName)"
    }

    /// Atom 流里每条 entry 的 `<title>` 就是 tag。只认纯数字版本(可带 v 前缀);
    /// 预发布/带后缀的 tag 不当作稳定版,免得把 beta 推给用户。去重后按版本降序。
    nonisolated static func parseAtomTags(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: "<entry>.*?<title>([^<]+)</title>",
                                                options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        var seen = Set<String>()
        var tags: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 1 else { continue }
            let raw = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isStableVersionTag(raw), seen.insert(raw).inserted else { continue }
            tags.append(raw)
        }
        return tags.sorted { isNewer($0, than: $1) }
    }

    nonisolated static func isStableVersionTag(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, f == "v" || f == "V" { s.removeFirst() }
        guard !s.isEmpty else { return false }
        return s.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
    }

    /// API 列表 → 按 tag 索引的资产信息。给 Atom 路径补 digest 用。
    nonisolated static func parseAssetMap(_ data: Data) -> [String: AssetMeta] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            Log.w(category, "update metadata parse failed bytes=\(data.count)")
            return [:]
        }
        var out: [String: AssetMeta] = [:]
        for dict in list {
            if dict["draft"] as? Bool == true || dict["prerelease"] as? Bool == true { continue }
            guard let tag = dict["tag_name"] as? String,
                  let assets = dict["assets"] as? [[String: Any]] else { continue }
            let asset = assets.first { ($0["name"] as? String) == dmgAssetName }
                ?? assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg") }
            guard let asset else { continue }
            var urls: [String] = []
            if let id = (asset["id"] as? NSNumber)?.intValue {
                urls.append(assetAPIURL + String(id))
            }
            if let direct = asset["browser_download_url"] as? String { urls.append(direct) }
            guard !urls.isEmpty else { continue }
            var sha: String?
            if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
                sha = String(digest.dropFirst("sha256:".count))
            }
            out[tag] = AssetMeta(size: (asset["size"] as? NSNumber)?.int64Value ?? 0,
                                 sha256: sha, urls: urls)
        }
        return out
    }

    struct AssetMeta {
        let size: Int64
        let sha256: String?
        let urls: [String]
    }

    /// release 列表 JSON → 最高的那条。解析失败与「没有任何带 dmg 的发布」分开记日志,
    /// 免得下一次排查又只看到一句 `got nothing`。
    nonisolated static func parseReleases(_ data: Data) -> Release? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            Log.w(category, "update check parse failed bytes=\(data.count)")
            return nil
        }
        var best: Release?
        for dict in list {
            if dict["draft"] as? Bool == true || dict["prerelease"] as? Bool == true { continue }
            guard let tag = dict["tag_name"] as? String,
                  let assets = dict["assets"] as? [[String: Any]] else { continue }
            let asset = assets.first { ($0["name"] as? String) == dmgAssetName }
                ?? assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg") }
            guard let asset else { continue }
            let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
            var urls: [String] = []
            if let id = (asset["id"] as? NSNumber)?.intValue {
                urls.append(assetAPIURL + String(id))
            }
            if let direct = asset["browser_download_url"] as? String { urls.append(direct) }
            guard !urls.isEmpty else { continue }
            // digest 形如 "sha256:…";老 release 没有这个字段,没有就先只对字节数。
            var sha: String?
            if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
                sha = String(digest.dropFirst("sha256:".count))
            }
            let rel = Release(tag: tag, urls: urls, size: size, sha256: sha)
            if best == nil || isNewer(rel.tag, than: best!.tag) { best = rel }
        }
        if best == nil { Log.w(category, "update check no dmg release in \(list.count) entries") }
        return best
    }

    /// 逐段比数字:1.0.10 > 1.0.9(字符串比大小会反过来)。缺的段按 0 补。
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = numericParts(remote), b = numericParts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated private static func numericParts(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let f = t.first, f == "v" || f == "V" { t.removeFirst() }
        return t.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }

    // MARK: - 下载

    private static var updateDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Reverb/update", isDirectory: true)
    }

    /// 上次下完没装(或装完又启动了一次):校验过就直接给安装,不再走一遍网络。
    private func existingFile(for rel: Release) -> URL? {
        let file = Self.updateDirectory.appendingPathComponent(rel.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        guard rel.size <= 0 || size?.int64Value == rel.size else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        if let want = rel.sha256, Self.sha256(of: file) != want {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return file
    }

    private func download(_ rel: Release) async -> URL? {
        let dir = Self.updateDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.e(Self.category, "创建更新目录失败", error: error)
            return nil
        }
        let target = dir.appendingPathComponent(rel.fileName)
        let part = URL(fileURLWithPath: target.path + ".part")
        let meta = URL(fileURLWithPath: target.path + ".part.json")
        // 目录里只该留着正在用的这一份:目标、分片、分片元数据。其余是旧版本残留(几十 MB 级)。
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let keep = Set([target.lastPathComponent, part.lastPathComponent, meta.lastPathComponent])
            for f in items where !keep.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            }
        }
        // 上次已下完整、只差改名(进程在最后一步被杀):校验后直接收尾,不再走网络。
        if rel.size > 0, Self.fileSize(part) == rel.size {
            if let want = rel.sha256, Self.sha256(of: part) != want {
                Log.w(Self.category, "分片 sha256 校验失败,丢弃 tag=\(rel.tag)")
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: meta)
            } else if Self.install(part: part, target: target, meta: meta) {
                return target
            }
        }
        if let partSize = Self.fileSize(part), rel.size > 0, partSize > rel.size {
            try? FileManager.default.removeItem(at: part)
            try? FileManager.default.removeItem(at: meta)
        }
        for urlString in rel.urls {
            guard let url = URL(string: urlString) else { continue }
            let ok = await UpdateDownloader(
                part: part,
                metaURL: meta,
                expectedTotal: rel.size,
                tag: rel.tag,
                allowedHosts: Self.trustedHosts,
                onPercent: { [weak self] pct in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(pct)
                    }
                }
            ).run(url)
            guard ok else {
                // 失败**保留分片与元数据**:下一次检测(Range/If-Range)接着下,不再整包重来。
                Log.w(Self.category, "下载未完成 endpoint=\(Log.endpoint(urlString)) tag=\(rel.tag) bytes=\(Self.fileSize(part) ?? 0)")
                continue
            }
            let size = Self.fileSize(part) ?? -1
            if rel.size > 0 && size != rel.size {
                Log.w(Self.category, "字节数不符 tag=\(rel.tag) got=\(size) want=\(rel.size)")
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: meta)
                continue
            }
            if let want = rel.sha256, Self.sha256(of: part) != want {
                Log.w(Self.category, "sha256 校验失败 tag=\(rel.tag)")
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: meta)
                continue
            }
            if Self.install(part: part, target: target, meta: meta) {
                Log.i(Self.category, "update downloaded tag=\(rel.tag) endpoint=\(Log.endpoint(urlString))")
                return target
            }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return n.int64Value
    }

    private static func install(part: URL, target: URL, meta: URL) -> Bool {
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: part, to: target)
            try? FileManager.default.removeItem(at: meta)
            return true
        } catch {
            Log.e(Self.category, "更新包落盘失败", error: error)
            return false
        }
    }

    /// 分块哈希,不把整个 dmg 读进内存(释放包几 MB 到几十 MB,不值当)。
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 决策弹窗

    /// 下载完成(或上次已下好)后的唯一一次决定:打开安装包,还是以后再说。
    private func promptInstall(_ rel: Release, _ file: URL) {
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "发现新版本 %@"), rel.tag)
        alert.informativeText = String(
            format: String(localized: "新版本 %@ 已下载完成（约 %@），现在打开安装包？"),
            rel.tag, Self.sizeText(rel.size))
        alert.addButton(withTitle: String(localized: "打开安装包"))
        alert.addButton(withTitle: String(localized: "以后再说"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(file)
            state = .idle
            Log.i(Self.category, "已打开安装包 tag=\(rel.tag)")
        } else {
            dismiss(rel)
        }
    }

    /// 只有主动检测才弹失败窗 —— 启动时自动查一次而网络不好,不该用模态窗打断用户。
    private func promptFailure(_ rel: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "更新下载失败")
        alert.informativeText = String(localized: "安装包没有下载成功。检查网络后重试，也可以选「以后再说」。")
        alert.addButton(withTitle: String(localized: "重试"))
        alert.addButton(withTitle: String(localized: "以后再说"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            checkNow()
        } else {
            dismiss(rel)
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "?" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

/// 分片元数据。只记录「这半截属于谁、远端给过什么校验器、总量多少」——
/// 续传的正确性全靠 ETag/Last-Modified 配上 `If-Range`:远端那一段没变才允许接。
struct UpdateResumeMeta: Codable, Equatable {
    let tag: String
    let etag: String?
    let lastModified: String?
    let total: Int64
}

/// 续传决策的纯逻辑,单独拎出来是为了能单测 —— 这部分错一次就是一份坏安装包。
enum UpdateResume {
    /// 能否从现有分片续:必须有校验器(否则分不清远端有没有换文件),总量也不能冲突。
    static func canResume(existing: Int64, meta: UpdateResumeMeta?, tag: String,
                          expectedTotal: Int64) -> Bool {
        guard existing > 0, let meta, meta.tag == tag else { return false }
        guard meta.etag != nil || meta.lastModified != nil else { return false }
        return meta.total <= 0 || expectedTotal <= 0 || meta.total == expectedTotal
    }

    /// `If-Range` 的值:优先强校验器 ETag,退而求其次用 Last-Modified。
    static func ifRange(_ meta: UpdateResumeMeta) -> String? {
        meta.etag ?? meta.lastModified
    }

    /// `Content-Range: bytes 1000-2023/6622867` → `(1000, 6622867)`;`*` 总量按 0。
    static func parseContentRange(_ raw: String?) -> (start: Int64, total: Int64)? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0] == "bytes" else { return nil }
        let halves = parts[1].split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let range = halves[0].split(separator: "-", maxSplits: 1)
        guard let start = Int64(range[0]) else { return nil }
        let total = halves[1] == "*" ? 0 : (Int64(halves[1]) ?? 0)
        return (start, total)
    }
}

/// 单个 dmg 的分片下载:Range/If-Range 续传、进度、重定向主机闸、完成后交给调用方校验。
///
/// 用 `URLSessionDataDelegate` 而不是 `URLSessionDownloadTask`,有两个理由:
/// ① 续传要自己控制 `Range` / `If-Range`,并且失败时**保留**分片;系统临时文件随任务结束消失,
///    跨候选、跨启动都接不上;
/// ② 重定向要拦。`URLSession.download(from:)` 会自己跟完 302,等拿到最终 URL 时字节已经下完了。
///
/// 「后台」在本端是进程级:macOS 应用退到后台仍会继续跑这条会话;应用被退出则分片留在缓存目录,
/// 下次启动的自动检测会带着 Range 接着下。没有用 background URLSession,是因为它的 downloadTask
/// 与自管的 Range 分片是两套恢复机制,叠在一起反而无法判断"哪一份字节算数"。
/// 不是 private 是为了让集成测试用真实的 206 / 200 / 416 响应驱动它(见 UpdateDownloaderResumeTests)。
final class UpdateDownloader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let part: URL
    private let metaURL: URL
    private let expectedTotal: Int64
    private let tag: String
    private let allowedHosts: Set<String>
    private let onPercent: (Int) -> Void

    private let lock = NSLock()
    private var session: URLSession?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false
    private var activity: NSObjectProtocol?

    // 下面这些只在 delegate 的串行回调里读写。
    private var handle: FileHandle?
    private var startOffset: Int64 = 0
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var lastPercent = -1
    private var writeFailed = false
    private var statusCode = 0

    init(part: URL, metaURL: URL, expectedTotal: Int64, tag: String,
         allowedHosts: Set<String>, onPercent: @escaping (Int) -> Void) {
        self.part = part
        self.metaURL = metaURL
        self.expectedTotal = expectedTotal
        self.tag = tag
        self.allowedHosts = allowedHosts
        self.onPercent = onPercent
    }

    func run(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Reverb/1.0 (macOS podcast client)", forHTTPHeaderField: "User-Agent")
        // API 那个端点必须带这个头才会 302 到文件本体;不带就返回 JSON。
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let existing = Self.fileSize(part)
        let meta = Self.loadMeta(metaURL, tag: tag)
        if UpdateResume.canResume(existing: existing, meta: meta, tag: tag, expectedTotal: expectedTotal),
           let meta {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            if let validator = UpdateResume.ifRange(meta) {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        } else if existing > 0 {
            // 没有校验器 / 总量对不上:宁可重下,也不要拼出一份坏包。
            try? FileManager.default.removeItem(at: part)
            try? FileManager.default.removeItem(at: metaURL)
        }

        // 等价于 Android 那把 partial wake lock:下载期间别让 App Nap 把这条网络请求按下去,
        // 也别让系统在收尾前睡过去。桌面端没有"前台服务",这是能拿到的最接近的驻留保证。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Downloading Reverb update")

        return await withCheckedContinuation { c in
            lock.lock()
            continuation = c
            lock.unlock()
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60
            cfg.waitsForConnectivity = true
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            lock.lock()
            session = s
            lock.unlock()
            s.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(false)
            return
        }
        statusCode = http.statusCode
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        switch http.statusCode {
        case 206:
            guard let range = UpdateResume.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start > 0, range.start == Self.fileSize(part) else {
                Log.w("Update", "续传响应不连续 range=\(http.value(forHTTPHeaderField: "Content-Range") ?? "?")")
                completionHandler(.cancel)
                finish(false)
                return
            }
            startOffset = range.start
            total = range.total > 0 ? range.total : max(expectedTotal, startOffset)
            do {
                let h = try FileHandle(forWritingTo: part)
                try h.seekToEnd()
                handle = h
            } catch {
                Log.e("Update", "打开分片失败", error: error)
                completionHandler(.cancel)
                finish(false)
                return
            }
            Self.saveMeta(UpdateResumeMeta(tag: tag, etag: etag,
                                           lastModified: lastModified, total: total), to: metaURL)
            report(force: true)
        case 200:
            // 远端忽略了 Range(或本来就没发):从头写,并覆盖旧分片与元数据。
            startOffset = 0
            total = http.expectedContentLength > 0 ? http.expectedContentLength : expectedTotal
            do {
                FileManager.default.createFile(atPath: part.path, contents: nil)
                handle = try FileHandle(forWritingTo: part)
            } catch {
                Log.e("Update", "创建分片失败", error: error)
                completionHandler(.cancel)
                finish(false)
                return
            }
            Self.saveMeta(UpdateResumeMeta(tag: tag, etag: etag,
                                           lastModified: lastModified, total: total), to: metaURL)
            report(force: true)
        default:
            Log.w("Update", "下载响应 http \(http.statusCode)")
            if http.statusCode == 416 {
                // 分片已越过远端资源(或远端换了一份):丢掉,下一次从 0 开始。
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: metaURL)
            }
            completionHandler(.cancel)
            finish(false)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            writeFailed = true
            Log.e("Update", "写分片失败", error: error)
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        report(force: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error {
            Log.w("Update", "下载中断 \(error.localizedDescription)")
        }
        let downloaded = startOffset + received
        let complete = !writeFailed && error == nil && statusCode != 0
            && (total <= 0 || downloaded == total)
            && (expectedTotal <= 0 || downloaded == expectedTotal)
        if !complete {
            Log.w("Update", "下载未完成 downloaded=\(downloaded) total=\(total) expected=\(expectedTotal)")
        }
        finish(complete)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let host = request.url?.host, allowedHosts.contains(host) else {
            Log.w("Update", "重定向到不受信任的主机,已拒绝 \(request.url?.host ?? "?")")
            // 回 nil = 不跟随;调用方会拿到 3xx 的响应体,随后按状态码判失败并保留分片。
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func report(force: Bool) {
        guard total > 0 else { return }
        let done = startOffset + received
        let pct = Int(Double(done) / Double(total) * 100)
        let clamped = min(100, max(0, pct))
        guard force || clamped != lastPercent else { return }
        lastPercent = clamped
        onPercent(clamped)
    }

    private func finish(_ ok: Bool) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        let s = session
        session = nil
        let a = activity
        activity = nil
        lock.unlock()
        if let a { ProcessInfo.processInfo.endActivity(a) }
        s?.finishTasksAndInvalidate()
        c?.resume(returning: ok)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return 0
        }
        return n.int64Value
    }

    private static func loadMeta(_ url: URL, tag: String) -> UpdateResumeMeta? {
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(UpdateResumeMeta.self, from: data),
              m.tag == tag else { return nil }
        return m
    }

    private static func saveMeta(_ meta: UpdateResumeMeta, to url: URL) {
        // 没有校验器就不落元数据:下一次 canResume 会判 false,从 0 开始,至少不会拼错。
        guard meta.etag != nil || meta.lastModified != nil else { return }
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
