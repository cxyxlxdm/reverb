import SwiftUI

/// 收听时长:按频道汇总本机各设备的累计收听毫秒,降序排列。
struct ListenStatsView: View {
    @EnvironmentObject var listenStats: ListenStatsStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var rows: [ChannelListen] {
        listenStats.stats.filter { $0.listenedMs > 0 }.sorted { $0.listenedMs > $1.listenedMs }
    }
    /// 已按时长降序,最大值用于归一化横条宽度。
    private var maxMs: Int { max(1, rows.first?.listenedMs ?? 1) }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    StateView(symbol: "headphones", text: "还没有收听记录")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(rows) { row($0) }
                        }
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationTitle("收听时长")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(accent)
    }

    /// 横条口径与 Android `ListenStatsScreen` / 鸿蒙 `ListenStatsPage` / macOS 同一份:
    /// 底槽 + 按「相对最长者」的比例填充,最长者满宽(不是占总时长的比例)。
    private func row(_ c: ChannelListen) -> some View {
        let fraction = min(1, max(0.02, Double(c.listenedMs) / Double(maxMs)))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Artwork(url: c.artworkUrl, size: 40, corner: 8)
                Text(c.title.isEmpty ? String(localized: "未知频道") : c.title)
                    .font(.callout).fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.duration(c.listenedMs / 1000))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(accent)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
        }
    }
}