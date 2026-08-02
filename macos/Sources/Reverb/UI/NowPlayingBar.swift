import SwiftUI

/// 底部常驻播放条:封面 + 标题/节目 + 播放暂停 + 下一集;点击整条打开全屏播放页。
struct NowPlayingBar: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @State private var showPlayer = false

    var body: some View {
        HStack(spacing: 12) {
            if let ep = player.current {
                Button { showPlayer = true } label: {
                    HStack(spacing: 12) {
                        Artwork(url: ep.artworkUrl, size: 44, corner: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title).font(.callout).lineLimit(1)
                            Text(ep.podcastTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 16))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasNext)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .environmentObject(env)
                .environmentObject(player)
        }
    }
}
