import SwiftUI

/// 听觉足迹画廊:印章格网 + 分享 / 保存海报。以 sheet 形式呈现。
struct FootprintView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var posterURL: URL?
    /// 「保存海报」失败提示。取消不算失败,只有真写不出去才出声(见 `ShareCardOutcome`)。
    @State private var shareCardFailed = false

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
                            // 失败要出声:两端同位置都有 `share_failed` 提示。原先这条路径整段静默
                            // —— 渲染不出连面板都不弹,写不出去也没有任何反馈。取消仍静默,见 `ShareCardOutcome`。
                            if saveWithPanel(FootprintPoster(stamps: env.stamps.stamps, accent: accent),
                                             defaultName: "reverb-footprint.png") == .failed { shareCardFailed = true }
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
        }
        .tint(accent)
        .alert("分享图片生成失败", isPresented: $shareCardFailed) {
            Button("好", role: .cancel) {}
        }
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
