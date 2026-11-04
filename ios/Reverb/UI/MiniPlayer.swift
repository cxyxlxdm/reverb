import SwiftUI

/// 底部迷你播放条:细进度线 + 封面 + 标题/节目 + 播放暂停 / 下一集。
/// 点信息区打开全屏播放页;直播流不画进度线(线性源没有"进度"这回事)。
struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    var onOpen: () -> Void
    @State private var showQueue = false

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private var isLive: Bool { player.current?.isLive == true && player.durationMs <= 0 }

    private var progress: Double {
        guard player.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(player.positionMs) / Double(player.durationMs)))
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLive {
                HStack(spacing: 4) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text("直播中").font(.caption2).foregroundStyle(accent)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        Rectangle().fill(accent)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
            }

            HStack(spacing: 12) {
                if let ep = player.current {
                    HStack(spacing: 11) {
                        // 封面的第二重语义与列表行同一条(Android `MiniPlayer` 的
                        // `coverChannelJump`):点头像进频道页,点其余部分展开播放页。
                        // 两者是**兄弟**而不是嵌套 —— 把 NavigationLink 塞进 Button 的 label 里,
                        // 命中会被外层 Button 吃掉,头像点了只会展开播放页。
                        if let channel = ep.channelRef {
                            NavigationLink(value: channel) {
                                Artwork(url: ep.artworkUrl, size: 42, corner: 8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("进入频道页"))
                        } else {
                            Artwork(url: ep.artworkUrl, size: 42, corner: 8)
                        }
                        Button(action: onOpen) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ep.title).font(.callout).fontWeight(.medium).lineLimit(1)
                                Text(ep.podcastTitle).font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        if player.playbackError != nil { player.retry() } else { player.togglePlayPause() }
                    } label: {
                        Image(systemName: player.playbackError != nil ? "arrow.clockwise" : (player.isPlaying ? "pause.fill" : "play.fill"))
                            .font(.system(size: 20))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(player.playbackError != nil ? .orange : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? Text("暂停") : Text("播放"))

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 15))
                            .frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasNext || ep.isLive)
                    .opacity(ep.isLive ? 0.3 : 1)

                    // 队列入口与关闭:位次与 Android 底条一致 —— 队列在前、X 在最右。
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16))
                            .frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("待播"))

                    Button { player.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("关闭播放器"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(player)
                .environmentObject(settings)
        }
    }
}