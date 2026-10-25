import SwiftUI

/// 播放队列(up next)的表体:点击单集直接跳播(摘出立即播)、可拖动重排、滑动删除。
///
/// **两处共用这一份 body**:队列 sheet(`QueueView`)与音阁的「待播」段(`LibraryView`)。
/// 与 Android `QueueScreen` + `LibraryScreen` 待播段共用同一个 body 同口径 ——
/// 一份清单不写两遍,改一处两处都对。
struct QueueList: View {
    /// 点封面直达频道页。队列 sheet 自带一个 `NavigationStack`,但里面没有注册 `Podcast`
    /// 的 destination,而且缺 `listenStats` / 下载两套环境对象 —— 只能把目的地交回根视图;
    /// 音阁「待播」段就在根栈里,传 nil 即走 `NavigationLink(value:)`。
    var onOpenChannel: ((Podcast) -> Void)? = nil

    @EnvironmentObject var player: PlayerController

    var body: some View {
        Group {
            if player.userQueue.isEmpty {
                StateView(symbol: "list.bullet", text: "播放队列为空")
            } else {
                List {
                    ForEach(player.userQueue) { ep in
                        HStack(spacing: 12) {
                            artwork(ep)
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
    }

    @ViewBuilder
    private func artwork(_ ep: Episode) -> some View {
        if let channel = ep.channelRef {
            if let onOpenChannel {
                Button { onOpenChannel(channel) } label: {
                    Artwork(url: ep.artworkUrl, size: 44, corner: 8)
                }
                .buttonStyle(.plain)
                .help("进入频道页")
                .accessibilityLabel(Text("进入频道页"))
                .pointingHandCursor()
            } else {
                // 音阁「待播」段走这条:根 `RootView` 已注册 `Podcast.self` 的 destination。
                NavigationLink(value: channel) {
                    Artwork(url: ep.artworkUrl, size: 44, corner: 8)
                }
                .buttonStyle(.plain)
                .help("进入频道页")
                .accessibilityLabel(Text("进入频道页"))
                .pointingHandCursor()
            }
        } else {
            Artwork(url: ep.artworkUrl, size: 44, corner: 8)
        }
    }
}

/// 播放队列 sheet:从底部播放条那颗按钮打开。标题与两端同一个词 ——「待播」。
struct QueueView: View {
    var onOpenChannel: (Podcast) -> Void = { _ in }

    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    /// 清空要二次确认。与 Android `QueueScreen.kt` / 音阁「待播」段那颗同一个走法:
    /// 一键清光没有找回办法,而桌面这一颗原先直连 `clearQueue()`(见 docs/MACOS-GAPS.md M1)。
    @State private var confirmClear = false

    private var accent: Color { Theme.accent(settings.accentIndex) }

    var body: some View {
        NavigationStack {
            QueueList(onOpenChannel: onOpenChannel)
                .navigationTitle("待播")
                .frame(minWidth: 440, minHeight: 480)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                    if !player.userQueue.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button(role: .destructive) { confirmClear = true } label: {
                                Label("清空", systemImage: "trash")
                            }
                            .help("清空待播")
                        }
                    }
                }
        }
        .confirmationDialog("清空播放队列?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { player.clearQueue() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空待播队列中的全部单集，无法恢复。")
        }
        .tint(accent)
    }
}
