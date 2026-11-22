import SwiftUI

/// 根视图:顶部工具栏内的 发现/电台/追更/音阁 分段切换 + 齿轮设置,内容区填满窗口,
/// 底部常驻播放条(仅当有正在播放的内容)。使用 NavigationStack 让详情页原生推入。
struct RootView: View {
    /// 四格的顺序与手机两端一致(发现 / 电台 / 追更 / 音阁):换端时手指/眼睛不用重新找。
    /// 「追更」是 2026-10-25 从音阁分段提上来的第三格(见 docs/MACOS-GAPS.md M6);
    /// 「电台」是 1.0.9 按商店评论加的独立入口(用户要求:能编辑、能添加、能搜在线台)。
    enum Section: String, CaseIterable, Identifiable {
        case discover = "发现"
        case radio = "电台"
        case inbox = "追更"
        case library = "音阁"
        var id: String { rawValue }
    }

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @State private var section: Section = .discover
    @State private var path = NavigationPath()
    /// 点 X 的粒子消散(三端同款,见 UI/DissolveParticles.swift):条子隐身但占位保留,
    /// 430ms 后才 close() —— 内容补位落在粒子散尽之后(参考视频的次序)。
    @State private var dissolveTick = 0
    @State private var dissolveRect = CGRect.zero
    @State private var barGhost = false
    /// 卡片深链打开播放页。**不能复用 `NowPlayingBar` 里那个 `showPlayer`**:卡片点开时
    /// 播放条才刚刚因为 `prepare` 有了 current,那条 sheet 根本没被构建过。
    @State private var showPlayerFromURL = false

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
            NavigationStack(path: $path) {
                Group {
                    switch section {
                    case .discover: DiscoverView()
                    case .radio: RadioView()
                    case .inbox: InboxView()
                    case .library: LibraryView()
                    }
                }
                .navigationDestination(for: Podcast.self) { PodcastDetailView(podcast: $0) }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $section) {
                            ForEach(Section.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        // 四格是定宽:最长的一组是法语(Découvrir / Radio / Nouveautés / Bibliothèque)。
                        // 从三格加到四格时把 300 调到 400 —— 加格之后会不会截断标签,
                        // 仍只有把界面跑起来才看得见,别凭猜再动这个数(本轮屏幕被锁,没看过)。
                        .frame(width: 400)
                        // 换分段 = 换了一个根视图,NavigationStack 里已经推上去的详情页要一起清掉
                        // (见 REVIEW-2026-10-25 族 E)。原先只换根视图、`path` 不动,
                        // 于是栈顶停在某频道主页时点「追更」/「音阁」**没有任何可见效果** ——
                        // 看着像分段按钮坏了,而 path 里那条 Podcast 栈还在,切回「发现」又冒出来。
                        // 用单参数闭包是**故意的**:双参数 `onChange(of:initial:_:)` 是 macOS 14 的 API,
                        // 本包 `platforms: [.macOS(.v13)]`,与 `LibraryView` 里那条同段切换清状态的写法保持一致。
                        .onChange(of: section) { _ in
                            path = NavigationPath()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        SettingsButton()
                    }
                }
            }

            if player.current != nil {
                // 点 X 走「粒子消散」:close() 延迟到散尽之后,这里的塌陷过渡发生在
                // 条子已经隐身时 —— 读出来只剩布局收拢,正好接在粒子之后。
                // 出现方向仍走这条 .animation(value:) 的反向弹出。
                Group {
                    Divider()
                    NowPlayingBar(
                        onOpenChannel: { path.append($0) },
                        ghost: barGhost,
                        onDissolve: { rect in
                            dissolveRect = rect
                            dissolveTick += 1
                            barGhost = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                                player.close()
                                barGhost = false
                            }
                        })
                }
                .opacity(barGhost ? 0 : 1)
                .transition(AnyTransition.modifier(
                    active: CollapseModifier(collapsed: true),
                    identity: CollapseModifier(collapsed: false)
                ))
            }
        }
        // 粒子层:铺满全窗、声明在 VStack 之后(压过一切),碎片上飞不被裁。
        DissolveParticles(tick: dissolveTick, rect: dissolveRect,
                          primary: Theme.accent(settings.accentIndex))
        }
        .frame(minWidth: 1100, minHeight: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 「这一集暂时播不了」的一次性提示(H232)。挂在外壳而不是播放页:解析失败时
        // 播放页显示的仍是**上一集**,那条提示根本不该随它出现;桌面也没有 Toast 可用。
        .overlay(alignment: .top) { TopToast(text: player.notice) }
        // 应用内更新:每次启动自动查询一次发布页(只在这一棵树里 —— 未同意隐私政策时
        // `PrivacyGate` 根本不构建它,所以这条请求天然在同意之后)。`start()` 自带
        // 「每次进程只跑一次」的闸,分段切换导致的重建不会重复请求。
        .task { env.update.start() }
        // 全屏(尤其刘海屏)时用窗口底色铺满安全区,避免顶部菜单栏那条露出黑色背衬
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
        .noFocusRing() // 整树去键盘焦点环
        // 「current 有无」翻转的统一动画源:驱动上面那条塌陷过渡(出现/消失两个方向),
        // 曲线与另两端收束 morph 的手感同档(欠阻尼小弹簧)。
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: player.current != nil)
        // 卡片点开:`reverb://player?id=<episodeId>`(scheme 在 Info.plist 的 CFBundleURLTypes 里声明)。
        // 系统投递先进 `DeepLinkInbox`(见 ReverbApp.swift 的 AppDelegate 与那里的实测注释);
        // 这里接两路:后续到达走订阅,「RootView 还没出现就投递」的那次由 onAppear 取走。
        .onReceive(DeepLinkInbox.shared.$arrival.compactMap { $0 }) { _ in
            // 走 takePending 而不是直接用发布值:不清空的话,下一次 onAppear
            // (换语言会重建这棵树)会把同一条旧深链再执行一遍。
            if let url = DeepLinkInbox.shared.takePending() { openFromWidget(url) }
        }
        .onAppear {
            if let url = DeepLinkInbox.shared.takePending() { openFromWidget(url) }
        }
        .sheet(isPresented: $showPlayerFromURL) {
            PlayerView(onOpenChannel: { pod in
                showPlayerFromURL = false
                path.append(pod)
            })
                .environmentObject(env)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(env.transcripts)
                .themedSheet(settings)
        }
    }

    /// 卡片深链:**只装载不播放** —— 冷启动时当前集可能还不是卡片那条,所以要显式 `prepare`
    /// (与 iOS / Android 的 `EXTRA_OPEN_EPISODE` 同一条理由,见 PlayerController.prepare)。
    /// 重复到达无副作用:`prepare` 自带同 id 短路,`showPlayerFromURL` 是幂等的置位。
    private func openFromWidget(_ url: URL) {
        guard url.scheme == "reverb", url.host == "player" else { return }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value ?? ""
        if !id.isEmpty, player.current?.id != id,
           let ep = env.history.history.first(where: { $0.episode.id == id })?.episode {
            player.prepare(ep)
        }
        showPlayerFromURL = true
    }
}

/// 播放条的塌陷形状:收到高度 0 + 裁剪 + 淡出。挂法见 `RootView` 那条 transition 注释。
private struct CollapseModifier: ViewModifier {
    let collapsed: Bool
    func body(content: Content) -> some View {
        if collapsed {
            content.frame(height: 0).clipped().opacity(0)
        } else {
            content
        }
    }
}

/// 齿轮设置按钮:macOS 14+ 用 SettingsLink,否则回退到打开设置窗口的 AppKit 动作。
struct SettingsButton: View {
    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
            } else {
                Button {
                    openSettingsLegacy()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .help("设置")
    }

    private func openSettingsLegacy() {
        // Ventura 起为 showSettingsWindow:,更早为 showPreferencesWindow:。
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
