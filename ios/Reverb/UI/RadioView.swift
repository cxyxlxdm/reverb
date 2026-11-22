import SwiftUI

/// 电台:管理自己的直播地址 + 从在线目录找台 + 内置精选兜底。
///
/// 与 Android / 鸿蒙的电台页同一口径,数据层共用 `StationStore` / `RadioBrowserSource`
/// (见 macos/Sources/Reverb/Data)。点一行就是「听这一路流」:合成 `id=live:<url>` 的
/// `Episode` 交给播放器,与发现页粘贴直播地址那条路径同 id —— 重复点不会在队列里堆两条。
struct RadioView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore

    @State private var query = ""
    @State private var searching = false
    @State private var searched = false
    @State private var results: [Station] = []
    @State private var popular: [Station] = []
    @State private var popularLoading = false
    @State private var popularError = false
    @State private var editor: EditorTarget?
    @State private var pendingDelete: Station?
    @State private var seed: [Station] = []

    private var accent: Color { Theme.accent(settings.accentIndex) }

    var body: some View {
        List {
            mySection
            if searched || searching {
                searchSection
            } else {
                hotSection
                seedSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("电台"))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("搜索电台名称"))
        .onSubmit(of: .search) {
            Task { await runSearch() }
        }
        .onChange(of: query) { _, v in
            if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searched = false
                results = []
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                AirPlayRouteButton(tint: UIColor(accent))
                    .frame(width: 40, height: 30)
                    .accessibilityLabel(Text("投放"))
                Button {
                    editor = .new
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("添加电台"))
            }
        }
        .task { await loadPopular() }
        .onAppear { seed = env.stations.seedStations() }
        .sheet(item: $editor) { target in
            RadioEditorView(existing: target.station)
                .environmentObject(env)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除电台", role: .destructive) {
                if let s = pendingDelete { env.stations.remove(id: s.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    /// 只让「我的电台」那段有内容;没有时给一句引导(与 Android 空态同一句)。
    @ViewBuilder private var mySection: some View {
        Section {
            if env.stations.stations.isEmpty {
                Text("还没有自己的电台。点右上角「+」手动添加，或从下面挑一个")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(env.stations.stations) { s in
                    row(s, mine: true)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = s } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button { editor = .edit(s) } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                        }
                }
            }
        } header: {
            Text("我的电台")
        }
    }

    @ViewBuilder private var searchSection: some View {
        Section {
            if searching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在搜索…").foregroundStyle(.secondary)
                }
            } else if results.isEmpty {
                Text("没找到这个电台，换个名字试试").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(results) { s in row(s, mine: false) }
            }
        } header: {
            Text("搜索结果")
        }
    }

    @ViewBuilder private var hotSection: some View {
        Section {
            if popularLoading && popular.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取…").foregroundStyle(.secondary)
                }
            } else if popularError && popular.isEmpty {
                HStack {
                    Text("在线目录暂时连不上").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await loadPopular() } }
                        .buttonStyle(.borderless)
                }
            } else if popular.isEmpty {
                Text("暂时没有可以推荐的电台").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(popular) { s in row(s, mine: false) }
            }
        } header: {
            Text("热门电台")
        }
    }

    @ViewBuilder private var seedSection: some View {
        if !seed.isEmpty {
            Section {
                ForEach(seed) { s in row(s, mine: false) }
            } header: {
                Text("精选电台")
            }
        }
    }

    /// 一行电台。点封面/文字才播 —— 右侧的「+」与滑动按钮不能被行点击吞掉。
    private func row(_ s: Station, mine: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(url: s.logo, size: 48, corner: 10)
                    if mine && player.current?.id == "live:\(s.url)" {
                        Circle().fill(accent).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).font(.body).lineLimit(1)
                    Text(subtitle(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { play(s) }

            if mine {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.tertiary)
            } else {
                Button { addCopy(s) } label: {
                    Image(systemName: env.stations.containsUrl(s.url) ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(env.stations.containsUrl(s.url) ? .secondary : accent)
                }
                .buttonStyle(.borderless)
                .disabled(env.stations.containsUrl(s.url))
                .accessibilityLabel(Text(env.stations.containsUrl(s.url) ? "已在列表里" : "添加电台"))
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ s: Station) -> String {
        var parts: [String] = []
        switch s.group {
        case "news": parts.append(NSLocalizedString("新闻", comment: "电台分组"))
        case "music": parts.append(NSLocalizedString("音乐", comment: "电台分组"))
        case "talk": parts.append(NSLocalizedString("谈话", comment: "电台分组"))
        case "retro": parts.append(NSLocalizedString("怀旧", comment: "电台分组"))
        default: break
        }
        switch s.source {
        case Station.sourceDirectory: parts.append(NSLocalizedString("目录", comment: "电台来源"))
        case Station.sourceSeed: parts.append(NSLocalizedString("精选", comment: "电台来源"))
        default: parts.append(NSLocalizedString("手动", comment: "电台来源"))
        }
        if !s.country.isEmpty { parts.append(s.country) }
        return parts.joined(separator: " · ")
    }

    /// 直播合成条目。`isLive = true` 让播放器关掉历史/缓存/断点/自动续播(见 PlayerController)。
    @MainActor private func play(_ s: Station) {
        let live = Episode(
            id: "live:\(s.url)",
            title: s.name,
            description: "",
            audioUrl: s.url,
            artworkUrl: s.logo,
            podcastTitle: NSLocalizedString("直播", comment: "直播条目的频道名"),
            durationSec: 0,
            pubDate: "",
            feedUrl: "",
            isLive: true
        )
        player.playOrToggle(live, queue: [live])
    }

    @MainActor private func addCopy(_ s: Station) {
        if env.stations.add(s) {
            env.toast.show(NSLocalizedString("已加入我的电台", comment: "添加电台结果"))
        } else {
            env.toast.show(NSLocalizedString("已在列表里", comment: "添加电台结果"))
        }
    }

    @MainActor private func loadPopular() async {
        guard popular.isEmpty, !popularLoading else { return }
        popularLoading = true
        popularError = false
        let list = await RadioBrowserSource.popular()
        popular = list
        popularError = list.isEmpty
        popularLoading = false
    }

    @MainActor private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        searched = true
        let list = await RadioBrowserSource.search(q)
        // 用户可能在等待期间又改了词:只认最后一次(与鸿蒙那代 generation 守卫同一条)。
        if query.trimmingCharacters(in: .whitespacesAndNewlines) == q {
            results = list
            searching = false
        }
    }

    private var deleteTitle: String {
        guard let s = pendingDelete else { return "" }
        return String(format: NSLocalizedString("确定删除「%@」吗？", comment: "删除电台确认"), s.name)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// 编辑器弹层的目标:新建 or 改某一条。`id` 用 station 的 id(新建用固定串)。
enum EditorTarget: Identifiable {
    case new
    case edit(Station)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let s): return "edit:\(s.id)"
        }
    }

    var station: Station? {
        switch self {
        case .new: return nil
        case .edit(let s): return s
        }
    }
}

/// 添加 / 编辑电台。校验与探测都在这一个弹层里完成:
/// - 地址必须以 http(s) 开头;
/// - 与列表里**别的**条目地址重复则拒绝(同一路流只该有一条);
/// - 新地址先探测响应头(`LiveStream.resolve`),已有条目没改地址就不重复探;
/// - 名称留空:用探测到的台名,再退到主机名。
struct RadioEditorView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let existing: Station?

    @State private var name = ""
    @State private var url = ""
    @State private var logo = ""
    @State private var group = ""
    @State private var error = ""
    @State private var checking = false

    private let groups: [(key: String, label: String)] = [
        ("", "未分组"),
        ("news", "新闻"),
        ("music", "音乐"),
        ("talk", "谈话"),
        ("retro", "怀旧")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("留空则自动取名"))
                    TextField("流地址", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("台标地址（可选）", text: $logo)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("分组", selection: $group) {
                        ForEach(groups, id: \.key) { g in
                            Text(LocalizedStringKey(g.label)).tag(g.key)
                        }
                    }
                } footer: {
                    if checking {
                        Text("正在检查这个地址…")
                    } else if !error.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Text(existing == nil ? "添加电台" : "编辑电台"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(checking || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let e = existing {
                    name = e.name
                    url = e.url
                    logo = e.logo
                    group = e.group
                }
            }
        }
    }

    @MainActor private func save() async {
        let rawUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = URL(string: rawUrl)?.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            error = NSLocalizedString("地址要以 http:// 或 https:// 开头", comment: "电台地址校验")
            return
        }
        if env.stations.containsUrl(rawUrl, exceptId: existing?.id ?? "") {
            error = NSLocalizedString("这个地址已经在列表里了", comment: "电台地址重复")
            return
        }
        error = ""
        // 只有「新建」或「地址改了」才探测 —— 改个名字不该因为对方服务器刚才抖了一下就存不进去。
        let needProbe = existing == nil || existing?.url != rawUrl
        var probed: Episode?
        if needProbe {
            checking = true
            probed = await LiveStream.resolve(rawUrl)
            checking = false
            guard probed != nil else {
                error = NSLocalizedString("这个地址没有返回音频流，请检查后再试", comment: "电台探测失败")
                return
            }
        }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (probed?.title.isEmpty == false ? probed!.title : (URL(string: rawUrl)?.host ?? rawUrl))
        let station = Station(
            id: existing?.id ?? "local:\(UUID().uuidString)",
            name: typed.isEmpty ? fallback : typed,
            url: rawUrl,
            logo: logo.trimmingCharacters(in: .whitespacesAndNewlines),
            group: Station.normalizeGroup(group),
            country: existing?.country ?? "",
            source: existing?.source ?? Station.sourceManual
        )
        if existing == nil {
            _ = env.stations.add(station)
            env.toast.show(NSLocalizedString("已加入我的电台", comment: "添加电台结果"))
        } else {
            _ = env.stations.update(station)
        }
        dismiss()
    }
}
