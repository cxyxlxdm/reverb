import SwiftUI
import AppKit

/// 关于页与开源许可页共用的常量。
///
/// 桌面端此前**没有任何对外文案出口**:设置页连版本号都不显示,隐私政策与备案号
/// 只在手机那两端存在(`docs/MACOS-GAPS.md` M11)。这一批把它们补齐,
/// 口径与 Android `AboutScreen.kt` / `LicensesScreen.kt` 对齐。
enum AppInfo {
    /// 备案号。监管要求在应用内显著位置展示。
    ///
    /// **空串 = 整行不渲染**(调用方判断),不是打印一个占位号 —— 硬规矩 13:
    /// 预写的是格式与位置,不是值;值只以下发的凭证为准。这一条此刻显示的是
    /// 已下发的号,与 Android `beian_number` / 鸿蒙同名键**逐字相同**。
    static let beianNumber = "浙ICP备2026068045号-1A"

    /// 完整隐私政策。与两端同一个地址,系统浏览器打开(不内置 WebView —— 三端同一取舍)。
    static let privacyURL = URL(string: "https://cxyxl.cn/reverb/privacy.html")!

    /// 版本号一律取 `Info.plist`。写死在文案里,发版不记得同步就会漂(Android 侧同一条注释)。
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    static func openPrivacyPolicy() {
        NSWorkspace.shared.open(privacyURL)
    }
}

/// 关于页。三段正文(这是什么 / 主要功能 / 设计理念)与 Android、鸿蒙同一分工;
/// 顶上多一行备案号,仅当 `AppInfo.beianNumber` 非空时渲染。
///
/// **主要功能这一段只写桌面真的有的**:手机那两条「播放缓存」「订阅更新提醒」
/// 在桌面还没有实现(`docs/MACOS-GAPS.md` M8、M3),
/// 照抄就是不实陈述 —— 这一页会被逐字读。
///
/// 每个 key 都是**简中原文**(macOS 的本地化约定,见 `Localization/en.lproj` 头注释):
/// 简中那份没有 `.lproj`,靠"键名本身就是简中"显示;另四种语言在 `.strings` 里逐条对译。
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
                        paragraph("余音是一款轻量的播客客户端：发现好节目、订阅收听、离线下载、随时续播，专注「听」本身。macOS 版只使用系统自带的框架，不引入任何第三方 SDK。")
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
            .frame(minWidth: 620, minHeight: 600)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(Theme.accent(settings.accentIndex))
    }

    /// 一行一条:手机端正文里的 `\n` 分段,在桌面上换成独立 Text ——
    /// 一是行距由排版系统管,二是不必让 `.strings` 的键里带换行符。
    private static let features: [String] = [
        "· 发现：按地区与分类浏览每日热门",
        "· 搜索：按名字或直接粘贴 RSS 地址",
        "· 频道分享：生成含 Logo、频道名、简介与余音落款的图片",
        "· 电台：随机漫游，或按时段与情境推荐",
        "· 追更：订阅频道播过的单集全在这一栏，按时间倒序翻看，可在页头手动刷新，可单独设这一栏的播放模式",
        "· 音阁：订阅、收藏、下载、待播、历史、批注六栏管理",
        "· 批量与直达：点任意单集封面直达它所属的频道；多个列表可切换「选择」把一批一次加入待播",
        "· 离线下载：下载的单集长期留在本机",
        "· 播放：倍速、快进快退、睡眠定时、播放模式（顺序 / 单曲循环 / 随机）、自动续播，以及系统媒体键与「正在播放」",
        "· 逐字稿：优先显示发布方提供的逐字稿，没有时在本机转成文字并随进度高亮（本机转写需 macOS 26）",
        "· 批注：记下这一秒和此刻的一句话；音阁「批注」栏把它们连成时间线，点一下从那一句接着听",
        "· 节目笔记：播放页横滑查看简介",
        "· 备份：勾选分区导出或恢复备份（与手机端格式互通），也能导入导出 OPML",
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

/// 开源许可页。对应 Android `LicensesScreen.kt` / 鸿蒙 `LicensesPage.ets`。
///
/// 与两端**内容不同、性质相同**:Android 列的是 Compose / Media3 / OkHttp / Coil;
/// 鸿蒙列的是 HarmonyOS SDK 与所用的系统 Kit;桌面端**不引任何三方库**,
/// 用到的全是 Apple 系统框架,所以列的是系统能力。取源清单与前两端一致,
/// 差别只有一条:**桌面不读官网那份推荐 OPML**(内置种子清单随包分发),
/// 所以 `src_site_opml` 在这里不能列 —— 列上去就是一句没发生的访问。
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: SettingsStore

    private struct Entry: Identifiable {
        let name: String
        var id: String { name }
    }

    /// 框架名是专有名词,五套界面同形,留在字面量里(判据与 Android `libs()` 相同:
    /// 「换语种要不要变」);右侧那格「系统框架」才走资源。
    private let frameworks = [
        Entry(name: "SwiftUI / AppKit"),
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
                    Text("余音 macOS 版只使用系统自带的框架，不引入任何第三方 SDK 或统计组件。以下是所用的系统能力与数据来源。")
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
            .frame(minWidth: 620, minHeight: 600)
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
