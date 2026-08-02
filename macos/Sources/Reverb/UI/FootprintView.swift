import SwiftUI

/// 听觉足迹画廊:印章格网 + 分享 / 保存海报。以 sheet 形式呈现。
struct FootprintView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var posterURL: URL?

    private var accent: Color { Theme.accent(settings.accentIndex) }
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if env.stamps.stamps.isEmpty {
                    StateView(symbol: "seal", text: "还没有留下听觉印记")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(env.stamps.stamps) { s in chip(s) }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("听觉足迹")
            .frame(minWidth: 560, minHeight: 520)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if !env.stamps.stamps.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        if let posterURL {
                            ShareLink(item: posterURL) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            saveWithPanel(FootprintPoster(stamps: env.stamps.stamps, accent: accent),
                                          defaultName: "reverb-footprint.png")
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
        }
        .tint(accent)
        .task(id: env.stamps.stamps.count) {
            guard !env.stamps.stamps.isEmpty else { posterURL = nil; return }
            posterURL = renderPNG(FootprintPoster(stamps: env.stamps.stamps, accent: accent))
        }
    }

    private func chip(_ s: Stamp) -> some View {
        VStack(spacing: 10) {
            Text(s.seal)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 64, height: 64)
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
