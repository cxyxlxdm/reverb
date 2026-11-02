import SwiftUI

/// 待播队列。与 Android / 鸿蒙 / macOS 同一份 `player.userQueue`:它优先于上下文队列。
struct QueueView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    private var accent: Color { Theme.accent(settings.accentIndex) }

    var body: some View {
        NavigationStack {
            Group {
                if player.userQueue.isEmpty {
                    StateView(symbol: "text.line.first.and.arrowtriangle.forward", text: "待播队列是空的")
                } else {
                    List {
                        ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { idx, ep in
                            Button {
                                player.playFromQueue(id: ep.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Text("\(idx + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22)
                                    Artwork(url: ep.artworkUrl, size: 38, corner: 7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ep.title).font(.callout).lineLimit(1)
                                        Text(ep.podcastTitle).font(.caption)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    player.removeFromQueue(ep.id)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                        }
                        .onMove { from, to in
                            guard let f = from.first else { return }
                            player.moveInQueue(from: f, to: to)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("待播")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                if !player.userQueue.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(Text("清空"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .confirmationDialog("清空播放队列?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { player.clearQueue() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清空待播队列中的全部单集，无法恢复。")
            }
        }
        .tint(accent)
    }
}