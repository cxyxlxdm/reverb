import SwiftUI

/// 电台(桌面端):管理自己的直播地址 + 从在线目录找台 + 内置精选兜底。
///
/// 与 iOS / Android / 鸿蒙同一口径,数据层共用 `StationStore` / `RadioBrowserSource`
/// (见 `Data/`)。点一行就是「听这一路流」:合成 `id=live:<url>` 的 `Episode` 交给播放器,
/// 与发现页粘贴直播地址那条路径同 id —— 重复点不会在队列里堆两条。
///
/// 桌面的差别只在形态:没有滑动删除,改用右键菜单;提示走页面顶部的 `TopToast`
/// (桌面没有全局 Toast,见 Theme.swift 里那段注释)。
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
    @State private var editor: RadioEditorTarget?
    @State private var pendingDelete: Station?
    @State private var seed: [Station] = []

    @State private var notice: String?
    /// 自动清空提示的代次:连着操作两次时,前一条的定时器不能把后一条提前抹掉
    /// (与 `BatchBar.showToast` 同一条理由)。
    @State private var noticeToken = 0

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
        .listStyle(.inset)
        .navigationTitle(Text("电台"))
        .searchable(text: $query, prompt: Text("搜索电台名称"))
        .onSubmit(of: .search) {
            Task { await runSearch() }
        }
        .onChange(of: query) { v in
            if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searched = false
                results = []
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                AirPlayRouteButton(player: player.avPlayer)
                    .frame(width: 22, height: 22)
                    .help("投放")
                Button {
                    editor = .new
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加电台")
            }
        }
        .task { await loadPopular() }
        .onAppear { seed = env.stations.seedStations() }
        .sheet(item: $editor) { target in
            RadioEditorView(existing: target.station)
                .environmentObject(env)
                .environmentObject(settings)
                .themedSheet(settings)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除电台", role: .destructive) {
                if let s = pendingDelete { env.stations.remove(id: s.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .overlay(alignment: .top) { TopToast(text: notice) }
    }

    @ViewBuilder private var mySection: some View {
        Section {
            if env.stations.stations.isEmpty {
                Text("还没有自己的电台。点右上角「+」手动添加，或从下面挑一个")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(env.stations.stations) { s in
                    row(s, mine: true)
                        .contextMenu {
                            Button("编辑") { editor = .edit(s) }
                            Button("删除", role: .destructive) { pendingDelete = s }
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

    /// 一行电台。点左侧内容才播 —— 右侧的「+」不能被行点击吞掉(与 iOS 同一条形状)。
    private func row(_ s: Station, mine: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(url: s.logo, size: 40, corner: 8)
                    if mine && player.current?.id == "live:\(s.url)" {
                        Circle().fill(accent).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).lineLimit(1)
                    Text(subtitle(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { play(s) }
            .help("播放这一路直播")

            if mine {
                Button { play(s) } label: {
                    Image(systemName: "play.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("播放")
            } else {
                Button { addCopy(s) } label: {
                    Image(systemName: env.stations.containsUrl(s.url) ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(env.stations.containsUrl(s.url) ? Color.secondary : accent)
                }
                .buttonStyle(.borderless)
                .disabled(env.stations.containsUrl(s.url))
                .help(env.stations.containsUrl(s.url) ? "已在列表里" : "添加电台")
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
        showNotice(env.stations.add(s)
            ? NSLocalizedString("已加入我的电台", comment: "添加电台结果")
            : NSLocalizedString("已在列表里", comment: "添加电台结果"))
    }

    private func showNotice(_ text: String) {
        noticeToken += 1
        let token = noticeToken
        notice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if noticeToken == token { notice = nil }
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
        // 用户可能在等待期间又改了词:只认最后一次(与 iOS / 鸿蒙那代 generation 守卫同一条)。
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

/// 编辑器弹层的目标:新建 or 改某一条。iOS 那份在 `ios/Reverb/UI/RadioView.swift`,
/// 两端各自声明(不在共享层):它只是界面状态,没有格式含义。
enum RadioEditorTarget: Identifiable {
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

/// 添加 / 编辑电台。校验与探测都在这一个弹层里完成(与 iOS 同一组判据):
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
        VStack(spacing: 0) {
            Text(existing == nil ? "添加电台" : "编辑电台")
                .font(.headline)
                .padding(.top, 16)
            Form {
                TextField("名称", text: $name, prompt: Text("留空则自动取名"))
                TextField("流地址", text: $url)
                    .autocorrectionDisabled()
                TextField("台标地址（可选）", text: $logo)
                    .autocorrectionDisabled()
                Picker("分组", selection: $group) {
                    ForEach(groups, id: \.key) { g in
                        Text(LocalizedStringKey(g.label)).tag(g.key)
                    }
                }
                if checking {
                    Text("正在检查这个地址…").font(.callout).foregroundStyle(.secondary)
                } else if !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear {
            if let e = existing {
                name = e.name
                url = e.url
                logo = e.logo
                group = e.group
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
        } else {
            _ = env.stations.update(station)
        }
        dismiss()
    }
}
