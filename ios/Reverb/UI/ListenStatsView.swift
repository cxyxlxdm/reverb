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
    private var totalSeconds: Int { rows.reduce(0) { $0 + $1.listenedMs } / 1000 }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    StateView(symbol: "headphones", text: "还没有收听记录")
                } else {
                    List {
                        Section {
                            HStack {
                                Text(Fmt.duration(totalSeconds))
                                    .font(.title2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(accent)
                                Spacer()
                                Image(systemName: "headphones").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        Section {
                            ForEach(rows) { c in
                                HStack(spacing: 12) {
                                    Artwork(url: c.artworkUrl, size: 40, corner: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.title.isEmpty ? String(localized: "未知频道") : c.title)
                                            .font(.callout)
                                            .lineLimit(1)
                                        if !c.feedUrl.isEmpty {
                                            Text(c.feedUrl)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(Fmt.duration(c.listenedMs / 1000))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
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
}