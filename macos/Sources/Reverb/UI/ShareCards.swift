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
    guard let cg = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("reverb-\(UUID().uuidString).png")
    do { try png.write(to: url); return url } catch { return nil }
}

/// 用 NSSavePanel 让用户选择位置保存 PNG。
@MainActor
func saveWithPanel(_ view: some View, defaultName: String, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultName
    panel.allowedContentTypes = [.png]
    if panel.runModal() == .OK, let url = panel.url {
        try? png.write(to: url)
    }
}

/// 异步加载远程封面为 NSImage(供 ImageRenderer 同步渲染使用)。
func loadNSImage(_ urlString: String) async -> NSImage? {
    guard let u = URL(string: urlString),
          let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
    return NSImage(data: data)
}
