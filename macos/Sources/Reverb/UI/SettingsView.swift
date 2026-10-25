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
    @State private var logSizeText = ""
    @State private var shareLogURL: URL?
    @State private var prompt: Prompt = .none

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
                Button { showExportPicker = true } label: {
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
                // 四行顺序与 Android `SettingsScreen.kt` / 鸿蒙 `SettingsPage.ets` 一致
                // (分享 → 邮件 → 导出 → 清空,D6)。这不是审美问题:三端同一节设置,
                // 用户按位置记按钮,顺序不同就会点错一次。
                if let url = shareLogURL {
                    ShareLink(item: url) {
                        Label("分享日志", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                Button { mailLog() } label: {
                    Label("发送日志到开发者邮箱", systemImage: "envelope")
                }
                Button { exportLog() } label: {
                    Label("导出日志…", systemImage: "square.and.arrow.up")
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

    private var usageText: String {
        let bytes = env.downloadManager.usageBytes()
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
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
