import SwiftUI
import UIKit

/// 首次启动的隐私同意门。与 Android `PrivacyConsentScreen.kt` / 鸿蒙 `PrivacyConsentPage.ets`
/// / macOS `PrivacyConsentView.swift` 同一分工:**未同意时主界面树根本不构建**。
///
/// 文案与 macOS 版只是平台名与系统备份名不同;iOS 没有桌面那条「应用内更新」请求,
/// 所以少了 GitHub 那一段 —— 把没有发生的网络访问写进同意页同样是失实陈述。
private struct ConsentBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("余音以本机处理为主。没有开发者后端、账号、广告、统计、归因、第三方登录、第三方推送、崩溃上报或跨应用追踪。订阅、历史、收藏、下载、收听统计、设置、批注与运行日志都在本机处理，不会自动上传给开发者；iOS 版只使用系统自带的框架，不含任何第三方 SDK。若你在系统设置里开启了 iCloud 备份，系统会把本机数据一并备份到你自己的 iCloud 空间。")
            Text("联网时，搜索词、地区或分类会发给 Apple、fyyd、gpodder 等公开目录；RSS、封面与音频直接请求发布方或托管方，因此对方会看到 IP 地址、User-Agent 和访问资源。日志可能包含节目或单集标识及所访问服务的主机名，只有你主动分享或导出时才离开应用。详情请阅读完整隐私政策。")
            // 私有订阅带来的是**一类新的本地数据**(用户名/密码)与**随请求发出的认证头**,
            // 不是新的网络地址。按本仓库口径仍要进同意页并让 privacyVersion +1。
            Text("私有订阅（可选）：部分自建 RSS 源需要用户名和密码（HTTP Basic 认证）。对方要求时，本应用会询问一次，并且只把这对凭据送回该源自己的域名（含其子域），用于它的 RSS、音频、下载与官方逐字稿；不会发给与它无关的音频 CDN。凭据只保存在本机，不进入备份、OPML 导出或日志，退订该源时一并删除。明文 http:// 源会以未加密方式发送口令，建议优先使用 https://。")
            Text("订阅更新提醒（可选）：开启后，应用会在后台每 6 小时检查一次你订阅频道的 RSS，有新一期时发一条本地通知；请求只发往发布方或托管方，与手动刷新时一样。关闭开关会撤销后续检查。")
            Text("视频链接（可选）：在搜索框粘贴一个视频页面链接或 BV 号，这一条视频会被当作单集来听——本应用向视频站公开接口（api.bilibili.com）请求标题、封面与音频地址，再从它的内容分发网络（*.bilivideo.com 等）直接流式播放，并像其他单集一样自动缓存到本机。请求不登录账号、不带任何用户标识；为取得音频地址，这类请求使用浏览器身份的 User-Agent 与视频站的来源页，对方因此会看到这些信息与你的 IP 地址。这类单集不提供「下载」。")
            Text("离线语音转文字（可选）：用系统自带的 Speech 框架在本机完成，首次使用某种语言时由系统下载对应模型；音频不上传、不出设备，也不经过任何服务器。该功能可在设置里关闭。")
            Text("点击「同意并继续」表示你已阅读并接受本政策。")
        }
        .font(.body)
        .foregroundStyle(.secondary)
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
                Spacer()
                Button("不同意并退出") { exit(0) }
                    .foregroundStyle(.secondary)
                Button("同意并继续") { settings.acceptPrivacy() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .background(Color(.systemBackground))
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
        .tint(Theme.accent(settings.accentIndex))
        .preferredColorScheme(Theme.colorScheme(settings.themeMode))
    }
}