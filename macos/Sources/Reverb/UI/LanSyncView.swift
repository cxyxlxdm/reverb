import SwiftUI

/// 「局域网同步」面板,macOS 与 iOS 共用同一份界面(两端都直接编译 `macos/Sources/Reverb/UI`)。
///
/// 三件事按顺序叠在一起,与 Android `LanSyncDialog.kt` 同一口径:
/// 1. **发现**:自动列出同一 Wi-Fi 下的设备;**同时**永远保留手动地址输入 ——
///    AP 隔离 / 访客网络会让组播到不了对端,发现失败不是功能坏了。
/// 2. **配对**:六位数字要人眼比对。这套加密没有证书体系,配对码就是唯一的中间人判据。
/// 3. **结果**:只报**新增条数**(合并前后之差),不把远端总数当新增混报。
///
/// 打开即监听、关闭即停止(控制器 `start()` / `stop()`)。P0 不做后台常驻,
/// 这一条是用户定的边界,也顺带避开系统对后台网络的限制。
struct LanSyncView: View {
    @ObservedObject var controller: LanSyncController
    @Environment(\.dismiss) private var dismiss
    @State private var manual = ""

    /// 配对与传输中不允许关面板:那会把 socket 抽走,另一端看到的是「网络中断」。
    private var locked: Bool {
        switch controller.state {
        case .confirm, .syncing: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("局域网同步")
                .font(.title3.weight(.semibold))

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Text("只同步订阅、收藏、印记、批注、历史与收听统计；下载与设置不参与。删除目前不会同步：在一台设备上取消订阅后，另一台同步时可能把它带回来。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            footer
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .interactiveDismissDisabled(locked)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("等待另一台设备…")
            }

        case let .listening(deviceName, addresses, peers):
            listening(deviceName: deviceName, addresses: addresses, peers: peers)

        case let .connecting(target):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在连接 \(target)…")
            }

        case let .confirm(peerName, code):
            confirm(peerName: peerName, code: code)

        case let .syncing(peerName, stage, percent):
            syncing(peerName: peerName, stage: stage, percent: percent)

        case let .done(result):
            done(result)

        case let .failed(_, fail, detail):
            failed(fail: fail, detail: detail)
        }
    }

    // MARK: - 各状态

    private func listening(deviceName: String, addresses: [String], peers: [LanSyncPeer]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机：\(deviceName)")

            if addresses.isEmpty {
                Text("没有找到 Wi-Fi 地址。请先连接与另一台设备相同的 Wi-Fi。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("本机地址，可让对方手动输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(addresses, id: \.self) { addr in
                    Text(addr)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
            }

            Text("附近的设备")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            if peers.isEmpty {
                Text("还没发现设备。确认对方也打开了这个页面；找不到就直接输入对方屏幕上显示的地址。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(peers) { peer in
                    Button {
                        controller.connect(to: peer)
                    } label: {
                        HStack {
                            Text(peer.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }

            HStack(spacing: 8) {
                TextField("对方地址，如 192.168.1.5:47820", text: $manual)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                Button("连接") { controller.connect(manual: manual) }
                    .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)

            Text("在任意一台设备上点对方即可，不需要两台都点。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func confirm(peerName: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("核对配对码")
                .font(.headline)
            Text("对方：\(peerName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(spaced(code))
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 6)
            Text("两台设备上的六位数字必须完全相同。不同就取消，可能有人在中间。")
                .font(.footnote)
        }
    }

    private func syncing(peerName: String, stage: LanSyncStage, percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正在与 \(peerName) 同步…")
            Text(stageText(stage))
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(percent) / 100)
        }
    }

    private func done(_ result: LanSyncResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("同步完成")
                .font(.headline)
            Text("已与 \(result.peerName) 合并")
            if result.total > 0 {
                Text("新增：订阅 \(result.subscriptions) · 收藏 \(result.favorites) · 印记 \(result.stamps) · 批注 \(result.notes) · 历史 \(result.history) · 统计 \(result.stats)")
                    .foregroundStyle(.tint)
            } else {
                Text("两端已经一致，没有新增内容。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func failed(fail: LanSyncFail, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("同步失败")
                .font(.headline)
            Text(failText(fail))
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch controller.state {
            case .confirm:
                Button("取消") { controller.confirm(false) }
                Button("一致，开始同步") { controller.confirm(true) }
                    .buttonStyle(.borderedProminent)
            case .done, .failed:
                Button("关闭") { dismiss() }
                Button("再同步一次") {
                    controller.stop()
                    controller.start()
                }
            default:
                Button("关闭") { dismiss() }
                    .disabled(locked)
            }
        }
    }

    // MARK: - 文案

    private func spaced(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 3).map { start in
            let from = code.index(code.startIndex, offsetBy: start)
            let to = code.index(from, offsetBy: min(3, code.count - start))
            return String(code[from..<to])
        }.joined(separator: " ")
    }

    private func stageText(_ stage: LanSyncStage) -> LocalizedStringKey {
        switch stage {
        case .sending: return "发送数据"
        case .receiving: return "接收数据"
        case .merging: return "合并数据"
        }
    }

    private func failText(_ fail: LanSyncFail) -> LocalizedStringKey {
        switch fail {
        case .connect: return "连不上对方。确认两台设备在同一 Wi-Fi、对方页面开着；也可以改用对方屏幕上显示的地址。"
        case .version: return "两台设备的版本不一致，先升级到同一版本。"
        case .protocolProblem: return "对方的回应不符合预期，已中止。"
        case .decrypt: return "加密校验失败，已中止。"
        case .io: return "网络中断，已中止。"
        case .cancelled: return "已取消。"
        case .peerCancelled: return "对方取消了这次同步。"
        }
    }
}

/// 创建控制器并承载面板。控制器与界面同生共死:
/// `@StateObject` 在 sheet 关闭时释放,监听随之停止,不会留下后台 socket。
struct LanSyncSheet: View {
    @StateObject private var controller: LanSyncController

    init(env: AppEnvironment) {
        _controller = StateObject(wrappedValue: LanSyncController(env: env))
    }

    var body: some View {
        LanSyncView(controller: controller)
    }
}
