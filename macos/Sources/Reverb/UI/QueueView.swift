import SwiftUI

/// 播放队列(up next)表单:点击单集直接跳播(摘出立即播)、可拖动重排、滑动删除、一键清空。
struct QueueView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { Theme.accent(settings.accentIndex) }

    var body: some View {
        NavigationStack {
            Group {
                if player.userQueue.isEmpty {
                    StateView(symbol: "list.bullet", text: "播放队列为空")
                } else {
                    List {
                        ForEach(player.userQueue) { ep in
                            HStack(spacing: 12) {
                                Artwork(url: ep.artworkUrl, size: 44, corner: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ep.title)
                                        .font(.callout).fontWeight(.medium)
                                        .lineLimit(2)
                                    if !ep.podcastTitle.isEmpty {
                                        Text(ep.podcastTitle)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { player.playFromQueue(id: ep.id) }
                        }
                        .onMove { from, to in
                            if let f = from.first { player.moveInQueue(from: f, to: to) }
                        }
                        .onDelete { idx in
                            let ids = idx.map { player.userQueue[$0].id }
                            ids.forEach { player.removeFromQueue($0) }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("播放队列")
            .frame(minWidth: 440, minHeight: 480)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if !player.userQueue.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) { player.clearQueue() } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .help("清空播放队列")
                    }
                }
            }
        }
        .tint(accent)
    }
}
