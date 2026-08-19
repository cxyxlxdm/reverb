import Foundation

/// 随包内置的「新手引导」音频。
///
/// 为什么要有它:全新安装、又恰好没网时,播放链路一个字节都放不出来 —— 播放条、进度、
/// 倍速、菜单栏控制,全都无从体验,也无从判断"是 App 坏了还是网络不通"。
/// 这段 30 秒的音频打在包里,任何时候点开都能走通完整播放流程。
///
/// 音频资源:`Reverb.app/Contents/Resources/guide_intro.m4a`
/// (由 `shared/guide/make-guide.sh` 生成,可替换成真人录音)。
///
/// **它不是一集真正的播客**,因此刻意不进任何统计:见 PlayerController 里对 id 的判断
/// —— 不记历史、不计收听时长。否则"收听时长"第一条就是引导音频,很荒唐。
enum GuideEpisode {

    /// 稳定标识。用 reverb:// 前缀,确保不会与任何真实 RSS 的 guid 相同。
    static let id = "reverb://guide-intro"

    /// 与实际音频时长一致(见 make-guide.sh 输出),用于进度条刻度。
    private static let durationSec = 32

    /// 构造引导单集。资源找不到时返回 nil —— 调用方据此不显示入口,
    /// 而不是给出一个点了没反应的按钮。
    static func make() -> Episode? {
        guard let url = resourceURL() else {
            Log.w("Guide", "找不到 guide_intro.m4a,不显示引导入口")
            return nil
        }
        return Episode(
            id: id,
            title: String(localized: "余音使用引导"),
            description: String(localized: "随应用内置的 30 秒引导音频，无需联网即可播放。"),
            audioUrl: url.absoluteString,
            artworkUrl: "",                  // 无封面,UI 回落到水墨波形占位
            podcastTitle: "余音 Reverb",
            durationSec: durationSec
        )
    }

    /// 是否为引导音频。播放层与统计层据此跳过记账。
    static func isGuide(_ episodeId: String?) -> Bool { episodeId == id }

    /// 与 SeedCatalog 同一套查找逻辑:打包后在 Contents/Resources,
    /// `swift run` 调试时回落到源码树。
    private static func resourceURL() -> URL? {
        if let u = Bundle.main.url(forResource: "guide_intro", withExtension: "m4a") {
            return u
        }
        #if DEBUG
        let macosDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Data
            .deletingLastPathComponent()   // Reverb
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // macos
        let dev = macosDir.appendingPathComponent("Resources/guide_intro.m4a")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }
}
