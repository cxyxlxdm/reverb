import SwiftUI

/// 底部迷你播放条:细进度线 + 封面 + 标题/节目 + 播放暂停 / 下一集。
/// 点信息区打开全屏播放页;直播流不画进度线(线性源没有"进度"这回事)。
struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    var onOpen: () -> Void

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
                    Button(action: onOpen) {
                        HStack(spacing: 11) {
                            Artwork(url: ep.artworkUrl, size: 42, corner: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ep.title).font(.callout).fontWeight(.medium).lineLimit(1)
                                Text(ep.podcastTitle).font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

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
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}