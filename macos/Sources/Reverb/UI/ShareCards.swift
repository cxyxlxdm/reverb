import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 剪藏卡片

/// 单集剪藏卡片(约 420×560):水墨深色渐变 + 封面 + 标题 + 剪藏时间 + 装饰波形 + 落款。
struct MomentCard: View {
    let episode: Episode
    let positionMs: Int
    var accent: Color = .accentColor
    var artwork: NSImage? = nil

    private func timeText(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        VStack(spacing: 20) {
            artworkView
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)

            VStack(spacing: 8) {
                Text(episode.title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(episode.podcastTitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Label("剪藏 · \(timeText(positionMs))", systemImage: "bookmark.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(accent.opacity(0.16), in: Capsule())

            waveform
                .frame(height: 26)
                .padding(.horizontal, 40)

            Spacer(minLength: 0)

            Text("余音 · 每一段余音都值得留存")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(32)
        .frame(width: 420, height: 560)
        .background(
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.13),
                         Color(red: 0.05, green: 0.06, blue: 0.08)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder private var artworkView: some View {
        if let artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(accent.opacity(0.25))
                Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var waveform: some View {
        GeometryReader { geo in
            let bars = 34
            let spacing: CGFloat = 3
            let barWidth = (geo.size.width - spacing * CGFloat(bars - 1)) / CGFloat(bars)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { i in
                    let h = (sin(Double(i) * 0.7) * 0.5 + 0.5) * 0.8 + 0.2
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(accent.opacity(0.7))
                        .frame(width: barWidth, height: geo.size.height * h)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - 频道分享卡片

/// 频道分享卡:频道 Logo + 频道名 + 简介(最多四行,超出省略)+ App 落款,不携带可能含私有凭据的 RSS 地址。
struct ChannelShareCard: View {
    let podcast: Podcast
    var accent: Color = .accentColor
    var artwork: NSImage? = nil

    /// 与详情页同一显示口径:存储的是 RSS 原文,渲染前统一去标签(见 PodcastDetailView)
    private var plainDesc: String { Fmt.plainText(podcast.description) }

    var body: some View {
        VStack(spacing: 28) {
            artworkView
                .frame(width: 250, height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 9)

            Text(podcast.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if !plainDesc.isEmpty {
                Text(plainDesc)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }

            Spacer(minLength: 0)

            Text("余音 · Reverb")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(36)
        // 简介最多四行 + 标题三行的最坏情形装不下 525;短内容由 Spacer 撑开
        .frame(width: 420, height: 640)
        .background(
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.13),
                         Color(red: 0.05, green: 0.06, blue: 0.08)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder private var artworkView: some View {
        if let artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(accent.opacity(0.25))
                Text("余")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
    }
}

// MARK: - 听觉足迹海报

/// 听觉足迹海报:标题 + 印记数量 + 印章格网(印字 + 单集标题)+ 落款。
struct FootprintPoster: View {
    let stamps: [Stamp]
    var accent: Color = .accentColor

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("听觉足迹").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("共 \(stamps.count) 枚印记")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(stamps) { s in chip(s) }
            }

            Text("余音 · 听觉足迹")
                .font(.footnote).foregroundStyle(.white.opacity(0.5))
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 520)
        .background(
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.13),
                         Color(red: 0.05, green: 0.06, blue: 0.08)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    private func chip(_ s: Stamp) -> some View {
        VStack(spacing: 8) {
            Text(s.seal)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 52, height: 52)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(s.title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 渲染 / 保存

/// 用 ImageRenderer 把视图渲染为 PNG,写入临时文件并返回 URL。
@MainActor
func renderPNG(_ view: some View, scale: CGFloat = 2) -> URL? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else {
        Log.e("ShareCard", "海报渲染失败:cgImage 为空")
        return nil
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        Log.e("ShareCard", "海报渲染失败:PNG 编码返回空")
        return nil
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("reverb-\(UUID().uuidString).png")
    do { try png.write(to: url); return url }
    catch { Log.e("ShareCard", "海报临时文件写入失败:\(url.lastPathComponent)", error: error); return nil }
}

/// `saveWithPanel` 的结果。**取消与失败必须分开** —— 用户按「取消」不是错误,弹一句「生成失败」
/// 是诬告(鸿蒙那一侧同族的坑记在 H147 / #99:那边 `saveText` 返回 `boolean`,把取消渲染成了失败提示)。
enum ShareCardOutcome { case saved, cancelled, failed }

/// 用 NSSavePanel 让用户选择位置保存 PNG。
///
/// 原先三处失败全是静默:两个 `guard … else { return }` 加一句 `try? png.write(to:)`,
/// 而 `try?` 那一处正是"面板已经点完、位置已经选好、字没写进去"的情形 —— 用户看到的是"什么都没发生"。
/// 现在渲染不出来就**不弹面板**(没有可写的内容,弹面板等于让用户白选一次),并把结果交回调用方出声。
/// 见 H157 收尾段与 H158 同族清点:两端同位置都有提示(`share_failed`「分享图片生成失败」)。
@MainActor
func saveWithPanel(_ view: some View, defaultName: String, scale: CGFloat = 2) -> ShareCardOutcome {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else {
        Log.e("ShareCard", "保存海报失败:cgImage 为空(未弹面板)")
        return .failed
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        Log.e("ShareCard", "保存海报失败:PNG 编码返回空(未弹面板)")
        return .failed
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultName
    panel.allowedContentTypes = [.png]
    guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
    do { try png.write(to: url) }
    catch {
        Log.e("ShareCard", "保存海报失败:\(url.lastPathComponent)", error: error)
        return .failed
    }
    return .saved
}

/// 异步加载远程封面为 NSImage(供 ImageRenderer 同步渲染使用)。
func loadNSImage(_ urlString: String) async -> NSImage? {
    guard let u = URL(string: urlString),
          let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
    return NSImage(data: data)
}
