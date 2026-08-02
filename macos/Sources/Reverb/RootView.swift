import SwiftUI

/// 骨架:侧栏(发现/音阁/设置)+ 内容区。后续逐步填充功能。
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

    @State private var tab: Tab = .discover

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .listStyle(.sidebar)
        } detail: {
            switch tab {
            case .discover: PlaceholderView(title: "发现", subtitle: "余音绕梁，隽永悠长")
            case .library: PlaceholderView(title: "音阁", subtitle: "订阅 · 收藏 · 下载 · 历史")
            case .settings: PlaceholderView(title: "设置", subtitle: "主题 · 播放 · 备份")
            }
        }
        .navigationTitle("余音")
    }
}

private struct PlaceholderView: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 34, weight: .semibold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
