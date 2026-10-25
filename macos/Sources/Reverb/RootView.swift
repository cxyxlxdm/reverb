import SwiftUI

/// 根视图:顶部工具栏内的 发现/追更/音阁 分段切换 + 齿轮设置,内容区填满窗口,
/// 底部常驻播放条(仅当有正在播放的内容)。使用 NavigationStack 让详情页原生推入。
struct RootView: View {
    /// 三格的顺序与两端一致(发现 / 追更 / 音阁):换端时手指/眼睛不用重新找。
    /// 「追更」是 2026-10-25 从音阁分段提上来的第三格(见 docs/MACOS-GAPS.md M6)。
    enum Section: String, CaseIterable, Identifiable {
        case discover = "发现"
        case inbox = "追更"
        case library = "音阁"
        var id: String { rawValue }
    }

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @State private var section: Section = .discover
    @State private var path = NavigationPath()

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $path) {
                Group {
                    switch section {
                    case .discover: DiscoverView()
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
                        // 三格是定宽:最长的一组是法语(Découvrir / Nouveautés / Bibliothèque)。
                        // 加第三格之后会不会截断标签,只有把界面跑起来才看得见 —— 别凭猜再调这个数。
                        .frame(width: 300)
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
                Divider()
                NowPlayingBar(onOpenChannel: { path.append($0) })
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 全屏(尤其刘海屏)时用窗口底色铺满安全区,避免顶部菜单栏那条露出黑色背衬
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
        .noFocusRing() // 整树去键盘焦点环
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
