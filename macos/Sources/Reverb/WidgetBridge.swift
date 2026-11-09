import Foundation
import Combine
import WidgetKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WidgetContract

/// 把「继续收听」卡片要画的东西写进共享目录,再让 WidgetKit 重载。
///
/// 与 iOS `ios/Reverb/App/WidgetBridge.swift` 是同一套节奏(20 秒一拍 + 一次性事件延迟 0.7 秒
/// + 逐字节相同就跳过),差别只有两处存储:
///  - 目录:macOS 没有 App Group(ad-hoc 签名没有 Team ID),落在
///    `~/Library/Application Support/Reverb/widget`(由 `WidgetShared.containerURL` 保证两端一致);
///  - 封面缩略图:用 ImageIO 直接降到 480px,不经过 `NSImage` 绘图上下文(少一层 scale 假设)。
///
/// 目录读不到时**什么都不写、只记一行日志**:App 照常可用,卡片显示空态。
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
        history.$history
            .sink { [weak self] _ in self?.schedule(force: false) }
            .store(in: &bag)
        settings.$themeMode
            .sink { [weak self] _ in self?.schedule(force: true) }
            .store(in: &bag)

        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in WidgetBridge.shared.flush() }
        }
        // 冷启动恢复出来的那份播放态不会再发一次 `$current`(restore 在 start 之前),
        // 所以这里必须主动写一次 —— 否则卡片要等用户按下播放才更新。
        schedule(force: true)
        Log.i("Widget", "桥梁启动")
    }

    /// 暂停态下的拖动/跳转:`positionMs` 跳了但下次落盘要等一拍。差得远就补写一次。
    private func positionChanged(_ ms: Int) {
        defer { lastPosition = ms }
        guard let player, !player.isPlaying else { return }
        if abs(ms - lastPosition) > 3_000 { schedule(force: true) }
    }

    /// `force = false` 时受 15 秒节流;两种都要再延迟 0.7 秒,等历史那条去抖写落盘。
    private func schedule(force: Bool) {
        if !force, Date().timeIntervalSince(lastWriteAt) < 15 { return }
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
        guard let container = WidgetShared.containerURL else {
            Log.w("Widget", "没有共享目录,卡片只能显示空态")
            return
        }

        var state = WidgetState()
        state.label = NSLocalizedString("继续收听", comment: "卡片顶部小字")
        state.dark = Self.isDark(settings)

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
                state.percent = Int((Double(max(0, position)) * 100 / Double(duration)).rounded())
                state.percent = min(max(state.percent, 0), 100)
                state.time = "\(Fmt.clock(position)) / \(Fmt.clock(duration))"
            } else if ep.isLive {
                state.time = NSLocalizedString("直播", comment: "直播流的时长位置占位")
            }
            state.art = writeArt(ep, to: container)
            state.empty = false
        } else {
            state.empty = true
            state.title = NSLocalizedString("挑一集开始听", comment: "卡片空态标题")
            state.podcast = NSLocalizedString("上次听到哪一集，会出现在这里", comment: "卡片空态副标题")
            state.art = writeArt(nil, to: container)
        }

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
    /// 纯白与浅色同按浅色画(与 `Theme.colorScheme` 同口径)。
    private static func isDark(_ settings: SettingsStore) -> Bool {
        switch settings.themeMode {
        case 2: return true
        case 1, 3: return false
        default:
            // `NSApp` 在 AppEnvironment 早期是 nil,`NSApplication.shared` 会顺手建出来。
            let appearance = NSApplication.shared.effectiveAppearance
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// 把封面从 App 的 `artwork_cache/` 复制一份缩略图到共享目录。
    /// 扩展读不到 App 沙箱,而卡片最大也就 4×4 那一档,480px 足够。
    /// 原图可能还没缓存(用户没在界面里见过)—— 那就返回空串,卡片画符号占位。
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
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480
              ] as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(
                  target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            lastArtSource = ""
            try? FileManager.default.removeItem(at: target)
            return ""
        }
        CGImageDestinationAddImage(dest, thumb,
                                   [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            lastArtSource = ""
            try? FileManager.default.removeItem(at: target)
            return ""
        }
        lastArtSource = episode.artworkUrl
        return WidgetShared.artFile
    }
}
