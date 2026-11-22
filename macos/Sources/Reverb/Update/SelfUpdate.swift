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
    private static let releasesURL = "https://api.github.com/repos/cxyxlxdm/revert-cast/releases?per_page=20"
    private static let assetAPIURL = "https://api.github.com/repos/cxyxlxdm/revert-cast/releases/assets/"
    /// 发布物按名字挑,不取 `assets[0]`:同一个 release 里还挂着 `reverb.apk`,
    /// 数组顺序不是契约(Android 侧同一条注释)。
    private static let dmgAssetName = "Reverb.dmg"

    /// 302 之后允许落地的主机。请求地址是本应用拼的,但**落地主机是远端给的** ——
    /// 下载到的东西会被用户打开,重定向到任意主机不拦就等于把「下什么」交给对方决定。
    private static let trustedHosts: Set<String> = [
        "api.github.com", "github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    private static let skippedKey = "update_skipped_tag"
    private static let category = "Update"

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
        guard let rel = await fetchLatest() else {
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

    /// 拉发布列表,挑「有 dmg 资产的、版本最高的、非草稿非预发布」那一条。
    ///
    /// **只对「传输层没拿到响应」重试一次**(间隔 1.2 秒)。依据是本机日志:2026-11-09 一次
    /// `403`(未带 token 的限额)之后紧跟 `got nothing`,2026-11-11 同一天的下载还撞过
    /// 「TLS 错误导致安全连接失败」;2026-11-19 实测本机 `github.com` 连 15 秒无响应、
    /// 同一时刻 `api.github.com` 200 —— 这条链路的失败**是瞬时的**,单次失败不代表发布页不可达。
    /// 服务端给了非 2xx 就不再重试:那是明确答复(403 是限额,重试只会再占一次)。
    /// 注意这**不是**根因修复:真被墙到连不上时,重试也只会把失败推迟一秒。
    private func fetchLatest() async -> Release? {
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
        // 目录里只该留着正在用的这一份:上次的残留不清理会一直占着几十 MB 级空间。
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in items where f.lastPathComponent != rel.fileName {
                try? FileManager.default.removeItem(at: f)
            }
        }
        let target = dir.appendingPathComponent(rel.fileName)
        let tmp = dir.appendingPathComponent(rel.fileName + ".part")
        for urlString in rel.urls {
            guard let url = URL(string: urlString) else { continue }
            try? FileManager.default.removeItem(at: tmp)
            let fetched = await UpdateDownloader(
                destination: tmp,
                allowedHosts: Self.trustedHosts,
                onPercent: { [weak self] pct in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(pct)
                    }
                }
            ).run(url)
            guard let file = fetched else {
                Log.w(Self.category, "下载失败 endpoint=\(Log.endpoint(urlString)) tag=\(rel.tag)")
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
            if rel.size > 0 && size?.int64Value != rel.size {
                Log.w(Self.category, "字节数不符 tag=\(rel.tag) got=\(size?.int64Value ?? -1) want=\(rel.size)")
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if let want = rel.sha256, Self.sha256(of: file) != want {
                Log.w(Self.category, "sha256 校验失败 tag=\(rel.tag)")
                try? FileManager.default.removeItem(at: file)
                continue
            }
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.moveItem(at: file, to: target)
            } catch {
                Log.e(Self.category, "更新包落盘失败", error: error)
                try? FileManager.default.removeItem(at: file)
                continue
            }
            Log.i(Self.category, "update downloaded tag=\(rel.tag) endpoint=\(Log.endpoint(urlString))")
            return target
        }
        return nil
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

/// 单个 dmg 的下载:进度、重定向主机闸、落地即搬走。
///
/// 用 delegate 形态而不是 `URLSession.download(from:)`,只有一个原因:**重定向要拦**。
/// 后者会自己跟完 302,等拿到最终 URL 时字节已经下完了 —— 那时再判主机只是事后记录。
/// 进度顺手就有了(下载完才更新一次状态的话,设置页那一行会长时间停在 0%)。
private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let allowedHosts: Set<String>
    private let onPercent: (Int) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var finished = false

    init(destination: URL, allowedHosts: Set<String>, onPercent: @escaping (Int) -> Void) {
        self.destination = destination
        self.allowedHosts = allowedHosts
        self.onPercent = onPercent
    }

    func run(_ url: URL) async -> URL? {
        await withCheckedContinuation { c in
            lock.lock()
            continuation = c
            lock.unlock()
            let cfg = URLSessionConfiguration.default
            // 60 MB 级的老口径是手机端的;桌面包只有几 MB,但网络慢时 20 秒也会掐断。
            cfg.timeoutIntervalForRequest = 60
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.httpAdditionalHeaders = [
                "User-Agent": "Reverb/1.0 (macOS podcast client)",
                // API 那个端点必须带这个头才会 302 到文件本体;不带就返回 JSON。
                "Accept": "application/octet-stream",
            ]
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            s.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        onPercent(min(99, max(0, pct)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            finish(nil, session: session)
            return
        }
        // `location` 在这个回调返回后就被系统删掉,必须当场搬走。
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(destination, session: session)
        } catch {
            Log.e("Update", "下载临时文件搬移失败", error: error)
            finish(nil, session: session)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            Log.w("Update", "下载链路失败 \(error.localizedDescription)")
        }
        finish(nil, session: session)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let host = request.url?.host, allowedHosts.contains(host) else {
            Log.w("Update", "重定向到不受信任的主机,已拒绝 \(request.url?.host ?? "?")")
            // 回 nil = 不跟随;调用方会拿到 3xx 的响应体,随后按字节数/摘要判失败。
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func finish(_ url: URL?, session: URLSession) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        c?.resume(returning: url)
    }
}
