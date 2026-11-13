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
        // 每段分开写而不是拼一整个字符串:每一段都是独立的本地化 key,
        // 法/西/英三种语言里段落长度差很多,合成一整条之后译文的换行位置无从校正。
        VStack(alignment: .leading, spacing: 14) {
            Text("余音以本机处理为主。没有开发者后端、账号、广告、统计、归因、第三方登录、第三方推送、崩溃上报或跨应用追踪。订阅、历史、收藏、下载、收听统计、设置、批注与运行日志都在本机处理，不会自动上传给开发者；macOS 版只使用系统自带的框架，不含任何第三方 SDK。若你在系统设置里开启 Time Machine 备份，系统会把本机数据一并备份到你自己的备份磁盘。")
            Text("联网时，搜索词、地区或分类会发给 Apple、fyyd、gpodder 等公开目录；RSS、封面与音频直接请求发布方或托管方，因此对方会看到 IP 地址、User-Agent 和访问资源。日志可能包含节目或单集标识及所访问服务的主机名，只有你主动分享或导出时才离开应用。详情请阅读完整隐私政策。")
            // 私有订阅带来的是**一类新的本地数据**(用户名/密码)与**随请求发出的认证头**,
            // 不是新的网络地址。按本仓库口径仍要进同意页并让 privacyVersion +1。
            Text("私有订阅（可选）：部分自建 RSS 源需要用户名和密码（HTTP Basic 认证）。对方要求时，本应用会询问一次，并且只把这对凭据送回该源自己的域名（含其子域），用于它的 RSS、音频、下载与官方逐字稿；不会发给与它无关的音频 CDN。凭据只保存在本机，不进入备份、OPML 导出或日志，退订该源时一并删除。明文 http:// 源会以未加密方式发送口令，建议优先使用 https://。")
            // 1.0.6 追加:视频链接带来的是**新的网络访问地址**(视频站接口与它的 CDN),
            // 按本仓库口径要进同意页,并让 `SettingsStore.privacyVersion` +1 重新征求一次。
            // 段落位置紧跟「联网时」那一段:它们讲的是同一件事(请求发往哪里)。
            Text("视频链接（可选）：在搜索框粘贴一个视频页面链接或 BV 号，这一条视频会被当作单集来听——本应用向视频站公开接口（api.bilibili.com）请求标题、封面与音频地址，再从它的内容分发网络（*.bilivideo.com 等）直接流式播放，并像其他单集一样自动缓存到本机。请求不登录账号、不带任何用户标识；为取得音频地址，这类请求使用浏览器身份的 User-Agent 与视频站的来源页，对方因此会看到这些信息与你的 IP 地址。这类单集不提供「下载」。")
            // 1.0.6 macOS:应用内更新带来的是**桌面端新的网络访问地址**(发布页接口与资产下载),
            // 按本仓库口径进同意页并让 `SettingsStore.privacyVersion` +1 重新征求一次
            // (Android 从 1.0.5 起就有这条请求,那边的版本号不动 —— 见 Stores.swift 那条注释)。
            // 段落紧跟视频链接:它们讲的都是「请求发往哪里」。
            // ⚠️ 这里**不写「包含当前版本号」**:请求里其实只有仓库地址,版本比较在本机完成。
            Text("应用内更新（可选）：本版本启动时会向 GitHub 的公开发布页接口（api.github.com）询问一次「最新版是哪个」；请求只包含本应用自己的公开仓库地址，不含账号、任何标识符、订阅列表或收听内容。你也可以在「设置 → 检查更新」里随时主动询问一次。只有那次回答里确实有更新版本时才会下载安装包，下载完由你自己打开磁盘映像安装，本应用不会自行安装。")
            Text("离线语音转文字（可选）：用系统自带的 Speech 框架在本机完成，首次使用某种语言时由系统下载对应模型；音频不上传、不出设备，也不经过任何服务器。该功能可在设置里关闭。")
            // 局域网同步与私有订阅同在未发版的 1.0.8,共用同一次 privacyVersion 重问,
            // 所以没有再加一档。它新增的是本机监听端口 + 把六个备份分区发给用户自己配对的
            // 另一台设备;较新的 macOS 首次使用时也会询问「本地网络」权限。
            Text("局域网同步（可选）：在设置里打开后，本应用会在同一 Wi-Fi 内广播一个服务名（含本机设备名与一段随机标识）并临时打开一个 TCP 端口，页面关闭即停止。你确认两端显示的六位配对码一致后，订阅、收藏、印记、批注、历史与收听统计（按设备标识合并）会直接发给对方设备，不含音频、缓存、私有订阅的用户名与密码、应用设置或播放队列；数据经两端协商的密钥加密（ECDH P-256 / AES-256-GCM），不经过任何服务器，也不上传给开发者。删除也会同步：在一台设备上退订、取消收藏、删掉印记或批注时，本机会记下「哪一类、哪一条、什么时候删的」并随同步发给对端，让对端也删掉；这份记录只存在本机，90 天后清除。删除记录优先于对端数据，若另一台在同步前刚重新添加了同一条，这一次仍会被删除。首次使用可能由系统询问「本地网络」权限。")
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
