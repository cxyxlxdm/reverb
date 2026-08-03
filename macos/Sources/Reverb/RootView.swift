import SwiftUI

/// 根视图:顶部工具栏内的 发现/音阁 分段切换 + 齿轮设置,内容区填满窗口,
/// 底部常驻播放条(仅当有正在播放的内容)。使用 NavigationStack 让详情页原生推入。
struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case discover = "发现"
        case library = "音阁"
        var id: String { rawValue }
    }

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @State private var section: Section = .discover

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                Group {
                    switch section {
                    case .discover: DiscoverView()
                    case .library: LibraryView()
                    }
                }
                .navigationDestination(for: Podcast.self) { PodcastDetailView(podcast: $0) }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $section) {
                            ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        SettingsButton()
                    }
                }
            }

            if player.current != nil {
                Divider()
                NowPlayingBar()
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 全屏(尤其刘海屏)时用窗口底色铺满安全区,避免顶部菜单栏那条露出黑色背衬
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
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
