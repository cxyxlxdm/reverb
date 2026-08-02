import SwiftUI

/// 根视图:侧栏(发现/音阁/设置)+ 内容区,底部常驻播放条。
struct RootView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case discover = "发现"
        case library = "音阁"
        case settings = "设置"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .discover: return "safari"
            case .library: return "books.vertical"
            case .settings: return "gearshape"
            }
        }
    }

    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @State private var tab: Tab = .discover

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .discover: DiscoverView()
                    case .library: LibraryView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if player.current != nil {
                    Divider()
                    NowPlayingBar()
                }
            }
        }
        .navigationTitle("余音")
        .tint(Theme.accent(env.settings.accentIndex))
    }
}
