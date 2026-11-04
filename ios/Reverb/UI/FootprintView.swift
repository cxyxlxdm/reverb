import SwiftUI
import UIKit

/// 听觉足迹画廊:印章格网 + 分享 / 保存海报。以 sheet 形式呈现。
/// 与 macOS `FootprintView` 同布局;保存从「NSSavePanel」换成「存进相册」。
struct FootprintView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var shareURL: URL?
    @State private var saveFailed = false
    @State private var savedOK = false

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if env.stamps.stamps.isEmpty {
                    StateView(symbol: "seal", text: "还没有留下听觉印记")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(env.stamps.stamps) { s in chip(s) }
                        }
                        .padding(Metrics.pagePadding)
                    }
                }
            }
            .navigationTitle("听觉足迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if !env.stamps.stamps.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            guard let image else { return }
                            Task {
                                if await saveToPhotoLibrary(image) { savedOK = true } else { saveFailed = true }
                            }
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        .disabled(image == nil)
                    }
                }
            }
        }
        .tint(accent)
        .alert("已保存到相册", isPresented: $savedOK) {
            Button("好", role: .cancel) {}
        }
        .alert("分享图片生成失败", isPresented: $saveFailed) {
            Button("好", role: .cancel) {}
        }
        .task(id: env.stamps.stamps.count) {
            guard !env.stamps.stamps.isEmpty else {
                image = nil
                shareURL = nil
                return
            }
            let rendered = renderImage(FootprintPoster(stamps: env.stamps.stamps, accent: accent))
            image = rendered
            shareURL = rendered.flatMap { writeTempPNG($0, name: "reverb-footprint.png") }
        }
    }

    private func chip(_ s: Stamp) -> some View {
        VStack(spacing: 10) {
            Text(s.seal)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 60, height: 60)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(s.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if !s.podcastTitle.isEmpty {
                Text(s.podcastTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
