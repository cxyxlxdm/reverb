import SwiftUI

/// 底部常驻播放条:细进度线 + 封面 + 标题/节目 + 上一集/播放暂停/下一集;
/// 点击信息区打开全屏播放页。纤细、优雅。
struct NowPlayingBar: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    var onOpenChannel: (Podcast) -> Void = { _ in }
    /// 粒子消散期间条子隐身(占位保留),由根视图在散尽后 close()。
    var ghost: Bool = false
    /// 点 X:把条子的窗口矩形交回根视图去放粒子。真正 close 延迟 430ms,不在本组件做。
    var onDissolve: (CGRect) -> Void = { _ in }
    @State private var showPlayer = false
    @State private var showQueue = false
    /// 本条在窗口坐标系(.global)里的矩形,布局变化即上报 —— 放粒子要用最后已知位置。
    @State private var frameInWindow = CGRect.zero

    private var accent: Color { Theme.accent(settings.accentIndex) }

    private var progress: Double {
        guard player.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(player.positionMs) / Double(player.durationMs)))
    }

    /// 拖动/点击进度线时的临时位置(0~1)。松手才 seek,拖动中只挪线不真跳。
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        VStack(spacing: 0) {
            // 细进度线:点/拖即跳播。2pt 的线放在 14pt 命中区中央 —— 细线本身根本点不中,
            // 也曾是「无法拖动播放进度」的直接原因;macOS 惯例悬停显示小手。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Rectangle().fill(accent)
                        .frame(width: geo.size.width * (scrubbing ? scrubValue : progress))
                }
                .frame(height: 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            scrubbing = true
                            scrubValue = Self.fraction(g.location.x, geo.size.width)
                        }
                        .onEnded { g in
                            scrubbing = false
                            seek(fraction: Self.fraction(g.location.x, geo.size.width))
                        }
                )
            }
            .frame(height: 14)
            .pointingHandCursor()

            HStack(spacing: 12) {
                if let ep = player.current {
                    // 封面独立成一颗按钮:直达这一集所属的频道页(与 Android 迷你条同一条门,
                    // 见 M4)。播放条在 `NavigationStack` 之外,所以走 `onOpenChannel` 回调,
                    // 由根视图把频道压进导航栈 —— 这里不能用 `NavigationLink(value:)`。
                    if let channel = ep.channelRef {
                        Button { onOpenChannel(channel) } label: {
                            Artwork(url: ep.artworkUrl, size: 46, corner: 8)
                        }
                        .buttonStyle(.plain)
                        .help("进入频道页")
                        .accessibilityLabel(Text("进入频道页"))
                        .pointingHandCursor()
                    } else {
                        Artwork(url: ep.artworkUrl, size: 46, corner: 8)
                    }
                    Button { showPlayer = true } label: {
                        HStack(spacing: 0) {
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

                        Button { if player.playbackError != nil { player.retry() } else { player.togglePlayPause() } } label: {
                            Image(systemName: player.playbackError != nil ? "arrow.clockwise" : (player.isPlaying ? "pause.fill" : "play.fill"))
                                .font(.system(size: 20))
                                .frame(width: 30, height: 30)
                                .foregroundStyle(player.playbackError != nil ? .orange : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(player.playbackError != nil ? "加载失败,点击重试" : "")

                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .disabled(!player.hasNext)

                        Button { showQueue = true } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 15))
                                .overlay(alignment: .topTrailing) {
                                    if !player.userQueue.isEmpty {
                                        Circle().fill(accent).frame(width: 6, height: 6)
                                            .offset(x: 4, y: -3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help("待播")

                        // 关闭(参考视频的位次:X 在播放条最右端,待播入口之外再一枚)。
                        // 色阶 secondary:次要动作,不与播放键争权重(与另两端同判)。
                        // 动作交给根视图(粒子 + 延迟 close),本组件不再直接 close ——
                        // 直接关会让布局收拢与粒子飞散同时发生,读起来是"边散边塌"。
                        Button { onDissolve(frameInWindow) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("关闭播放条")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { frameInWindow = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { frameInWindow = $0 }
            }
        )
        .sheet(isPresented: $showPlayer) {
            PlayerView(onOpenChannel: { pod in showPlayer = false; onOpenChannel(pod) })
                .environmentObject(env)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(env.transcripts)
                .themedSheet(settings)
        }
        .sheet(isPresented: $showQueue) {
            QueueView(onOpenChannel: { pod in
                // 先收 sheet 再压栈:根视图的 path 在 sheet 后面改了,用户会「关掉之后
                // 才看见目的地」—— 中间那一帧看起来像点空了。
                showQueue = false
                onOpenChannel(pod)
            })
                .environmentObject(env)
                .environmentObject(player)
                .environmentObject(settings)
                .themedSheet(settings)
        }
    }

    private static func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private func seek(fraction f: Double) {
        guard player.durationMs > 0 else { return }
        player.seek(toMs: Int(f * Double(player.durationMs)))
    }
}
