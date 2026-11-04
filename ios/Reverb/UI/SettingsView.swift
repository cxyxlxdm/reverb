import SwiftUI
import UIKit
import MessageUI
import UniformTypeIdentifiers

/// 设置:外观 / 内容 / 播放 / 存储 / 备份 / 日志 / 关于。
/// iOS 版没有「应用内更新」分区 —— 分发走 TestFlight 与 App Store,由系统负责更新。
struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var player: PlayerController

    private let themeNames = ["跟随系统", "浅色 · 宣纸", "深色 · 水墨", "纯白"]
    private let regions: [(code: String, name: String)] = [
        ("", "自动"), ("cn", "中国大陆"), ("hk", "中国香港"), ("tw", "中国台湾"),
        ("us", "美国"), ("jp", "日本"), ("kr", "韩国"), ("gb", "英国"),
        ("sg", "新加坡"), ("au", "澳大利亚"), ("ca", "加拿大"), ("de", "德国")
    ]
    private let skipBackOptions = [5, 10, 15, 30]
    private let skipForwardOptions = [15, 30, 45, 60]

    @State private var cacheBytes: Int64 = -1
    @State private var confirmClearCache = false
    @State private var confirmClearDownloads = false
    @State private var confirmClearLog = false
    @State private var showAbout = false
    @State private var showLicenses = false
    @State private var sectionSheet: SectionSheetKind?
    @State private var restorePayload: RestorePayload?
    @State private var restoreUnreadable = false
    @State private var importerKind: ImportKind = .backup
    @State private var showImporter = false
    @State private var exportDocument: TextFileDocument?
    @State private var exportType: UTType = .json
    @State private var exportName = "reverb-backup.json"
    @State private var showExporter = false
    @State private var shareLogURL: URL?
    @State private var logSizeText = ""
    @State private var alertText: LocalizedStringKey?
    @State private var showFootprint = false
    @State private var mailDraft = false
    @State private var mailBody = ""
    @State private var mailLogData = Data()

    /// 回到前台时刷新存储与日志读数:设置页的 `.onAppear` 只在首次出现时跑,
    /// 从播放/下载页回来时数字会停在打开那一刻。
    @Environment(\.scenePhase) private var scenePhase

    private var accent: Color { Theme.accent(settings.accentIndex) }

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.themeMode) {
                    ForEach(0..<themeNames.count, id: \.self) {
                        Text(LocalizedStringKey(themeNames[$0])).tag($0)
                    }
                }
                // 四档与 Android / 鸿蒙逐项相同(0.85 / 1.0 / 1.15 / 1.3),映射见 `FontScale`。
                Picker("字号", selection: Binding(
                    get: { FontScale.index(for: settings.fontScale) },
                    set: { settings.fontScale = FontScale.scales[$0] }
                )) {
                    ForEach(0..<FontScale.scales.count, id: \.self) { i in
                        Text(LocalizedStringKey(FontScale.labels[i])).tag(i)
                    }
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
            }

            Section("内容") {
                Picker("地区", selection: $settings.regionOverride) {
                    ForEach(regions, id: \.code) { Text(LocalizedStringKey($0.name)).tag($0.code) }
                }
                Button { showFootprint = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("听觉足迹")
                                .foregroundStyle(.primary)
                            Text("你盖下的所有印记，汇成一张足迹图")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                // Form 的默认 Button 样式会给标签上 tint,青瓷这类低饱和配色下整行读成
                // 「禁用」。用 plain 样式按普通可进入行画,与另三端一致。
                .buttonStyle(.plain)
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
                // 反向开关:存的是 `allowCellularDownload`,界面显示的是「仅 Wi-Fi」。
                // 与 Android `set_wifi_only` / 鸿蒙同一口径,默认关(只 Wi-Fi)。
                Toggle(isOn: Binding(
                    get: { !settings.allowCellularDownload },
                    set: { settings.allowCellularDownload = !$0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仅在 Wi-Fi 下载")
                        Text("关闭后蜂窝网络也允许下载与缓存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("语音转文字", isOn: $settings.transcriptionEnabled)
                Text("在播放页查看逐字稿,完全离线转录当前单集(需 iOS 26,首次按语言下载模型)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("提醒") {
                Toggle(isOn: Binding(
                    get: { settings.updatesEnabled },
                    set: { turnUpdates($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("订阅更新提醒")
                        Text("订阅有新一期时通知你")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("存储") {
                Button { confirmClearCache = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("清除缓存")
                            Text("榜单、频道、图片、逐字稿与已播音频缓存")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(cacheBytes < 0 ? String(localized: "计算中…") : cacheSizeText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .disabled(cacheBytes < 0)
                HStack {
                    Label("离线下载", systemImage: "internaldrive")
                    Spacer()
                    Text(String(format: NSLocalizedString("%lld 集 · %@", comment: ""),
                                Int64(env.downloads.downloads.count), usageText))
                        .foregroundStyle(.secondary)
                }
                if !env.downloads.downloads.isEmpty {
                    Button("清空下载", role: .destructive) { confirmClearDownloads = true }
                }
            }

            Section("备份") {
                Button { sectionSheet = .export } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                Button {
                    importerKind = .backup
                    showImporter = true
                } label: {
                    Label("恢复备份", systemImage: "square.and.arrow.down")
                }
                Button {
                    prepareExport(text: BackupManager.exportOPML(env),
                                  type: UTType(filenameExtension: "opml") ?? .xml,
                                  name: "reverb.opml")
                } label: {
                    Label("导出 OPML", systemImage: "list.bullet.rectangle")
                }
                Button {
                    importerKind = .opml
                    showImporter = true
                } label: {
                    Label("导入 OPML", systemImage: "tray.and.arrow.down")
                }
            }

            Section("日志") {
                HStack {
                    Label("日志", systemImage: "doc.text")
                    Spacer()
                    Text(logSizeText).foregroundStyle(.secondary)
                }
                if let url = shareLogURL {
                    ShareLink(item: url) {
                        Label("分享日志", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                Button { composeLogMail() } label: {
                    Label("发送日志到开发者邮箱", systemImage: "envelope")
                }
                Button { exportLog() } label: {
                    Label("导出日志…", systemImage: "square.and.arrow.up")
                }
                Button("清空日志", role: .destructive) { confirmClearLog = true }
            }

            Section("关于") {
                Button { showAbout = true } label: {
                    Label("关于余音", systemImage: "info.circle")
                }
                Button { AppInfo.openPrivacyPolicy() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("隐私政策")
                            Text("我们如何处理你的数据")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                Button { showLicenses = true } label: {
                    Label("开源许可", systemImage: "doc.text.magnifyingglass")
                }
                HStack {
                    Label("版本", systemImage: "number")
                    Spacer()
                    Text(AppInfo.version).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .tint(accent)
        .navigationTitle("设置")
        .toolbarTitleDisplayMode(.inlineLarge)
        .onAppear { refreshCacheSize(); refreshLogSize(); prepareShareLog() }
        // 设置页在 TabView 里常驻:从播放页/系统设置回来不会触发 `onAppear`,
        // 缓存在那期间可能已增长。回到前台时把两个读数重算一次。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshCacheSize(); refreshLogSize(); prepareShareLog()
            }
        }
        .alert("清除缓存?", isPresented: $confirmClearCache) {
            Button("清除", role: .destructive) { clearCaches() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除榜单、频道缓存、图片、已生成的逐字稿与已播音频缓存，不影响订阅与下载。")
        }
        .alert("清空全部离线下载?", isPresented: $confirmClearDownloads) {
            Button("清空", role: .destructive) {
                for d in env.downloads.downloads { env.downloadManager.delete(d.episode.id) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("确定清空日志?", isPresented: $confirmClearLog) {
            Button("清空日志", role: .destructive) {
                Log.clear()
                refreshLogSize()
                prepareShareLog()
            }
            Button("取消", role: .cancel) {}
        }
        .alert("无法恢复备份", isPresented: $restoreUnreadable) {
            Button("好", role: .cancel) {}
        } message: {
            Text("这个文件无法识别为余音的备份,可能已损坏或来自不兼容的版本。")
        }
        .alert(Text(alertText ?? ""), isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("好", role: .cancel) {}
        }
        .sheet(item: $sectionSheet) { kind in
            BackupSectionSheet(
                title: kind == .export ? "备份数据" : "恢复备份",
                subtitle: kind == .export ? "选择要备份的内容" : "选择要合并的内容",
                available: kind == .export
                    ? BackupManager.Section.allCases
                    : (restorePayload?.sections.sorted { $0.rawValue < $1.rawValue } ?? []),
                initial: kind == .export
                    ? Set(BackupManager.Section.allCases)
                    : (restorePayload?.sections ?? []),
                confirmTitle: kind == .export ? "备份" : "恢复"
            ) { picked in
                sectionSheet = nil
                if kind == .export {
                    prepareExport(text: BackupManager.build(env, picked),
                                  type: .json, name: "reverb-backup.json")
                } else if let payload = restorePayload {
                    BackupManager.apply(env, payload.json, picked)
                    restorePayload = nil
                }
            } onCancel: {
                sectionSheet = nil
            }
            .tint(accent)
        }
        .sheet(isPresented: $showAbout) {
            AboutView().environmentObject(settings)
        }
        .sheet(isPresented: $showLicenses) {
            LicensesView().environmentObject(settings)
        }
        .sheet(isPresented: $showFootprint) {
            FootprintView().environmentObject(env).environmentObject(settings)
        }
        .sheet(isPresented: $mailDraft) {
            MailComposer(recipient: "woooxooom@gmail.com",
                         subject: NSLocalizedString("余音 iOS 日志反馈", comment: "日志邮件主题"),
                         body: mailBody,
                         attachment: ("reverb-log.txt", mailLogData)) {
                mailDraft = false
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importerKind == .backup
                        ? [.json]
                        : [UTType(filenameExtension: "opml") ?? .xml, .xml],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            handleImport(url)
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: exportType,
                      defaultFilename: exportName) { result in
            if case .failure(let error) = result {
                Log.e("Settings", "导出失败 \(exportName)", error: error)
                alertText = "保存失败"
            }
            exportDocument = nil
        }
    }

    // MARK: - 存储

    private var usageText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(env.downloadManager.usageBytes()))
    }

    private var cacheSizeText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: max(0, cacheBytes))
    }

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

    // MARK: - 备份 / 文件

    private enum SectionSheetKind: String, Identifiable {
        case export, restore
        var id: String { rawValue }
    }

    private enum ImportKind { case backup, opml }

    private struct RestorePayload {
        var json: String
        var sections: Set<BackupManager.Section>
    }

    private func prepareExport(text: String, type: UTType, name: String) {
        exportDocument = TextFileDocument(text: text)
        exportType = type
        exportName = name
        // 等勾选弹窗收完再开文件面板:iOS 同一时刻只呈现一个模态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showExporter = true
        }
    }

    private func handleImport(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .utf16))
        guard let text else {
            alertText = "无法读取文件"
            return
        }
        switch importerKind {
        case .opml:
            BackupManager.importOPML(env, text)
        case .backup:
            let sections = BackupManager.sectionsIn(text)
            guard !sections.isEmpty else {
                Log.e("Backup", "恢复探测失败:文件无法识别为余音备份")
                restoreUnreadable = true
                return
            }
            restorePayload = RestorePayload(json: text, sections: sections)
            sectionSheet = .restore
        }
    }

    // MARK: - 提醒

    /// 打开时先要通知权限:没有权限就把开关拨回去并说明,而不是留一个永远不会有动静的开关。
    /// 与 Android `POST_NOTIFICATIONS` 那条分支同一意图。
    private func turnUpdates(_ on: Bool) {
        guard on else {
            settings.updatesEnabled = false
            env.updates.cancelScheduled()
            return
        }
        Task {
            let granted = await env.updates.requestAuthorization()
            guard granted else {
                settings.updatesEnabled = false
                alertText = "通知权限未开启，请在系统设置里允许余音发送通知"
                return
            }
            settings.updatesEnabled = true
            env.updates.scheduleNext()
        }
    }

    // MARK: - 日志

    /// 日志邮件:正文留「请描述你遇到的问题」模板,附件是 reverb-log.txt。
    /// 设备没配邮件账户时退回 `mailto:` 并明说附件怎么给 —— 起草器打不开时
    /// 悄悄什么都不发生,是最糟的一种反馈。
    private func composeLogMail() {
        let ver = AppInfo.version
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        mailBody = String(format: NSLocalizedString("请描述你遇到的问题:\n\n\n——\n余音 iOS v%@ · %@",
                                                    comment: "日志邮件正文"), ver, os)
        mailLogData = Data(Log.allText().utf8)
        guard MFMailComposeViewController.canSendMail() else {
            var comps = URLComponents()
            comps.scheme = "mailto"
            comps.path = "woooxooom@gmail.com"
            comps.queryItems = [URLQueryItem(name: "subject",
                                             value: NSLocalizedString("余音 iOS 日志反馈", comment: "日志邮件主题"))]
            if let url = comps.url { UIApplication.shared.open(url) }
            alertText = "这台设备没有配置邮件账户。日志已准备好，也可以先用上面的「分享日志」把文件发给我"
            Log.i("Settings", "邮件起草器不可用,退回 mailto bytes=\(mailLogData.count)")
            return
        }
        mailDraft = true
    }

    private func refreshLogSize() {
        let f = ByteCountFormatter()
        f.countStyle = .file
        logSizeText = f.string(fromByteCount: Int64(Log.totalSizeBytes()))
    }

    private func prepareShareLog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reverb-log.txt")
        let text = Log.allText()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareLogURL = url
        } catch {
            Log.e("Settings", "日志临时文件写入失败", error: error)
            shareLogURL = nil
        }
    }

    private func exportLog() {
        prepareExport(text: Log.allText(), type: .plainText, name: "reverb-log.txt")
    }
}

/// 备份勾选弹窗。与 Android / 鸿蒙的 `BackupSectionDialog` 同口径:初值全勾,
/// 导出与恢复的可用分区由调用方给。
private struct BackupSectionSheet: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let available: [BackupManager.Section]
    @State private var selection: Set<BackupManager.Section>
    let confirmTitle: LocalizedStringKey
    var onDone: (Set<BackupManager.Section>) -> Void
    var onCancel: () -> Void

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey,
         available: [BackupManager.Section], initial: Set<BackupManager.Section>,
         confirmTitle: LocalizedStringKey,
         onDone: @escaping (Set<BackupManager.Section>) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.available = available
        self.confirmTitle = confirmTitle
        self.onDone = onDone
        self.onCancel = onCancel
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(available) { section in
                        Toggle(LocalizedStringKey(section.label), isOn: Binding(
                            get: { selection.contains(section) },
                            set: { on in
                                if on { selection.insert(section) } else { selection.remove(section) }
                            }))
                    }
                } header: {
                    Text(subtitle)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onDone(selection) }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 导出用的纯文本文件包装。备份是 JSON、OPML 是 XML、日志是纯文本,一份文档类型即可。
struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .xml, .plainText] }
    /// OPML 不在系统静态类型表里,`fileExporter` 要写它就必须在可写类型里声明一次,
    /// 否则导出会在保存那一刻失败(JSON/日志不会,因为它们在 readable 里)。
    static var writableContentTypes: [UTType] {
        [.json, .xml, .plainText, UTType(filenameExtension: "opml") ?? .xml]
    }

    var text: String
    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}