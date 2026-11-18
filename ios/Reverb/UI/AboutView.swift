import SwiftUI
import UIKit

/// 关于页与许可页共用的常量。版本号取 Info.plist,备案号只显示已下发的值。
enum AppInfo {
    static let beianNumber = "浙ICP备2026068045号-1A"
    static let privacyURL = URL(string: "https://cxyxl.cn/reverb/privacy.html")!

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    static func openPrivacyPolicy() {
        UIApplication.shared.open(privacyURL)
    }
}

/// 关于页。三段正文与另三端同一分工;**只列 iOS 真的有的能力** ——
/// 桌面那条「检查更新」在 iOS 上由 TestFlight / App Store 负责,这里不写。
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("余音 · Reverb")
                        .font(.title.weight(.semibold))
                    Text("余音绕梁，隽永悠长")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(String(format: String(localized: "版本 %@"), AppInfo.version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    if !AppInfo.beianNumber.isEmpty {
                        Text(AppInfo.beianNumber)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }

                    section("这是什么") {
                        paragraph("余音是一款轻量的播客客户端：发现好节目、订阅收听、离线下载、随时续播，专注「听」本身。iOS 版只使用系统自带的框架，不引入任何第三方 SDK。")
                    }
                    section("主要功能") {
                        ForEach(Self.features, id: \.self) { line in
                            Text(LocalizedStringKey(line))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("设计理念") {
                        paragraph("美学上取「水墨 + 青瓷 + 梁金」的底色，名字与图标呼应「余音绕梁」——声波环绕横梁，余韵不散。")
                        paragraph("取源上坚持全链路免费、无需登录、无需任何 API Key：检索一律基于公开来源，最终始终回到发布方自己的 RSS，直接流式播放原始音频——版权干净、成本为零。")
                        paragraph("隐私上，订阅、历史和下载保存在设备本地，不向开发者自动上传，也不用于跨应用追踪。")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(Theme.accent(settings.accentIndex))
    }

    /// 一行一条,与 macOS 版同一形状;新增/删减时同步四个 `.strings`。
    private static let features: [String] = [
        "· 发现：按地区与分类浏览每日热门",
        "· 搜索：按名字或直接粘贴 RSS 地址",
        "· 直播流：粘贴一条网络电台/直播流地址直接收听",
        "· 视频链接：粘贴 B 站视频链接或 BV 号，直接当单集听（不登录；视频来源的单集不提供下载）",
        "· 频道分享：生成含 Logo、频道名、简介与余音落款的图片",
        "· 电台：随机漫游，或按时段与情境推荐",
        "· 追更：订阅频道播过的单集全在这一栏，按时间倒序翻看，可下拉刷新、单独设这一栏的播放模式",
        "· 音阁：订阅、收藏、下载、待播、历史、批注六栏管理",
        "· 批量与直达：点任意单集封面直达它所属的频道；追更、收藏、下载、历史与频道页长按单集选「多选」，勾一批一次加入待播",
        "· 离线下载：下载的单集长期留在本机，可仅 Wi-Fi 下载",
        "· 播放缓存：播过的单集自动留在本机，下次直接本地起播；断网时已加载的列表与封面仍可浏览，可在设置一键清除",
        "· 播放：倍速、快进快退、睡眠定时、播放模式（顺序 / 单曲循环 / 随机）与自动续播",
        "· 后台播放：锁屏或切到其他应用后继续播放，支持锁屏遥控与「正在播放」",
        "· 逐字稿：优先显示发布方提供的逐字稿，没有时在本机转成文字并随进度高亮（本机转写需 iOS 26）；支持全文搜索，可导出为文本或 Markdown 分享",
        "· 批注：记下这一秒和此刻的一句话；音阁「批注」栏把它们连成时间线，点一下从那一句接着听",
        "· 节目笔记：播放页查看简介",
        "· 章节：发布方给了章表的单集，播放页进度条上方显示当前章节，点开可跳转；章表取一次后离线也能看",
        "· 剪藏与足迹：把此刻的一句话做成剪藏海报分享；每一枚听觉印记汇成一张足迹图",
        "· 订阅更新提醒：订阅有新一期时通知你",
        "· 备份：勾选分区导出或恢复备份（与手机端格式互通），也能导入导出 OPML",
        "· 局域网同步：在同一 Wi-Fi 下与另一台设备合并订阅、收藏、印记、批注与进度；正在听的一集还能在另一台接着听（由你点，不会自动接管）",
        "· 外观：深色 / 浅色 / 跟随系统、字号、主题配色、多语言"
    ]

    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .padding(.top, 20)
            content()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 开源许可页:与另三端内容不同、性质相同。iOS 同样不引任何三方库。
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: SettingsStore

    private struct Entry: Identifiable {
        let name: String
        var id: String { name }
    }

    private let frameworks = [
        Entry(name: "SwiftUI / UIKit"),
        Entry(name: "AVFoundation"),
        Entry(name: "Speech（SpeechAnalyzer）"),
        Entry(name: "Foundation / URLSession")
    ]

    private let sources = [
        "Apple iTunes Search / Marketing RSS",
        "fyyd.de",
        "gpodder.net"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("余音 iOS 版只使用系统自带的框架，不引入任何第三方 SDK 或统计组件。以下是所用的系统能力与数据来源。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    header("系统能力")
                    ForEach(frameworks) { f in
                        HStack(alignment: .firstTextBaseline) {
                            Text(f.name).font(.body)
                            Spacer(minLength: 16)
                            Text("系统框架").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }

                    header("数据来源")
                    Text("以下为公开的播客目录/检索接口，仅用于检索与榜单；音频始终来自发布方原始 RSS，本应用不转存、不代理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(sources, id: \.self) { s in
                        Text(s).font(.body).padding(.vertical, 6)
                    }
                    Text("播客发布方自己的 RSS 地址").font(.body).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("开源许可")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(Theme.accent(settings.accentIndex))
    }

    private func header(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }
}