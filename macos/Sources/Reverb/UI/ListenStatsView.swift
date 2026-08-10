import SwiftUI

/// 收听时长:按频道累计的收听时长,从多到少排序,用横条可视化(越长横条越长)。以 sheet 呈现。
struct ListenStatsView: View {
    @EnvironmentObject var listenStats: ListenStatsStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { Theme.accent(settings.accentIndex) }

    /// 已按时长降序;最大值用于归一化横条宽度。
    private var rows: [ChannelListen] { listenStats.stats.filter { $0.listenedMs > 0 } }
    private var maxMs: Int { max(1, rows.first?.listenedMs ?? 1) }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    StateView(symbol: "chart.bar", text: String(localized: "还没有收听记录"))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(rows) { row($0) }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("收听时长")
            .frame(minWidth: 560, minHeight: 520)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(accent)
    }

    private func row(_ c: ChannelListen) -> some View {
        let fraction = Double(c.listenedMs) / Double(maxMs)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Artwork(url: c.artworkUrl, size: 40, corner: 8)
                Text(c.title.isEmpty ? String(localized: "未知频道") : c.title)
                    .font(.headline).fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.duration(c.listenedMs / 1000))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // 横条:底槽 + 按比例填充的强调色;最长者满宽
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
