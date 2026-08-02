import SwiftUI

/// 底部常驻播放条:细进度线 + 封面 + 标题/节目 + 上一集/播放暂停/下一集;
/// 点击信息区打开全屏播放页。纤细、优雅。
struct NowPlayingBar: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @State private var showPlayer = false

    private var accent: Color { Theme.accent(settings.accentIndex) }

    private var progress: Double {
        guard player.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(player.positionMs) / Double(player.durationMs)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 细进度线
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Rectangle().fill(accent)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 2)

            HStack(spacing: 12) {
                if let ep = player.current {
                    Button { showPlayer = true } label: {
                        HStack(spacing: 12) {
                            Artwork(url: ep.artworkUrl, size: 46, corner: 8)
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
                    .help("打开播放页")

                    HStack(spacing: 18) {
                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill").font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .disabled(!player.hasPrev)

                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)

                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .disabled(!player.hasNext)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .environmentObject(env)
                .environmentObject(player)
                .environmentObject(settings)
        }
    }
}
