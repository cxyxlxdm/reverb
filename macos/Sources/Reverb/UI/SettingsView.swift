import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 设置(标准 macOS 设置窗口):外观 / 内容 / 播放 / 备份 / 足迹。
struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    var body: some View {
        SettingsForm(env: env, settings: env.settings, player: env.player, update: env.update)
    }
}

private struct SettingsForm: View {
    let env: AppEnvironment
    @ObservedObject var settings: SettingsStore
    @ObservedObject var player: PlayerController
    @ObservedObject var update: SelfUpdate
    @ObservedObject var downloadStore: DownloadStore

    init(env: AppEnvironment, settings: SettingsStore, player: PlayerController, update: SelfUpdate) {
        self.env = env
        self.settings = settings
        self.player = player
        self.update = update
        self.downloadStore = env.downloads
    }

    /// 主题名。**这四条同时是本地化 key**(`Text(LocalizedStringKey(...))`),
    /// 改动要连 Localization/*.lproj 一起改。「· 宣纸 / · 水墨」的后缀与 Android、鸿蒙一致。
    private let themeNames = ["跟随系统", "浅色 · 宣纸", "深色 · 水墨", "纯白"]
    /// 地区列表。**12 项,与 Android `REGION_OPTIONS` / 鸿蒙 `Genres.ets` `REGIONS` 逐项同序同码**
    /// (`docs/MACOS-GAPS.md` D1):少一项就等于"这份目录在桌面上取不到",不是显示问题。
    /// 名称同时是本地化 key,加一项要连 4 个 `.lproj` 一起加(简中是代码里的 key 本身)。
    private let regions: [(code: String, name: String)] = [
        ("", "自动"), ("cn", "中国大陆"), ("hk", "中国香港"), ("tw", "中国台湾"),
        ("us", "美国"), ("jp", "日本"), ("kr", "韩国"), ("gb", "英国"),
        ("sg", "新加坡"), ("au", "澳大利亚"), ("ca", "加拿大"), ("de", "德国")
    ]
    private let skipBackOptions = [5, 10, 15, 30]
    private let skipForwardOptions = [15, 30, 45, 60]

    /// 失败提示的三种标题。**这三条同时是本地化 key**,改动要连 Localization/*.lproj 一起改;
    /// 文案对齐 Android / 鸿蒙的同名提示(硬规矩 5),取值口径见 Localization/en 同段注释。
    /// 用枚举而不是 String:alert 的标题参数要 StaticString 形态的 LocalizedStringKey,
    /// 运行期拼出来的 String 不会被查表本地化。
    private enum Prompt: Equatable {
        case none, sendFailed, saveFailed, backupFailed

        var title: LocalizedStringKey {
            switch self {
            case .none: return ""
            case .sendFailed: return "日志发送失败"
            case .saveFailed: return "保存失败"
            case .backupFailed: return "备份失败"
            }
        }
    }

    @State private var showFootprint = false
    @State private var showExportPicker = false
    @State private var restorePayload: RestorePayload?
    @State private var restoreUnreadable = false
    @State private var confirmClearDownloads = false
    @State private var confirmClearLog = false
    /// 缓存总量;`-1` = 还在算(显示「计算中…」而不是一个会被下一个瞬间推翻的 0)。
    @State private var cacheBytes: Int64 = -1
    @State private var confirmClearCache = false
    @State private var logSizeText = ""
    @State private var shareLogURL: URL?
    @State private var prompt: Prompt = .none
    @State private var showAbout = false
    @State private var showLicenses = false
    /// 局域网同步面板。打开时才创建控制器,关闭即停止监听(与 Android `showLanSync` 同口径)。
    @State private var showLanSync = false
    /// 功能聚合开关(1.1.0)。
    @State private var showFeatures = false
    /// 本视图所在窗口的激活态。**重算时机要挂在它上面,而不是只挂 `.onAppear`**:
    /// SwiftUI 的 `Settings` scene 关掉窗口是**隐藏、不销毁** ⇒ 一次运行里 `.onAppear` 只跑第一次,
    /// 第二次 ⌘, 打开时缓存与日志两个数还停在第一次那一刻(用户读到的是永不过期的假值,见 H215)。
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.themeMode) {
                    ForEach(0..<themeNames.count, id: \.self) { Text(LocalizedStringKey(themeNames[$0])).tag($0) }
                }
                Picker("主题配色", selection: $settings.accentIndex) {
                    ForEach(0..<Theme.accents.count, id: \.self) { i in
                        Text(LocalizedStringKey(Theme.accents[i].name)).tag(i)
                    }
                }
                Picker("语言", selection: $settings.language) {
                    Text("跟随系统").tag("")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "繁體中文").tag("zh-Hant")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Français").tag("fr")
                    Text(verbatim: "Español").tag("es")
                }
                Text("重启后生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("字号")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.fontScale * 100))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $settings.fontScale, in: 0.85...1.3, step: 0.05)
                }
            }

            Section("内容") {
                Picker("地区", selection: $settings.regionOverride) {
                    ForEach(regions, id: \.code) { Text(LocalizedStringKey($0.name)).tag($0.code) }
                }
                Picker("电台模式", selection: $settings.contextualRadio) {
                    Text("随机").tag(false)
                    Text("情境").tag(true)
                }
            }

            Section("播放") {
                Picker("默认速度", selection: Binding(
                    get: { settings.defaultSpeed },
                    set: { settings.defaultSpeed = $0; player.setSpeed($0) }
                )) {
                    ForEach(player.speedSteps, id: \.self) { s in
                        Text(String(format: "%g×", s)).tag(s)
                    }
                }
                Picker("快退", selection: $settings.skipBackSec) {
                    ForEach(skipBackOptions, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("快进", selection: $settings.skipForwardSec) {
                    ForEach(skipForwardOptions, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Toggle("逐字稿", isOn: $settings.transcriptionEnabled)
                Text("在播放页新增「转录」页,完全离线转录当前单集(需 macOS 26,首次按语言下载模型)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("足迹") {
                SettingsRowButton(
                    title: "听觉足迹",
                    systemImage: "seal",
                    trailing: AnyView(Text("\(env.stamps.stamps.count) 枚").foregroundStyle(.secondary)),
                    showsChevron: true
                ) { showFootprint = true }
            }

            Section("备份") {
                SettingsRowButton(title: "导出备份", systemImage: "square.and.arrow.up") {
                    showExportPicker = true
                }
                SettingsRowButton(title: "恢复备份", systemImage: "square.and.arrow.down") {
                    restoreBackup()
                }
                SettingsRowButton(title: "导出 OPML", systemImage: "list.bullet.rectangle") {
                    exportOPML()
                }
                SettingsRowButton(title: "导入 OPML", systemImage: "tray.and.arrow.down") {
                    importOPML()
                }
            }

            // 单独一段:它不是"备份文件"的又一种格式,而是两台设备之间的实时合并
            // (Android 那段注释同样说明了为什么不并进「备份」)。聚合开关关掉时整段不出现。
            if settings.lanSyncEnabled {
                Section("局域网") {
                    SettingsRowButton(
                        title: "局域网同步",
                        subtitle: Text("在同一 Wi-Fi 下与另一台设备合并订阅、收藏、印记、批注与进度，正在听的一集可接着听"),
                        systemImage: "wifi.router",
                        showsChevron: true
                    ) { showLanSync = true }
                }
            }

            Section("存储") {
                // 与 Android `SettingsScreen.kt` / 鸿蒙 `SettingsPage.ets` 同一个分区口径:
                // 缓存(可再生的)一行、下载(用户点名要留的)一行,清空入口分开。
                // 合成一个「清除缓存」会把下载一并删掉,而那正是用户最不该被顺手清掉的东西。
                SettingsRowButton(
                    title: "清除缓存",
                    subtitle: Text("榜单、频道、图片、逐字稿与已播音频缓存"),
                    systemImage: "trash.slash",
                    trailing: AnyView(
                        Text(cacheBytes < 0 ? "计算中…" : cacheSizeText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    )
                ) { confirmClearCache = true }
                .disabled(cacheBytes < 0)
                // .plain 按钮不吃系统的 disabled 变灰,显式给一半透明度,和「计算中…」一致。
                .opacity(cacheBytes < 0 ? 0.55 : 1)
                SettingsRow(
                    title: "离线下载",
                    systemImage: "internaldrive",
                    trailing: AnyView(
                        Text("\(downloadStore.downloads.count) 集 · \(usageText)")
                            .foregroundStyle(.secondary)
                    )
                )
                if !downloadStore.downloads.isEmpty {
                    SettingsRowButton(title: "清空下载", systemImage: "trash", destructive: true) {
                        confirmClearDownloads = true
                    }
                }
            }

            // 功能开关放在维护区(日志之前),不进页首:它是"改应用形态"的元设置。
            Section("功能") {
                SettingsRowButton(
                    title: "功能开关",
                    subtitle: Text("关闭不需要的模块：逐字稿、电台、投放、局域网同步"),
                    systemImage: "switch.2",
                    showsChevron: true
                ) { showFeatures = true }
            }

            Section("日志") {
                SettingsRow(
                    title: "日志",
                    systemImage: "doc.text",
                    trailing: AnyView(Text(logSizeText).foregroundStyle(.secondary))
                )
                // 四行顺序与 Android `SettingsScreen.kt` / 鸿蒙 `SettingsPage.ets` 一致
                // (分享 → 邮件 → 导出 → 清空,D6)。这不是审美问题:三端同一节设置,
                // 用户按位置记按钮,顺序不同就会点错一次。
                if let url = shareLogURL {
                    ShareLink(item: url) {
                        SettingsRow(title: "分享日志",
                                    systemImage: "square.and.arrow.up.on.square",
                                    interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                SettingsRowButton(title: "发送日志到开发者邮箱", systemImage: "envelope") {
                    mailLog()
                }
                SettingsRowButton(title: "导出日志…", systemImage: "square.and.arrow.up") {
                    exportLog()
                }
                SettingsRowButton(title: "清空日志", systemImage: "trash", destructive: true) {
                    confirmClearLog = true
                }
            }

            // 应用内更新(与 Android「设置 → 检查更新」同一个入口位置:关于之上)。
            // 读数写在行内副标题里,不弹「已是最新」那种只有「知道了」的窗 —— 主动查询的反馈
            // 放在原地比打断正在做的事更省事(Android 那一行同一条理由)。
            Section("更新") {
                SettingsRowButton(
                    title: "检查更新",
                    subtitle: Text(updateStatusText),
                    systemImage: "arrow.triangle.2.circlepath",
                    // 检测与下载都只给一个转圈:进度百分比已经写在副标题里,
                    // 再加一条不定长进度条只会让这一行看起来有两处在动。
                    trailing: update.busy ? AnyView(ProgressView().controlSize(.small)) : nil
                ) { update.checkNow() }
                .disabled(update.busy)
                .opacity(update.busy ? 0.55 : 1)
            }

            // 四行的顺序与 Android `SettingsScreen.kt` 的同名分区逐项对应
            // (关于 → 隐私政策 → 开源许可 → 版本,M11)。隐私政策这一行**不能只在首启出现**:
            // 平台合规指引要求应用内随时可查,所以它在设置里常驻,指向官网那份完整政策。
            Section("关于") {
                SettingsRowButton(title: "关于余音", systemImage: "info.circle", showsChevron: true) {
                    showAbout = true
                }
                SettingsRowButton(
                    title: "隐私政策",
                    subtitle: Text("我们如何处理你的数据"),
                    systemImage: "hand.raised",
                    trailing: AnyView(
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.tertiary)
                    )
                ) { AppInfo.openPrivacyPolicy() }
                SettingsRowButton(title: "开源许可",
                                  systemImage: "doc.text.magnifyingglass",
                                  showsChevron: true) {
                    showLicenses = true
                }
                SettingsRow(
                    title: "版本",
                    systemImage: "number",
                    trailing: AnyView(
                        Text(AppInfo.version)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    )
                )
            }
        }
        .onAppear { refreshLogSize(); prepareShareLog(); refreshCacheSize() }
        // 设置窗口第二次打开时 `.onAppear` 不会再跑(见 `controlActiveState` 那条注释),
        // 所以把入场那三件事在**每次窗口重新成为关键窗口**时重做一遍:
        // 缓存与日志两个数、以及给 ShareLink 备的那份临时日志文件,否则它们停在第一次开窗那一刻。
        // 只在 `.key` 时做:切到别的窗口(失焦)不该触发一次全盘扫描(硬规矩 6)。
        .onChange(of: controlActiveState) { state in
            if state == .key { refreshLogSize(); prepareShareLog(); refreshCacheSize() }
        }
        .confirmationDialog("确定清空日志?", isPresented: $confirmClearLog, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                Log.clear()
                refreshLogSize()
                prepareShareLog()
            }
            Button("取消", role: .cancel) {}
        }
        .formStyle(.grouped)
        // 只声明最小/理想尺寸,把上限留给窗口;原先写死的 `width:height:` 会把设置窗钉成不可缩放。
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity,
               minHeight: 560, idealHeight: 620, maxHeight: .infinity)
        // `Settings` 场景本身不认 `.windowResizability`(2026-11-23 实测:`AXSize` 不可设置),
        // 只能从底层 NSWindow 补 `.resizable`,见下面 `SettingsWindowConfigurator`。
        .background(SettingsWindowConfigurator())
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
        .confirmationDialog("清除缓存?", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("清除", role: .destructive) { clearCaches() }
            Button("取消", role: .cancel) {}
        } message: {
            // 正文照抄 Android `confirm_clear_cache`:三端这一句说的是同一件事(硬规矩 5)
            Text("将清除榜单、频道缓存、图片、已生成的逐字稿与已播音频缓存，不影响订阅与下载。")
        }
        .confirmationDialog("清空全部离线下载?", isPresented: $confirmClearDownloads, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                for d in downloadStore.downloads { env.downloadManager.delete(d.episode.id) }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showFootprint) {
            FootprintView()
                .environmentObject(env)
                .environmentObject(settings)
                .themedSheet(settings)
        }
        // 关于页与许可页都做成 sheet(设置窗口本身是 Form,推不出新页):
        // 与「听觉足迹」同一种呈现,尺寸由内容自己声明。
        .sheet(isPresented: $showAbout) {
            AboutView()
                .environmentObject(settings)
                .tint(Theme.accent(settings.accentIndex))
                .themedSheet(settings)
        }
        .sheet(isPresented: $showLanSync) {
            LanSyncSheet(env: env)
        }
        .sheet(isPresented: $showFeatures) {
            FeatureSwitchSheet(settings: settings, player: player)
                .tint(Theme.accent(settings.accentIndex))
                .themedSheet(settings)
        }
        .sheet(isPresented: $showLicenses) {
            LicensesView()
                .environmentObject(settings)
                .tint(Theme.accent(settings.accentIndex))
                .themedSheet(settings)
        }
        // 导出分区勾选。选择集由弹窗自持(初值全勾,与另两端一致),不进外部状态 ——
        // 与恢复弹窗同一个理由:sheet 闭包首开会拿到外部状态的旧快照。
        // 确认后先把 sheet 收起,再在下一轮 run loop 里弹保存面板:NSSavePanel 是独立模态窗口,
        // 直接叠在 sheet 上会被 sheet 压在下面,看起来像"点了没反应"。
        .sheet(isPresented: $showExportPicker) {
            ExportSheet(
                onExport: { sections in
                    showExportPicker = false
                    DispatchQueue.main.async { exportBackup(sections) }
                },
                onCancel: { showExportPicker = false })
            .tint(Theme.accent(settings.accentIndex))
            .themedSheet(settings)
        }
        // 弹窗用 item 驱动而非 isPresented + 外部状态:sections/selection 与弹出
        // 写在同一事务时,sheet 内容闭包首开会拿到旧快照 —— 选项区整块空白,
        // 关掉重开才正常(探针已证明同样的行在独立窗口渲染无恙)。
        // payload 自己携带数据,内容闭包只读弹窗入参,不存在时序差。
        .sheet(item: $restorePayload) { payload in
            RestoreSheet(
                sections: payload.sections,
                onApply: { selection in
                    BackupManager.apply(env, payload.json, selection)
                    restorePayload = nil
                },
                onCancel: { restorePayload = nil })
            .tint(Theme.accent(settings.accentIndex))
            .themedSheet(settings)
        }
        .alert("无法恢复备份", isPresented: $restoreUnreadable) {
            Button("好", role: .cancel) {}
        } message: {
            Text("这个文件无法识别为余音的备份,可能已损坏或来自不兼容的版本。")
        }
        // 只给标题、不给正文:Android / 鸿蒙上这三条本来就是 toast 的一句短语,
        // 在这里换成 alert 也不新增双端没有的文案,免得同一件事在三端读出三种话。
        .alert(prompt.title, isPresented: Binding(get: { prompt != .none }, set: { if !$0 { prompt = .none } })) {
            Button("好", role: .cancel) {}
        }
    }

    /// 「检查更新」那一行的读数。六种状态与 Android 设置页同一套语义,只有文案按桌面改:
    /// 桌面包没有蜂窝计费那一问,所以默认副标题不提网络类型。
    private var updateStatusText: String {
        switch update.state {
        case .idle:
            return String(localized: "到 GitHub 查一次有没有新的安装包")
        case .checking:
            return String(localized: "正在检查…")
        case .upToDate(let tag):
            return String(format: String(localized: "已是最新版本 %@"), tag)
        case .checkFailed:
            return String(localized: "检查失败，看看网络之后再试一次")
        case .downloading(let pct):
            return String(format: String(localized: "正在下载新版本 %d%%"), pct)
        case .ready(let rel, _):
            return String(format: String(localized: "新版本 %@ 已下载完成"), rel.tag)
        }
    }

    private var usageText: String {
        let bytes = env.downloadManager.usageBytes()
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private var cacheSizeText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: max(0, cacheBytes))
    }

    /// 算缓存总量:榜单/频道(仓库自己写的两份文件)、逐字稿、封面、已播音频四块之和。
    ///
    /// 逐字稿、封面、音频三份可能各自上百个文件,扫描丢到后台(硬规矩 8:await 回来之后的
    /// 同步计算照样占调用线程)。榜单/频道在同一个目录里只有十来个文件,留在主 actor 上算
    /// —— 它是 `@MainActor` 仓库的方法,硬要挪到后台就得把它那两个 store 也改造成 Sendable,
    /// 为一个十几行的目录读付这个代价不值。
    /// 四条**分头要、一起显示**:任一格算不出来就沿用 0,不让一个目录读失败把整行卡在「计算中…」。
    private func refreshCacheSize() {
        let repoBytes = env.repository.cacheSizeBytes()
        let audio = env.audioCache
        Task {
            let rest = await Task.detached(priority: .utility) {
                TranscriptStore.diskUsageBytes() + audio.usageBytes()
            }.value
            let artBytes = await ArtworkCache.shared.usageBytes()
            cacheBytes = repoBytes + rest + artBytes
        }
    }

    /// 清除四类可再生数据。**不动**订阅、历史、批注、下载、设置 —— 它们的文件与缓存同在
    /// `Application Support/Reverb` 下,所以每一格都只按自己的文件名/子目录删,
    /// 没有一处用「把目录清空」这种省事的写法。
    private func clearCaches() {
        env.repository.clearCaches()
        env.transcripts.clearAll()
        env.audioCache.clearAll()
        cacheBytes = -1
        Task {
            await ArtworkCache.shared.clear()
            refreshCacheSize()
        }
    }

    // MARK: - 文件操作

    /// 写盘并把成败交回调用方。原先这五处清一色 `try? … data(using:)?.write(to:)`:
    /// 磁盘满、选了只读卷、沙箱拒绝时用户点了「导出」什么也不会发生,连日志都没有。
    /// IO 留在 detached 线程(硬规矩 8:await 回来之后的同步计算照样占调用线程),
    /// 只有 Bool 回主线程驱动提示。
    private func writeText(_ text: String, to url: URL) async -> Bool {
        await Task.detached {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                Log.e("Settings", "写入失败:\(url.lastPathComponent)", error: error)
                return false
            }
        }.value
    }

    /// 导出前先让人勾分区(与 Android / 鸿蒙的 `BackupSectionDialog` 同口径)。
    /// 原先这里写死 `Set(allCases)`:想只导出订阅做搬家,桌面做不到,只能连历史与统计一起带走。
    private func exportBackup(_ sections: Set<BackupManager.Section>) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reverb-backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let json = BackupManager.build(env, sections)
        Task {
            let ok = await writeText(json, to: url)
            if !ok { prompt = .backupFailed }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let json = await readString(url) else { return }
            let sections = BackupManager.sectionsIn(json)
            // 解析不出任何分区时必须给可见反馈 —— 曾经静默 return,
            // 用户视角就是「导入了没任何效果」,连错在哪都无从查起(H86)
            guard !sections.isEmpty else {
                Log.e("Backup", "恢复探测失败:文件无法识别为余音备份")
                restoreUnreadable = true
                return
            }
            restorePayload = RestorePayload(json: json, sections: sections)
        }
    }

    private func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reverb.opml"
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let xml = BackupManager.exportOPML(env)
        Task {
            // 失败提示与鸿蒙同口径(`backup_failed`):Android 这一格原先成功失败都不出声,
            // 补的是 Android 那一侧,不是把这里改成静默。
            let ok = await writeText(xml, to: url)
            if !ok { prompt = .backupFailed }
        }
    }

    private func importOPML() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let xml = await readString(url) { BackupManager.importOPML(env, xml) }
        }
    }

    private func readString(_ url: URL) async -> String? {
        await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
    }

    // MARK: - 日志

    private func refreshLogSize() {
        let bytes = Log.totalSizeBytes()
        let f = ByteCountFormatter()
        f.countStyle = .file
        logSizeText = f.string(fromByteCount: Int64(bytes))
    }

    /// 将当前完整日志写入临时文件,供 ShareLink 分享。
    /// 失败时不弹提示:这个函数由 `.onAppear` 和「清空日志」自动调用,用户此刻并没有点「发送」,
    /// 弹一句「日志发送失败」反而莫名其妙。改成把分享入口撤掉(ShareLink 只在有文件时渲染)+ 留日志。
    private func prepareShareLog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reverb-log.txt")
        Task {
            let text = await Task.detached { Log.allText() }.value
            let ok = await writeText(text, to: url)
            shareLogURL = ok ? url : nil
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reverb-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let text = await Task.detached { Log.allText() }.value
            let ok = await writeText(text, to: url)
            if !ok { prompt = .saveFailed }
        }
    }

    /// 用系统邮件把日志作为附件发到开发者邮箱;无邮件客户端时回退到 mailto + 在访达中定位日志文件。
    private func mailLog() {
        let devEmail = "woooxooom@gmail.com"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reverb-log.txt")
        Task {
            let text = await Task.detached { Log.allText() }.value
            // 附件那份写不出去就别把邮件起草出去:否则用户发走的是一封挂着不存在/上一次内容的附件
            let ok = await writeText(text, to: url)
            guard ok else { prompt = .sendFailed; return }
            let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let body = String(localized: "请描述你遇到的问题:\n\n\n——\n余音 macOS v\(ver) · \(os)") as NSString
            let items: [Any] = [body, url]
            if let svc = NSSharingService(named: .composeEmail), svc.canPerform(withItems: items) {
                svc.recipients = [devEmail]
                svc.subject = String(localized: "余音 macOS 日志反馈")
                svc.perform(withItems: items)
            } else {
                // 未配置邮件客户端:打开 mailto 起草,并在访达中选中日志文件方便手动拖入附件
                if let mailto = URL(string: "mailto:\(devEmail)?subject=%E4%BD%99%E9%9F%B3%20macOS%20%E6%97%A5%E5%BF%97%E5%8F%8D%E9%A6%88") {
                    NSWorkspace.shared.open(mailto)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// 设置行:静态行直接用,可点的行由 `SettingsRowButton` 包一层。
///
/// 两种行共用同一套图标宽度与文字排版,页面里不再有"一行像系统按钮、隔壁一行像纯文本"
/// 的参差(用户点名的那组:足迹 / 备份 / 存储 / 离线下载 / 日志 / 更新 / 关于)。
/// 可点行的图标用强调色、开新层级的行在右端补一个 chevron,提示可点但不加按钮底框。
///
/// 副标题必须让行高自己撑开:caption 曾经被表单行高裁掉下半截 ——
/// 原因是 `Button` 默认样式会按控件单行高度排版标签。所以这里同时做两件事:
/// 可点的行统一 `.buttonStyle(.plain)`(去掉控件自带的高度假设),
/// 标题+副标题那个 `VStack` 挂 `.fixedSize(vertical:)`,让多行说明参与行高计算。
private struct SettingsRow: View {
    let title: LocalizedStringKey
    var subtitle: Text? = nil
    let systemImage: String
    var trailing: AnyView? = nil
    var showsChevron = false
    var destructive = false
    /// 由 `SettingsRowButton` 置 true;静态行走默认值。
    var interactive = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .foregroundStyle(iconStyle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                if let subtitle {
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let trailing { trailing }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 可点行的图标跟设置窗口的 `.tint` 走(用户选的主题配色),静态行退到次色。
    private var iconStyle: AnyShapeStyle {
        if destructive { return AnyShapeStyle(Color.red) }
        return interactive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }
}

/// 可点的设置行:整体点击区是 `SettingsRow` 那一行,去掉系统按钮的底框与固定行高。
private struct SettingsRowButton: View {
    let title: LocalizedStringKey
    var subtitle: Text? = nil
    let systemImage: String
    var trailing: AnyView? = nil
    var showsChevron = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRow(title: title, subtitle: subtitle, systemImage: systemImage,
                        trailing: trailing, showsChevron: showsChevron,
                        destructive: destructive, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

/// 导出备份:勾选要写的分区后交给调用方落盘。
/// 版式与 `RestoreSheet` 同形(复选框、语义色、不用 `.formStyle(.grouped)`,理由见那边注释),
/// 初值全勾 —— 与 Android `BackupSectionDialog(available = null, selected = 全集)` 一致。
private struct ExportSheet: View {
    @State private var selection = Set(BackupManager.Section.allCases)
    var onExport: (Set<BackupManager.Section>) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("备份数据").font(.headline).padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("选择要备份的内容")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                    ForEach(BackupManager.Section.allCases) { section in
                        Toggle(LocalizedStringKey(section.label), isOn: Binding(
                            get: { selection.contains(section) },
                            set: { on in
                                if on { selection.insert(section) } else { selection.remove(section) }
                            }))
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 16)
            }
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("备份") { onExport(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
            .padding(24)
        }
        .frame(width: 420, height: 500)
    }
}

/// 弹窗载荷:备份 json 与探测出的分区一起随 item 传入。
private struct RestorePayload: Identifiable {
    let id = UUID()
    let json: String
    let sections: Set<BackupManager.Section>
}

/// 恢复备份:勾选要合并的分区后应用。selection 由弹窗自持,
/// 初值在 init 里从入参同步,首帧就是完整勾选态(不依赖弹出后再补一轮状态)。
private struct RestoreSheet: View {
    let sections: Set<BackupManager.Section>
    @State private var selection: Set<BackupManager.Section> = []
    var onApply: (Set<BackupManager.Section>) -> Void
    var onCancel: () -> Void

    init(sections: Set<BackupManager.Section>,
         onApply: @escaping (Set<BackupManager.Section>) -> Void,
         onCancel: @escaping () -> Void) {
        self.sections = sections
        self.onApply = onApply
        self.onCancel = onCancel
        _selection = State(initialValue: sections)
    }

    private var available: [BackupManager.Section] {
        BackupManager.Section.allCases.filter { sections.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("恢复备份").font(.headline).padding(24)
            Divider()
            // 不用 Form(.grouped):grouped 表单的行底色与文字色由系统外观驱动,
            // 跟 themedSheet 的 preferredColorScheme 不同步 —— 深色主题下
            // 分区行整块不可见,表头与按钮反而正常(H86)。
            // 普通行 + 语义色,colorScheme 一变即跟随。
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("选择要合并的内容")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                    ForEach(available) { section in
                        Toggle(LocalizedStringKey(section.label), isOn: Binding(
                            get: { selection.contains(section) },
                            set: { on in
                                if on { selection.insert(section) } else { selection.remove(section) }
                            }))
                            // 复选框(框在文字左侧),与 Android 恢复弹窗的多选形态一致
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 16)
            }
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("恢复") { onApply(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
            .padding(24)
        }
        .frame(width: 420, height: 500)
    }
}

/// 功能聚合开关(1.1.0):四项各自即改即存 —— `SettingsStore` 的 `didSet` 写 UserDefaults,
/// 打开的这些视图(顶部分段、播放页投播按钮)都观察同一个对象,不需要「确定」这一步。
/// 用 checkbox 而不是开关列表:这与另三端的多选框形态一致,一眼能看出「勾 = 开着」。
struct FeatureSwitchSheet: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("功能开关")
                    .font(.headline)
                Text("关闭不需要的模块：逐字稿、电台、投放、局域网同步。正在播放的直播流会在关闭电台时停止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("逐字稿", isOn: $settings.transcriptionEnabled)
                    .toggleStyle(.checkbox)
                Toggle("电台", isOn: $settings.radioEnabled)
                    .toggleStyle(.checkbox)
                Toggle("投放", isOn: $settings.castEnabled)
                    .toggleStyle(.checkbox)
                Toggle("局域网同步", isOn: $settings.lanSyncEnabled)
                    .toggleStyle(.checkbox)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 400)
        // 直播流没有"整段"边界,关掉入口后留着只会持续耗流量;普通播客/下载音频不动。
        .onChange(of: settings.radioEnabled) { on in
            if !on && player.current?.isLive == true { player.close() }
        }
    }
}

/// SwiftUI 的 `Settings` 场景在 macOS 上不理会 `.windowResizability(.contentMinSize)` ——
/// 2026-11-23 实测窗口 styleMask 只有 32771(titled + closable + fullSizeContentView),`AXSize`
/// 不可设置,设置窗拉不动。SwiftUI 没有公开钩子,只能拿到底层 NSWindow 后把 `.resizable`
/// 补进 styleMask。
///
/// 但只补一次会被擦掉:每次 key/main 切换 SwiftUI 都会把 mask 写回 32771(实测点一下主窗口
/// 再回来,补丁就没了)。所以还要盯着 `styleMask` 的 KVO —— 只要看到 `.resizable` 被摘掉就在
/// 下一轮 runloop 再补。补完会触发一次 KVO(true),判据直接跳过,不会自激。
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var observed: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window {
                if w !== observed {
                    stopObserving()
                    observed = w
                    w.addObserver(self, forKeyPath: "styleMask", options: [.new], context: nil)
                }
            } else {
                stopObserving()
            }
            apply()
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            guard window?.styleMask.contains(.resizable) == false else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let w = window, !w.styleMask.contains(.resizable) else { return }
            w.styleMask.insert(.resizable)
            // 最小尺寸给到整张表单可用的下限(内容区 460×560),上限交给屏幕。
            w.contentMinSize = NSSize(width: 460, height: 560)
            w.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        }

        private func stopObserving() {
            observed?.removeObserver(self, forKeyPath: "styleMask")
            observed = nil
        }

        deinit { stopObserving() }
    }
}
