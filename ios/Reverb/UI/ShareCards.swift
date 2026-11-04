import SwiftUI
import UIKit
import Photos

// MARK: - 剪藏卡片

/// 单集剪藏卡片(420×560):水墨深色渐变 + 封面 + 标题 + 剪藏时间 + 装饰波形 + 落款。
/// 与 macOS `MomentCard` 同一套排版与文案;尺寸不随屏幕走 —— 海报是拿出去的文件,
/// 不是界面(Android 固定 1080×1500,这里按 2× 渲染成 840×1120)。
struct MomentCard: View {
    let episode: Episode
    let positionMs: Int
    var accent: Color = .accentColor
    var artwork: UIImage? = nil

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

            Label(String(format: NSLocalizedString("剪藏 · %@", comment: "剪藏卡上的时间"),
                         timeText(positionMs)), systemImage: "bookmark.fill")
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
            Image(uiImage: artwork).resizable().aspectRatio(contentMode: .fill)
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

/// 频道分享卡:频道 Logo + 频道名 + 简介(最多四行)+ App 落款,不携带可能含私有凭据的 RSS 地址。
struct ChannelShareCard: View {
    let podcast: Podcast
    var accent: Color = .accentColor
    var artwork: UIImage? = nil

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
            Image(uiImage: artwork).resizable().aspectRatio(contentMode: .fill)
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

/// 听觉足迹海报:标题 + 印记数量 + 印章格网 + 落款。
struct FootprintPoster: View {
    let stamps: [Stamp]
    var accent: Color = .accentColor

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("听觉足迹").font(.largeTitle.bold()).foregroundStyle(.white)
                Text(String(format: NSLocalizedString("共 %lld 枚印记", comment: ""), Int64(stamps.count)))
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

// MARK: - 渲染 / 分享 / 保存

/// 把视图渲染成 UIImage。iOS 没有 NSSavePanel:`ImageRenderer` 拿到图之后,
/// 分享走系统分享面板(ShareLink),保存走相册(仅新增权限)。
@MainActor
func renderImage(_ view: some View, scale: CGFloat = 2) -> UIImage? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.uiImage else {
        Log.e("ShareCard", "海报渲染失败:uiImage 为空")
        return nil
    }
    return image
}

/// 渲染后写一份临时 PNG,供 `ShareLink` 分享(它只认 URL / 字符串,不认内存图)。
@MainActor
func writeTempPNG(_ image: UIImage, name: String) -> URL? {
    guard let data = image.pngData() else {
        Log.e("ShareCard", "海报 PNG 编码返回空")
        return nil
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("reverb-\(UUID().uuidString)-\(name)")
    do {
        try data.write(to: url, options: .atomic)
        return url
    } catch {
        Log.e("ShareCard", "海报临时文件写入失败:\(url.lastPathComponent)", error: error)
        return nil
    }
}

/// 保存到相册(.addOnly),返回是否成功。**用户拒绝授权与写入失败都返回 false** ——
/// 两者的界面反馈都是"没存上",调用方只需要说一句「保存失败」。
@MainActor
func saveToPhotoLibrary(_ image: UIImage) async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
        Log.i("ShareCard", "保存相册未获授权 status=\(status.rawValue)")
        return false
    }
    do {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
        return true
    } catch {
        Log.e("ShareCard", "保存到相册失败", error: error)
        return false
    }
}

/// 异步取封面并解码为 UIImage(海报是同步渲染的,`AsyncImage` 那条异步链等不到结果)。
func loadUIImage(_ urlString: String) async -> UIImage? {
    guard !urlString.isEmpty else { return nil }
    guard let data = await ArtworkCache.shared.data(for: urlString) else { return nil }
    return UIImage(data: data)
}

/// 三张海报共用的预览 / 分享 / 保存面板。
///
/// 为什么要先预览再分享:手机上"点一下就直接起分享面板"会把生成好的图藏在系统面板里,
/// 用户看不到自己发出去的是什么;先看一眼再决定更接近剪贴的实际动作。
struct ShareCardPreview: View {
    let title: LocalizedStringKey
    let image: UIImage
    /// 写进文件名的那一段(不带扩展名)。
    let fileName: String
    var accent: Color = .accentColor

    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var saveFailed = false
    @State private var savedOK = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                        .padding(20)
                }
                HStack(spacing: 12) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        Task {
                            if await saveToPhotoLibrary(image) { savedOK = true } else { saveFailed = true }
                        }
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { shareURL = writeTempPNG(image, name: "\(fileName).png") }
            .alert("已保存到相册", isPresented: $savedOK) {
                Button("好", role: .cancel) {}
            }
            .alert("分享图片生成失败", isPresented: $saveFailed) {
                Button("好", role: .cancel) {}
            }
        }
        .tint(accent)
    }
}
