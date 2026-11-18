import SwiftUI
import UIKit
import Combine
import WidgetKit

/// 把「继续收听」卡片要画的东西写进 App Group 容器,再让 WidgetKit 重载。
///
/// 与鸿蒙 `WidgetUpdater` 是同一套节奏:
///  - **播放中约每 20 秒**写一次(进度条不必按秒跳,系统对重载也有配额);
///  - **换集 / 暂停 / 换主题**这类一次性事件延迟 0.7 秒再写 —— 历史那边是 400ms 去抖落盘,
///    立刻写会抓到上一集的位置;
///  - 算出来的内容与上次**逐字节相同**时直接跳过,不做无意义的 `reloadAllTimelines`。
///
/// 为什么由 App 主动推、卡片不自己排时间线:卡片的"上次听到哪"只有 App 知道。让系统按自己的
/// 节奏拉起扩展去读盘,读到的可能还是 20 秒前那份(与另三端同一条,见 `WidgetShared.swift`)。
///
/// 读不到 App Group 容器时(免费 Personal Team 签名没有这项能力)**什么都不写、只记一行日志**:
/// App 本身照常可用,卡片显示空态;不抛错、不反复重试。见 `docs/IOS.md`。
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    private weak var player: PlayerController?
    private weak var history: HistoryStore?
    private weak var settings: SettingsStore?

    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var lastWritten = Data()
    private var lastWriteAt = Date.distantPast
    private var lastPosition = -1
    private var missingContainerLogged = false
    /// 封面按 URL 缓存:同一张图不重复解码/编码(20 秒一拍都重编一次是白烧 CPU)。
    private var lastArtSource = ""

    private init() {}

    func start(player: PlayerController, history: HistoryStore, settings: SettingsStore) {
        self.player = player
        self.history = history
        self.settings = settings

        player.$current
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &bag)
        player.$isPlaying
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &bag)
        player.$positionMs
            .sink { [weak self] ms in self?.positionChanged(ms) }
            .store(in: &bag)
        // 历史在播放中约每 5 秒落一次盘(uPDATE)、换集时整体变一次。前者靠节流,
        // 后者与 `$current` 同时到达,不必单独分辨。
        history.$history
            .sink { [weak self] _ in self?.schedule(force: false) }
            .store(in: &bag)
        settings.$themeMode
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &bag)

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in WidgetBridge.shared.flush() }
        }
        // 冷启动恢复出来的那份播放态不会再发一次 `$current`(restore 在 start 之前),
        // 所以这里必须主动写一次 —— 否则卡片要等用户按下播放才更新。
        schedule(force: true)
        Log.i("Widget", "桥梁启动")
    }

    /// 暂停态下的拖动/跳转:`positionMs` 跳了但下次落盘要等一拍。差得远就补写一次,
    /// 几百毫秒内的抖动交给 20 秒那一拍(与 Android 那条 900ms 延迟同一个目的)。
    private func positionChanged(_ ms: Int) {
        defer { lastPosition = ms }
        guard let player, !player.isPlaying else { return }
        if abs(ms - lastPosition) > 3_000 { schedule(force: true) }
    }

    /// `force = false` 时受 4 秒节流;两种都要再延迟 0.7 秒,等历史那条去抖写落盘。
    /// 历史在播放中约 5 秒落一次,节流必须小于 5,否则每次都被挡掉、卡片退回 15 秒一拍(见 H267)。
    private func schedule(force: Bool) {
        if !force, Date().timeIntervalSince(lastWriteAt) < 4 { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 计算 → 与上次逐字节比较 → 变了才落盘并重载。
    private func flush() {
        guard let player, let history, let settings else { return }

        var state = WidgetState()
        state.dark = Self.isDark(settings)
        // 播放/暂停图标靠这一位翻面;进度 > 0 推不出"正在播"——暂停时进度还在。
        state.playing = player.isPlaying

        let episode = Self.pickEpisode(player: player, history: history)
        if let ep = episode {
            let row = history.history.first { $0.episode.id == ep.id }
            let duration = (row?.durationMs ?? 0) > 0
                ? row!.durationMs
                : max(ep.durationSec * 1000, player.current?.id == ep.id ? player.durationMs : 0)
            let position = row?.positionMs ?? (player.current?.id == ep.id ? player.positionMs : 0)
            state.id = ep.id
            state.title = ep.title
            state.podcast = ep.podcastTitle.isEmpty ? NSLocalizedString("未知频道", comment: "频道名缺失时的占位") : ep.podcastTitle
            state.live = ep.isLive
            if !ep.isLive && duration > 0 {
                state.hasProgress = true
                // 0.1% 一档(等价 Android 的 0..1000)。整数百分比在 80 分钟的节目上一格约 48 秒,
                // 5 秒推一次时进度条会"定住"(H267)。
                let raw = (Double(max(0, position)) * 1000 / Double(duration)).rounded() / 10
                state.percent = min(max(raw, 0), 100)
                state.time = "\(Fmt.clock(position)) / \(Fmt.clock(duration))"
            } else if ep.isLive {
                state.time = NSLocalizedString("直播", comment: "直播流的时长位置占位")
            }
            state.empty = false
        } else {
            state.empty = true
            state.title = NSLocalizedString("挑一集开始听", comment: "卡片空态标题")
            state.podcast = NSLocalizedString("上次听到哪一集，会出现在这里", comment: "卡片空态副标题")
        }

        // 锁屏 / 灵动岛与主屏卡片同源:同一份字段、同一拍更新。放在逐字节比较**之前** ——
        // 卡片内容没变时 flush 会提前返回,但 Live Activity 可能仍需因暂停/续播/拖动而重锚。
        // ⚠️ 这一步**必须在 App Group 判据之前**:Live Activity 不依赖组容器,
        // 免费团队签名拿不到 App Group 时,主屏卡片退化为空态,锁屏/灵动岛仍应工作。
        PlaybackLiveActivityBridge.shared.sync(state: state, player: player)

        guard let container = WidgetShared.containerURL else {
            if !missingContainerLogged {
                missingContainerLogged = true
                Log.w("Widget", "没有 App Group 容器,卡片只能显示空态(免费团队签名没有这项能力)")
            }
            return
        }
        state.art = writeArt(episode, to: container)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else {
            Log.w("Widget", "卡片状态编码失败")
            return
        }
        if data == lastWritten { return }
        do {
            try data.write(to: WidgetShared.stateURL(container), options: .atomic)
            lastWritten = data
            lastWriteAt = Date()
            WidgetCenter.shared.reloadAllTimelines()
            Log.i("Widget", "卡片已更新 empty=\(state.empty) id=\(state.id) percent=\(state.percent) art=\(state.art.isEmpty ? "-" : "有")")
        } catch {
            Log.e("Widget", "卡片状态写入失败", error: error)
        }
    }

    /// 与三端同一条筛选:先看 `playback_state.current`,没有才退回历史里
    /// 「10 秒以上、95% 以下、未播完」的第一条 —— 不另立一套门槛。
    private static func pickEpisode(player: PlayerController, history: HistoryStore) -> Episode? {
        if let cur = player.current, !cur.audioUrl.isEmpty { return cur }
        return history.history.first { row in
            guard !row.played, row.durationMs > 0 else { return false }
            return row.positionMs >= 10_000 && row.positionMs <= Int(Double(row.durationMs) * 0.95)
        }?.episode
    }

    /// 主题档位只有 App 知道(跟随系统 / 浅 / 深 / 纯白),扩展里拿到的是设备深浅。
    /// 纯白与浅色在手机上同按浅色画(与 `Theme.colorScheme` 同口径)。
    private static func isDark(_ settings: SettingsStore) -> Bool {
        switch settings.themeMode {
        case 2: return true
        case 1, 3: return false
        default:
            let style = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.traitCollection.userInterfaceStyle }
                .first
            return style == .dark
        }
    }

    /// 把封面从 App 的 `artwork_cache/` 复制一份缩略图到组容器。
    /// 扩展读不到 App 沙箱,而卡的尺寸最大也就 4×4 那一档,480px 足够。
    /// 原图可能还没缓存(用户没在界面里见过) —— 那就返回空串,卡片画符号占位。
    private func writeArt(_ episode: Episode?, to container: URL) -> String {
        guard let episode, !episode.artworkUrl.isEmpty else {
            lastArtSource = ""
            try? FileManager.default.removeItem(at: WidgetShared.artURL(container))
            return ""
        }
        let target = WidgetShared.artURL(container)
        if episode.artworkUrl == lastArtSource, FileManager.default.fileExists(atPath: target.path) {
            return WidgetShared.artFile
        }
        let src = AppSupport.dir
            .appendingPathComponent("artwork_cache", isDirectory: true)
            .appendingPathComponent(ArtworkCache.fileName(episode.artworkUrl))
        guard let image = UIImage(contentsOfFile: src.path) else {
            lastArtSource = ""
            try? FileManager.default.removeItem(at: target)
            return ""
        }
        let maxSide: CGFloat = 480
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let thumb = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = thumb.jpegData(compressionQuality: 0.82) else { return "" }
        do {
            try data.write(to: target, options: .atomic)
            lastArtSource = episode.artworkUrl
            return WidgetShared.artFile
        } catch {
            Log.w("Widget", "封面副本写入失败:\(error.localizedDescription)")
            return ""
        }
    }
}
