import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 设置(标准 macOS 设置窗口):外观 / 内容 / 播放 / 备份 / 足迹。
struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    var body: some View {
        SettingsForm(env: env, settings: env.settings, player: env.player)
    }
}

private struct SettingsForm: View {
    let env: AppEnvironment
    @ObservedObject var settings: SettingsStore
    @ObservedObject var player: PlayerController
    @ObservedObject var downloadStore: DownloadStore

    init(env: AppEnvironment, settings: SettingsStore, player: PlayerController) {
        self.env = env
        self.settings = settings
        self.player = player
        self.downloadStore = env.downloads
    }

    private let themeNames = ["跟随系统", "浅色", "深色", "纯白"]
    private let regions: [(code: String, name: String)] = [
        ("", "自动"), ("cn", "中国大陆"), ("hk", "中国香港"), ("tw", "中国台湾"),
        ("us", "美国"), ("jp", "日本"), ("kr", "韩国"), ("gb", "英国")
    ]
    private let skipBackOptions = [5, 10, 15, 30]
    private let skipForwardOptions = [15, 30, 45, 60]

    @State private var showFootprint = false
    @State private var showRestore = false
    @State private var restoreJSON = ""
    @State private var restoreSections: Set<BackupManager.Section> = []
    @State private var restoreSelection: Set<BackupManager.Section> = []
    @State private var confirmClearDownloads = false
    @State private var confirmClearLog = false
    @State private var logSizeText = ""
    @State private var shareLogURL: URL?

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.themeMode) {
                    ForEach(0..<themeNames.count, id: \.self) { Text(LocalizedStringKey(themeNames[$0])).tag($0) }
                }
                Picker("配色", selection: $settings.accentIndex) {
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
                Picker("默认倍速", selection: Binding(
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
                Toggle("语音转文字", isOn: $settings.transcriptionEnabled)
                Text("在播放页新增「转录」页,完全离线转录当前单集(需 macOS 26,首次按语言下载模型)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("足迹") {
                Button {
                    showFootprint = true
                } label: {
                    HStack {
                        Label("听觉足迹", systemImage: "seal")
                        Spacer()
                        Text("\(env.stamps.stamps.count) 枚").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
            }

            Section("备份") {
                Button { exportBackup() } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                Button { restoreBackup() } label: {
                    Label("恢复备份", systemImage: "square.and.arrow.down")
                }
                Button { exportOPML() } label: {
                    Label("导出 OPML", systemImage: "list.bullet.rectangle")
                }
                Button { importOPML() } label: {
                    Label("导入 OPML", systemImage: "tray.and.arrow.down")
                }
            }

            Section("存储") {
                HStack {
                    Label("离线下载", systemImage: "internaldrive")
                    Spacer()
                    Text("\(downloadStore.downloads.count) 集 · \(usageText)")
                        .foregroundStyle(.secondary)
                }
                if !downloadStore.downloads.isEmpty {
                    Button(role: .destructive) { confirmClearDownloads = true } label: {
                        Label("清空下载", systemImage: "trash")
                    }
                }
            }

            Section("日志") {
                HStack {
                    Label("日志", systemImage: "doc.text")
                    Spacer()
                    Text(logSizeText).foregroundStyle(.secondary)
                }
                Button { exportLog() } label: {
                    Label("导出日志…", systemImage: "square.and.arrow.up")
                }
                if let url = shareLogURL {
                    ShareLink(item: url) {
                        Label("分享日志", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                Button { mailLog() } label: {
                    Label("发送日志到开发者邮箱", systemImage: "envelope")
                }
                Button(role: .destructive) { confirmClearLog = true } label: {
                    Label("清空日志", systemImage: "trash")
                }
            }
        }
        .onAppear { refreshLogSize(); prepareShareLog() }
        .confirmationDialog("确定清空日志?", isPresented: $confirmClearLog, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                Log.clear()
                refreshLogSize()
                prepareShareLog()
            }
            Button("取消", role: .cancel) {}
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
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
        }
        .sheet(isPresented: $showRestore) {
            RestoreSheet(
                sections: restoreSections,
                selection: $restoreSelection,
                onApply: {
                    BackupManager.apply(env, restoreJSON, restoreSelection)
                    showRestore = false
                },
                onCancel: { showRestore = false })
            .tint(Theme.accent(settings.accentIndex))
        }
    }

    private var usageText: String {
        let bytes = env.downloadManager.usageBytes()
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    // MARK: - 文件操作

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reverb-backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let json = BackupManager.build(env, Set(BackupManager.Section.allCases))
        Task.detached { try? json.data(using: .utf8)?.write(to: url) }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let json = await readString(url) else { return }
            let sections = BackupManager.sectionsIn(json)
            guard !sections.isEmpty else { return }
            restoreJSON = json
            restoreSections = sections
            restoreSelection = sections
            showRestore = true
        }
    }

    private func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reverb.opml"
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let xml = BackupManager.exportOPML(env)
        Task.detached { try? xml.data(using: .utf8)?.write(to: url) }
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
    private func prepareShareLog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reverb-log.txt")
        Task {
            let text = await Task.detached { Log.allText() }.value
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
            shareLogURL = url
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reverb-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let text = await Task.detached { Log.allText() }.value
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    /// 用系统邮件把日志作为附件发到开发者邮箱;无邮件客户端时回退到 mailto + 在访达中定位日志文件。
    private func mailLog() {
        let devEmail = "woooxooom@gmail.com"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reverb-log.txt")
        Task {
            let text = await Task.detached { Log.allText() }.value
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
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

/// 恢复备份:勾选要合并的分区后应用。
private struct RestoreSheet: View {
    let sections: Set<BackupManager.Section>
    @Binding var selection: Set<BackupManager.Section>
    var onApply: () -> Void
    var onCancel: () -> Void

    private var available: [BackupManager.Section] {
        BackupManager.Section.allCases.filter { sections.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("恢复备份").font(.headline).padding(20)
            Divider()
            Form {
                Section("选择要合并的内容") {
                    ForEach(available) { section in
                        Toggle(LocalizedStringKey(section.label), isOn: Binding(
                            get: { selection.contains(section) },
                            set: { on in
                                if on { selection.insert(section) } else { selection.remove(section) }
                            }))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("恢复", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 400, height: 460)
    }
}
