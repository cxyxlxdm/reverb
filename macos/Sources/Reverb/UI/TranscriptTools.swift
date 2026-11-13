import SwiftUI

/// 逐字稿页顶部的「搜索条」与「导出菜单」。macOS 与 iOS 各有一份 `TranscriptPage`,
/// 但这两件东西必须长得一样、文案一样,否则同一功能在两端的自述就会分叉 ——
/// 所以放在共享层由两端共用(理由与 `TranscriptLines` 被两端共用相同)。
///
/// 搜索的**匹配计算**不在这里(见 `TranscriptSearch`):这里只是把结果画出来,
/// 每帧重绘时不该再扫一遍稿子(硬规矩 6)。
struct TranscriptFindBar: View {
    @Binding var query: String
    /// 命中的**句子数**(不是出现次数)—— 与 Android 的「第几处 / 共几处」同口径。
    let count: Int
    let cursor: Int
    let onPrev: () -> Void
    let onNext: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    private var canStep: Bool { count > 0 }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("搜索逐字稿", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("清除"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            )

            Group {
                if canStep {
                    Text(verbatim: "\(cursor + 1) / \(count)")
                        .monospacedDigit()
                } else {
                    Text("无匹配")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()

            Button(action: onPrev) { Image(systemName: "chevron.up") }
                .disabled(!canStep)
                .accessibilityLabel(Text("上一处"))
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .disabled(!canStep)
                .accessibilityLabel(Text("下一处"))
            Button(action: onCancel) { Image(systemName: "xmark") }
                .accessibilityLabel(Text("取消"))
        }
        .buttonStyle(.borderless)
        .onAppear { focused = true }
    }
}

/// 导出入口:两种格式各是一个系统分享项(`ShareLink`),点击即弹系统分享面板。
///
/// 文件**不在渲染路径里生成** —— 由页面在稿子就绪时写好临时文件,这里只把它交出去。
/// 写失败(磁盘满 / 沙盒权限)时页面会拿不到 URL,整个菜单就不出现;与设置页
/// 「分享日志」的处理一致:此刻用户并没有点「导出」,弹一句失败提示反而莫名其妙。
struct TranscriptExportMenu: View {
    let textFile: URL?
    let markdownFile: URL?

    var body: some View {
        Menu {
            if let url = textFile {
                ShareLink(item: url) { Text("纯文本 (.txt)") }
            }
            if let url = markdownFile {
                ShareLink(item: url) { Text("Markdown (.md)") }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text("导出逐字稿"))
    }
}
