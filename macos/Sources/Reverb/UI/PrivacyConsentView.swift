import SwiftUI
import AppKit

/// 首次启动的隐私同意门。对应 Android `PrivacyConsentScreen.kt` / 鸿蒙 `PrivacyConsentPage.ets`。
///
/// **为什么必须有**:平台合规指引要求首次启动即以显著方式提示用户阅读隐私政策,
/// 且**在用户同意之前不得申请任何个人信息或权限**。桌面上真正会被触发的是联网 ——
/// 发现页一出现就去请求 iTunes / fyyd / gpodder,并带上本机 IP 与 User-Agent。
/// 因此这一页是**硬门**:未同意时主界面树根本不构建(`ReverbApp` 的 `PrivacyGate`),
/// 网络请求一次都发不出去。
///
/// 「不同意」直接退出 —— 与手机两端同一取舍:本应用没有能脱离联网使用的核心功能可退让,
/// 给一个残缺状态不如说清楚。
private struct ConsentBody: View {
    var body: some View {
        // 四段分开写而不是拼一整个字符串:每一段都是独立的本地化 key,
        // 法/西/英三种语言里段落长度差很多,合成一整条之后译文的换行位置无从校正。
        VStack(alignment: .leading, spacing: 14) {
            Text("余音以本机处理为主。没有开发者后端、账号、广告、统计、归因、第三方登录、第三方推送、崩溃上报或跨应用追踪。订阅、历史、收藏、下载、收听统计、设置、批注与运行日志都在本机处理，不会自动上传给开发者；macOS 版只使用系统自带的框架，不含任何第三方 SDK。若你在系统设置里开启 Time Machine 备份，系统会把本机数据一并备份到你自己的备份磁盘。")
            Text("联网时，搜索词、地区或分类会发给 Apple、fyyd、gpodder 等公开目录；RSS、封面与音频直接请求发布方或托管方，因此对方会看到 IP 地址、User-Agent 和访问资源。日志可能包含节目或单集标识及所访问服务的主机名，只有你主动分享或导出时才离开应用。详情请阅读完整隐私政策。")
            Text("离线语音转文字（可选）：用系统自带的 Speech 框架在本机完成，首次使用某种语言时由系统下载对应模型；音频不上传、不出设备，也不经过任何服务器。该功能可在设置里关闭。")
            Text("点击「同意并继续」表示你已阅读并接受本政策。")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrivacyConsentView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("隐私政策与数据说明")
                .font(.title2.weight(.semibold))

            // 一道短的分隔线,与 App 里页头的形态同一路;不用整宽 Divider,
            // 那是表单分区的语言,这是整页的标题。
            Rectangle()
                .fill(Theme.accent(settings.accentIndex))
                .frame(width: 40, height: 3)
                .clipShape(Capsule())
                .padding(.top, 12)

            ScrollView {
                ConsentBody()
                    .padding(.vertical, 20)
            }

            HStack(spacing: 16) {
                Button("阅读完整隐私政策") { AppInfo.openPrivacyPolicy() }
                    .buttonStyle(.link)
                Spacer()
                Button("不同意并退出") { NSApp.terminate(nil) }
                Button("同意并继续") { settings.acceptPrivacy() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 同意门。同意前只渲染 `PrivacyConsentView`,主界面树(`RootView`)不存在。
struct PrivacyGate<Content: View>: View {
    @EnvironmentObject var settings: SettingsStore
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if settings.privacyAccepted {
                content()
            } else {
                PrivacyConsentView()
            }
        }
        // 同意页也要跟着 App 主题:`RootView` 上的 `preferredColorScheme` 此刻还没生效
        // (它还没被构建)。深色主题 + 系统浅色的组合下,漏了这条正文会看不见。
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
    }
}
